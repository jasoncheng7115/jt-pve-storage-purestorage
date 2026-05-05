# Pure Storage FlashArray Storage Plugin for Proxmox VE
# Copyright (c) 2026 Jason Cheng (Jason Tools)
# Licensed under the MIT License

package PVE::Storage::Custom::PureStoragePlugin;

use strict;
use warnings;

use base qw(PVE::Storage::Plugin);

use PVE::Tools qw(run_command);
use PVE::JSONSchema qw(get_standard_option);
use PVE::Cluster qw(cfs_read_file);
use PVE::ProcFSTools;

use Fcntl qw(:flock);
use JSON;
use POSIX ();
use File::Path qw(make_path);

use PVE::Storage::Custom::PureStorage::API;
use PVE::Storage::Custom::PureStorage::Naming qw(
    encode_volume_name
    decode_volume_name
    encode_snapshot_name
    decode_snapshot_name
    encode_host_name
    encode_config_volume_name
    decode_config_volume_name
    is_config_volume
    pve_volname_to_pure
    pure_to_pve_volname
    is_pve_managed_volume
);
use PVE::Storage::Custom::PureStorage::ISCSI qw(
    get_initiator_name
    probe_portal
    discover_targets
    login_target
    logout_target
    get_sessions
    rescan_sessions
    is_portal_logged_in
    wait_for_device
);
use PVE::Storage::Custom::PureStorage::Multipath qw(
    rescan_scsi_hosts
    rescan_scsi_device
    multipath_reload
    multipath_flush
    multipath_resize_map
    get_multipath_device
    get_device_by_wwid
    wait_for_multipath_device
    cleanup_lun_devices
    is_device_in_use
    get_multipath_slaves
    remove_scsi_device
    list_pure_multipath_devices
    get_device_usage_details
);
use PVE::Storage::Custom::PureStorage::FC qw(
    get_fc_wwpns
    get_fc_wwpns_raw
    is_fc_available
    rescan_fc_hosts
    get_fc_targets
    normalize_wwn
);

# Plugin API version
use constant APIVERSION => 13;
use constant MIN_APIVERSION => 9;

# Mark as shared storage (accessible from multiple nodes)
push @PVE::Storage::Plugin::SHARED_STORAGE, 'purestorage';

#
# Plugin registration
#

sub api {
    return APIVERSION;
}

sub type {
    return 'purestorage';
}

sub plugindata {
    return {
        content => [
            { images => 1, rootdir => 1 },
            { images => 1 },
        ],
        format => [
            { raw => 1 },
            'raw',
        ],
    };
}

sub properties {
    return {
        'pure-portal' => {
            description => "Pure Storage FlashArray management IP address or hostname.",
            type => 'string',
        },
        'pure-api-token' => {
            description => "API token for Pure Storage REST API authentication.",
            type => 'string',
        },
        'pure-username' => {
            description => "Username for Pure Storage REST API (if not using API token).",
            type => 'string',
            optional => 1,
        },
        'pure-password' => {
            description => "Password for Pure Storage REST API (if not using API token).",
            type => 'string',
            optional => 1,
        },
        'pure-ssl-verify' => {
            description => "Verify SSL certificate.",
            type => 'boolean',
            default => 0,
        },
        'pure-protocol' => {
            description => "SAN protocol: 'iscsi' or 'fc' (Fibre Channel).",
            type => 'string',
            enum => ['iscsi', 'fc'],
            default => 'iscsi',
        },
        'pure-host-mode' => {
            description => "Host mode: 'per-node' creates host per PVE node, 'shared' uses single shared host.",
            type => 'string',
            enum => ['per-node', 'shared'],
            default => 'per-node',
        },
        'pure-cluster-name' => {
            description => "PVE cluster name for host naming on Pure Storage.",
            type => 'string',
            optional => 1,
        },
        'pure-device-timeout' => {
            description => "Timeout in seconds for device discovery after volume connection.",
            type => 'integer',
            minimum => 10,
            maximum => 300,
            default => 60,
        },
        'pure-portal-probe-timeout' => {
            description => "Timeout in seconds for the TCP pre-check that skips"
                . " unreachable iSCSI portals before iscsiadm discovery/login."
                . " Set to 0 to disable the pre-check (legacy behaviour). Raise"
                . " on high-latency or congested storage networks.",
            type => 'integer',
            minimum => 0,
            maximum => 30,
            default => 2,
        },
        'pure-pod' => {
            description => "Pod name for ActiveCluster configurations. Required when File service is enabled.",
            type => 'string',
            optional => 1,
        },
    };
}

sub options {
    return {
        'pure-portal'        => { fixed => 1 },
        'pure-api-token'     => { optional => 1 },
        'pure-username'      => { optional => 1 },
        'pure-password'      => { optional => 1 },
        'pure-ssl-verify'    => { optional => 1 },
        'pure-protocol'      => { optional => 1 },
        'pure-host-mode'     => { optional => 1 },
        'pure-cluster-name'  => { optional => 1 },
        'pure-device-timeout' => { optional => 1 },
        'pure-portal-probe-timeout' => { optional => 1 },
        'pure-pod'           => { optional => 1 },
        nodes                => { optional => 1 },
        disable              => { optional => 1 },
        content              => { optional => 1 },
        shared               => { optional => 1 },
    };
}

#
# Helper methods
#

# Get API client instance (cached per storage config)
my %api_cache;
use constant API_CACHE_TTL => 300;

# Run `udevadm trigger --subsystem-match=block` and `udevadm settle` with
# bounded timeouts. Bare `system('udevadm ...')` can hang indefinitely on a
# wedged kernel namespace; PVE::Tools::run_command kills the child on timeout.
sub _udev_refresh {
    eval {
        PVE::Tools::run_command(
            ['/sbin/udevadm', 'trigger', '--subsystem-match=block'],
            timeout => 10, errfunc => sub { }, outfunc => sub { },
        );
    };
    eval {
        PVE::Tools::run_command(
            ['/sbin/udevadm', 'settle', '--timeout=5'],
            timeout => 10, errfunc => sub { }, outfunc => sub { },
        );
    };
}

#
# WWID tracking — cluster residual device cleanup
#
# The problem this solves: in a per-host mapping setup we connect every new
# Pure volume to ALL cluster hosts (so live migration works). When node A
# deletes a VM, node A cleans up its local multipath/SCSI devices and then
# disconnects + deletes the volume on the array. But nodes B and C, which
# also auto-discovered the volume via iSCSI rescan, are now left with stale
# multipath devices pointing at a volume that no longer exists. Combined
# with `queue_if_no_path` in multipath.conf, any process that touches one
# of those stale devices later (e.g. `vgs` during a migration) enters
# uninterruptible sleep (D state) and can only be recovered by a reboot.
#
# Each node keeps a tracking file at /var/lib/pve-storage-purestorage/<storeid>-wwids.json
# that lists every WWID we've ever seen alive on this node. Periodically
# (from status()) we query the array for the current alive WWIDs, auto-import
# them into the tracking file (so all nodes converge on the same alive set),
# then for any tracked WWID NOT in the alive set we clean its local stale
# device. The plugin only ever touches WWIDs in its own tracking file or
# auto-imported from the array — it never touches manually-managed devices
# from other plugins or customer storage.

sub _wwid_state_dir { return '/var/lib/pve-storage-purestorage'; }
sub _wwid_lock_dir  { return '/var/run/pve-storage-purestorage'; }

sub _safe_storeid {
    my ($storeid) = @_;
    $storeid //= 'unknown';
    $storeid =~ s/[^A-Za-z0-9_-]/_/g;
    return $storeid;
}

sub _wwid_state_file {
    my ($storeid) = @_;
    return _wwid_state_dir() . '/' . _safe_storeid($storeid) . '-wwids.json';
}

sub _wwid_lock_file {
    my ($storeid) = @_;
    return _wwid_lock_dir() . '/' . _safe_storeid($storeid) . '-wwids.lock';
}

sub _ensure_wwid_state_dir {
    my $state_dir = _wwid_state_dir();
    my $lock_dir  = _wwid_lock_dir();
    eval { make_path($state_dir, { mode => 0700 }) unless -d $state_dir; };
    eval { make_path($lock_dir,  { mode => 0700 }) unless -d $lock_dir;  };
}

# Acquire a non-blocking flock with bounded retries. Standard flock(LOCK_EX)
# blocks indefinitely if another worker is stuck holding the lock; that would
# defeat the whole point of all the timeout protections. After 10s of failing
# to lock we proceed without the lock — better to risk a rare lost write than
# to hang the whole storage daemon.
sub _with_wwid_lock {
    my ($storeid, $code) = @_;

    _ensure_wwid_state_dir();
    my $lock_file = _wwid_lock_file($storeid);

    open(my $lock_fh, '>', $lock_file) or do {
        warn "Cannot open WWID lock file $lock_file: $!\n";
        return $code->();
    };

    my $deadline = time() + 10;
    my $locked = 0;
    while (time() < $deadline) {
        if (flock($lock_fh, LOCK_EX | LOCK_NB)) {
            $locked = 1;
            last;
        }
        select(undef, undef, undef, 0.1);
    }

    unless ($locked) {
        warn "Cannot acquire WWID lock $lock_file within 10s, proceeding without lock\n";
        close($lock_fh);
        return $code->();
    }

    my @ret = eval { $code->() };
    my $err = $@;
    flock($lock_fh, LOCK_UN);
    close($lock_fh);
    die $err if $err;
    return wantarray ? @ret : $ret[0];
}

sub _read_wwid_state {
    my ($storeid) = @_;
    my $file = _wwid_state_file($storeid);
    return {} unless -f $file;
    open(my $fh, '<', $file) or return {};
    local $/;
    my $json = <$fh>;
    close($fh);
    my $data = eval { decode_json($json) } // {};
    return ref($data) eq 'HASH' ? $data : {};
}

sub _write_wwid_state {
    my ($storeid, $state) = @_;
    _ensure_wwid_state_dir();
    my $file = _wwid_state_file($storeid);
    my $tmp = "$file.tmp.$$";
    open(my $fh, '>', $tmp) or do {
        warn "Cannot open $tmp for write: $!\n";
        return 0;
    };
    print $fh encode_json($state // {});
    close($fh);
    rename($tmp, $file) or do {
        warn "Cannot rename $tmp to $file: $!\n";
        unlink($tmp);
        return 0;
    };
    return 1;
}

sub _track_wwid {
    my ($storeid, $wwid) = @_;
    return unless $wwid;
    _with_wwid_lock($storeid, sub {
        my $state = _read_wwid_state($storeid);
        return if $state->{lc($wwid)};
        $state->{lc($wwid)} = time();
        _write_wwid_state($storeid, $state);
    });
}

sub _untrack_wwid {
    my ($storeid, $wwid) = @_;
    return unless $wwid;
    _with_wwid_lock($storeid, sub {
        my $state = _read_wwid_state($storeid);
        if (delete $state->{lc($wwid)}) {
            _write_wwid_state($storeid, $state);
        }
    });
}

# Cleanup orphaned/stale Pure multipath devices on this node.
#
# Phase 1: query the array for all current pve_* LUN WWIDs and auto-import
#          them into the local tracking file. This is what makes nodes B/C
#          aware of LUNs created on node A — without this, they would never
#          find anything to clean up.
# Phase 2: for every WWID in the tracking file that is NOT in the current
#          array alive-set, if it has a local multipath device, clean it up.
#          Only untrack the WWID if cleanup verifiably succeeded (multipath
#          device gone). If cleanup failed, KEEP the WWID tracked so the
#          next pass can retry — without this, a single transient failure
#          (kpartx holders, multipathd glitch, dmsetup busy) would silently
#          leak a stale device because Phase 1 cannot re-import a WWID
#          whose volume has been deleted from the array.
# Phase 3: best-effort warning for Pure multipath devices on this node that
#          are not in tracking and not on the array. We do NOT auto-clean
#          these because they could be from a manually-attached LUN, another
#          plugin, or a customer's own storage.
sub _cleanup_orphaned_devices {
    my ($api, $storeid, $scfg) = @_;

    my $san_storage = $storeid;
    $san_storage =~ s/-/_/g;

    my $pod = $scfg->{'pure-pod'};
    my $pattern = "pve-${san_storage}-*";
    $pattern = "${pod}::${pattern}" if $pod;

    # Phase 1: import currently-alive WWIDs from the array.
    my $volumes = eval { $api->volume_list($pattern); };
    if ($@) {
        warn "orphan cleanup: array query failed, aborting to avoid false positives: $@\n";
        return;
    }
    $volumes //= [];

    my %alive;
    for my $vol (@$volumes) {
        next unless $vol->{name};
        next if $vol->{destroyed};  # already destroyed on the array
        my $wwid = eval { $api->volume_get_wwid($vol->{name}); };
        next unless $wwid;
        $alive{lc($wwid)} = 1;
        eval { _track_wwid($storeid, $wwid); };
    }

    # Phase 2: for each tracked WWID not on the array, clean its local stale
    # device if any.
    my $tracked = _read_wwid_state($storeid);
    for my $wwid (keys %$tracked) {
        next if $alive{$wwid};
        my $mpath = eval { get_multipath_device($wwid); };
        if ($mpath && -b $mpath) {
            warn "orphan cleanup: stale Pure device $mpath (wwid $wwid) — array no longer has this volume, cleaning up\n";
            # Refuse to clean if the stale device is somehow in use — better
            # to leave it for the operator than to disrupt running I/O.
            if (eval { is_device_in_use($mpath) }) {
                warn "orphan cleanup: $mpath is in use, leaving for manual review\n";
                next;
            }
            eval { cleanup_lun_devices($wwid); };
            warn "orphan cleanup: cleanup of $wwid failed: $@\n" if $@;

            # Verify the multipath device is actually gone before untracking.
            # Mirrors the conditional-untrack pattern in free_image(): if the
            # device is still present, keep the WWID tracked so the next
            # status() poll retries. Without this guard a partial cleanup
            # (e.g. kpartx holder, queue_if_no_path stuck) would untrack the
            # WWID and leave a stale device that no future pass can find.
            my $still_present = eval { get_multipath_device($wwid); };
            if ($still_present) {
                warn "orphan cleanup: device for WWID $wwid still present after cleanup, " .
                     "keeping tracked for retry.\n";
                next;
            }
        }
        eval { _untrack_wwid($storeid, $wwid); };
    }

    # Phase 3: warn about Pure multipath devices not tracked and not on array.
    # Use a per-WWID cooldown (flag file in /var/run/) to avoid flooding
    # the journal every 10 seconds when pvestatd polls status(). Each WWID
    # is warned about at most once per hour.
    my $local = eval { list_pure_multipath_devices(); } // [];
    my $cooldown_dir = _wwid_lock_dir();
    for my $dev (@$local) {
        my $w = $dev->{wwid};
        next if $alive{$w};
        next if $tracked->{$w};

        # Cooldown: skip if warned about this WWID within the last hour.
        my $flag = "$cooldown_dir/orphan-warned-$w";
        if (-f $flag) {
            my $age = time() - (stat($flag))[9];
            next if $age < 3600;  # 1 hour cooldown
        }

        warn "orphan cleanup: untracked stale Pure multipath device /dev/mapper/$dev->{name} " .
             "(wwid $w) — not on array and not tracked. Possibly from a manually-attached LUN " .
             "or a previous plugin version. Manual cleanup recommended:\n" .
             "  multipathd disablequeueing map $dev->{name}\n" .
             "  dmsetup message $dev->{name} 0 fail_if_no_path\n" .
             "  multipath -f /dev/mapper/$dev->{name}\n";

        # Touch the flag file for cooldown.
        eval { open(my $fh, '>', $flag); close($fh); };
    }
}

sub _get_api {
    my ($scfg) = @_;

    my $storeid = $scfg->{storage} // $scfg->{'pure-portal'} // 'unknown';

    # Return cached client if available, fresh, and from same process
    # (forked workers must not share session tokens)
    if (my $cached = $api_cache{$storeid}) {
        my $cache_age = time() - ($cached->{timestamp} // 0);
        if ($cache_age < API_CACHE_TTL &&
            $cached->{host} eq $scfg->{'pure-portal'} &&
            ($cached->{pid} // 0) == $$) {
            return $cached->{api};
        }
    }

    my $ssl_verify = $scfg->{'pure-ssl-verify'} // 0;

    my $api = PVE::Storage::Custom::PureStorage::API->new(
        host       => $scfg->{'pure-portal'},
        api_token  => $scfg->{'pure-api-token'},
        username   => $scfg->{'pure-username'},
        password   => $scfg->{'pure-password'},
        ssl_verify => $ssl_verify,
    );

    $api_cache{$storeid} = {
        api       => $api,
        host      => $scfg->{'pure-portal'},
        timestamp => time(),
        pid       => $$,
    };

    return $api;
}

# Get host name for current node
sub _get_host_name {
    my ($scfg) = @_;

    my $cluster_name = $scfg->{'pure-cluster-name'} // 'pve';
    my $mode = $scfg->{'pure-host-mode'} // 'per-node';

    if ($mode eq 'shared') {
        return encode_host_name($cluster_name, undef);
    } else {
        my $nodename = PVE::INotify::nodename();
        return encode_host_name($cluster_name, $nodename);
    }
}

# Get full volume name with pod prefix if configured
sub _get_full_volname {
    my ($scfg, $volname) = @_;

    my $pod = $scfg->{'pure-pod'};
    if ($pod) {
        return "${pod}::${volname}";
    }
    return $volname;
}

# Strip pod prefix from volume name for display
sub _strip_pod_prefix {
    my ($scfg, $fullname) = @_;

    my $pod = $scfg->{'pure-pod'};
    if ($pod && $fullname =~ /^\Q${pod}\E::(.+)$/) {
        return $1;
    }
    return $fullname;
}

# Convert PVE volname to full Pure Storage volume name (with pod prefix)
sub _pve_to_pure_full {
    my ($scfg, $storeid, $volname) = @_;

    my $pure_volname_base = pve_volname_to_pure($storeid, $volname);
    return _get_full_volname($scfg, $pure_volname_base);
}

#
# VM Config Backup Functions
#

# Get VM config file path (supports both QEMU and LXC)
sub _get_vm_config_path {
    my ($vmid) = @_;

    # Try QEMU config first
    my $qemu_conf = "/etc/pve/qemu-server/${vmid}.conf";
    return $qemu_conf if -f $qemu_conf;

    # Try LXC config
    my $lxc_conf = "/etc/pve/lxc/${vmid}.conf";
    return $lxc_conf if -f $lxc_conf;

    return undef;
}

# Read VM config content
sub _read_vm_config {
    my ($vmid) = @_;

    my $conf_path = _get_vm_config_path($vmid);
    return undef unless $conf_path;

    open(my $fh, '<', $conf_path) or return undef;
    local $/;
    my $content = <$fh>;
    close($fh);

    return $content;
}

# Backup VM config to Pure Storage volume
# Creates a small volume and writes config content to it
sub _backup_vm_config {
    my ($scfg, $storeid, $api, $vmid, $snapname) = @_;

    # Read VM config
    my $config_content = _read_vm_config($vmid);
    unless ($config_content) {
        warn "Cannot read VM config for VMID $vmid, skipping config backup\n";
        return 0;
    }

    # Generate config volume name
    my $config_vol_base = encode_config_volume_name($storeid, $vmid, $snapname);
    my $config_vol = _get_full_volname($scfg, $config_vol_base);

    # Check if config volume already exists (from another disk's snapshot)
    my $existing = eval { $api->volume_get($config_vol); };
    if ($existing) {
        # Already exists, skip (another disk of same VM already created it)
        return 1;
    }

    # Create small volume (1MB is plenty for config file)
    eval { $api->volume_create($config_vol, 1 * 1024 * 1024); };  # 1MB
    if ($@) {
        warn "Failed to create config backup volume: $@\n";
        return 0;
    }

    # Connect to current host
    my $host = _get_host_name($scfg);
    eval { $api->volume_connect_host($config_vol, $host); };
    if ($@) {
        warn "Failed to connect config volume to host: $@\n";
        # Defensive disconnect: connection may have actually been made on
        # the array even though the response was lost. Without this the
        # subsequent volume_delete leaves orphaned host connections (Bug E).
        _disconnect_from_all_hosts($api, $config_vol);
        eval { $api->volume_delete($config_vol, skip_eradicate => 1); };
        return 0;
    }

    # Get device path
    my $wwid = eval { $api->volume_get_wwid($config_vol); };
    unless ($wwid) {
        warn "Cannot get WWID for config volume\n";
        # Use _disconnect_from_all_hosts rather than a single
        # volume_disconnect_host so we also catch any extra connections
        # that may have appeared between connect and now.
        _disconnect_from_all_hosts($api, $config_vol);
        eval { $api->volume_delete($config_vol, skip_eradicate => 1); };
        return 0;
    }

    # Rescan and wait for device with protocol-specific rescan in wait loop
    my $protocol = $scfg->{'pure-protocol'} // 'iscsi';
    if ($protocol eq 'iscsi') {
        rescan_sessions();
    } else {
        rescan_fc_hosts();
    }
    multipath_reload();

    my $timeout = $scfg->{'pure-device-timeout'} // 60;
    my %wait_opts = (timeout => $timeout);
    if ($protocol eq 'fc') {
        $wait_opts{fc_rescan} = sub { rescan_fc_hosts(delay => 1); };
    } else {
        $wait_opts{iscsi_rescan} = sub { rescan_sessions(); };
    }
    my $device = wait_for_multipath_device($wwid, %wait_opts);

    unless ($device) {
        warn "Config backup device not found, skipping config backup\n";
        eval { cleanup_lun_devices($wwid); };
        eval { $api->volume_disconnect_host($config_vol, $host); };
        eval { $api->volume_delete($config_vol, skip_eradicate => 1); };
        return 0;
    }

    # Format with ext4 and write config. Wrap mkfs/mount/umount in
    # PVE::Tools::run_command with explicit timeouts — bare system() can
    # enter D state on a wedged multipath device. The 1MB volume was just
    # allocated so the device should be healthy, but we still want a
    # bounded failure mode rather than a node hang.
    my $mount_point = "/tmp/pve-pure-config-$$";
    my $mounted = 0;
    eval {
        # Create filesystem. -O ^has_journal because 1MB is too small.
        PVE::Tools::run_command(
            ['/sbin/mkfs.ext4', '-q', '-F', '-O', '^has_journal', $device],
            timeout => 30,
        );

        # Mount and write config
        mkdir($mount_point) or die "mkdir failed: $!";

        PVE::Tools::run_command(
            ['/bin/mount', $device, $mount_point],
            timeout => 30,
        );
        $mounted = 1;

        # Write config file
        my $conf_file = "$mount_point/${vmid}.conf";
        open(my $fh, '>', $conf_file) or die "Cannot write config: $!";
        print $fh $config_content;
        close($fh);

        # Add metadata file with snapshot info
        my $meta_file = "$mount_point/metadata.txt";
        open(my $mfh, '>', $meta_file) or die "Cannot write metadata: $!";
        print $mfh "vmid=$vmid\n";
        print $mfh "snapname=$snapname\n";
        print $mfh "timestamp=" . time() . "\n";
        print $mfh "source_file=" . (_get_vm_config_path($vmid) // 'unknown') . "\n";
        close($mfh);

        # Sync to ensure data hits the device before unmount
        PVE::Tools::run_command(['/bin/sync'], timeout => 10);

        # Unmount
        PVE::Tools::run_command(['/bin/umount', $mount_point], timeout => 30);
        $mounted = 0;
        rmdir($mount_point);
    };
    if ($@) {
        warn "Failed to write config to volume: $@\n";
        # Ensure mount is cleaned up even on error
        if ($mounted) {
            eval { PVE::Tools::run_command(['/bin/umount', $mount_point], timeout => 30); };
            rmdir($mount_point);
        }
        # Cleanup local devices and Pure Storage volume
        eval { cleanup_lun_devices($wwid); };
        eval { $api->volume_disconnect_host($config_vol, $host); };
        eval { $api->volume_delete($config_vol, skip_eradicate => 1); };
        return 0;
    }

    # Disconnect volume (config is written, no need to keep it connected)
    eval {
        cleanup_lun_devices($wwid);
        $api->volume_disconnect_host($config_vol, $host);
    };

    return 1;
}

# Delete a specific config volume
sub _delete_config_volume {
    my ($api, $scfg, $storeid, $vmid, $snapname) = @_;

    my $config_vol_base = encode_config_volume_name($storeid, $vmid, $snapname);
    my $config_vol = _get_full_volname($scfg, $config_vol_base);

    my $existing = eval { $api->volume_get($config_vol); };
    if ($existing) {
        # Disconnect from all hosts first
        my $connections = eval { $api->volume_get_connections($config_vol); } // [];
        for my $conn (@$connections) {
            eval { $api->volume_disconnect_host($config_vol, $conn->{name}); };
        }
        # Delete (destroy only, no eradicate for recoverability)
        eval { $api->volume_delete($config_vol, skip_eradicate => 1); };
        if ($@) {
            warn "Failed to delete config volume $config_vol: $@\n";
        }
    }
}

# Cleanup all config volumes for a VM (called when VM is deleted)
sub _cleanup_vm_config_volumes {
    my ($api, $scfg, $storeid, $vmid) = @_;

    # List all config volumes for this VM
    my $san_storage = $storeid;
    $san_storage =~ s/-/_/g;

    my $pattern = "pve-${san_storage}-${vmid}-vmconf-*";
    my $pod = $scfg->{'pure-pod'};

    my $volumes = eval { $api->volume_list(pattern => $pattern, pod => $pod); } // [];

    for my $vol (@$volumes) {
        my $volname = $vol->{name};
        # Disconnect and delete
        my $connections = eval { $api->volume_get_connections($volname); } // [];
        for my $conn (@$connections) {
            eval { $api->volume_disconnect_host($volname, $conn->{name}); };
        }
        eval { $api->volume_delete($volname, skip_eradicate => 1); };
        if ($@) {
            warn "Failed to cleanup config volume $volname: $@\n";
        }
    }
}

# Get initiators based on protocol (iSCSI IQN or FC WWPN)
# Note: For FC, returns WWPNs in raw format (no colons) as expected by Pure Storage API
sub _get_initiators {
    my ($scfg) = @_;

    my $protocol = $scfg->{'pure-protocol'} // 'iscsi';

    if ($protocol eq 'fc') {
        # Use raw format (no colons) for Pure Storage API compatibility
        my $wwpns = get_fc_wwpns_raw(online_only => 1);
        die "No FC HBA WWPNs found on this node. Is FC HBA installed and online?" unless @$wwpns;
        return ('wwn', @$wwpns);
    } else {
        return ('iqn', get_initiator_name());
    }
}

# Ensure host exists and has current node's initiator
sub _ensure_host {
    my ($scfg, $api) = @_;

    my $host_name = _get_host_name($scfg);
    my ($initiator_type, @initiators) = _get_initiators($scfg);

    # Get or create host
    my $host;
    eval {
        if ($initiator_type eq 'wwn') {
            $host = $api->host_get_or_create($host_name, wwns => \@initiators);
        } else {
            $host = $api->host_get_or_create($host_name, iqns => \@initiators);
        }
    };
    if ($@) {
        my $err = $@;
        # Check if the error is due to initiator already being in use by another host
        if ($err =~ /already in use/i || $err =~ /already exists/i || $err =~ /conflict/i) {
            die "Failed to create host '$host_name': initiator is already registered with another host. " .
                "This may happen if the same initiator was previously configured with a different host name. " .
                "Please check Pure Storage UI and remove the conflicting host entry. Error: $err";
        }
        die "Failed to create/get host '$host_name': $err";
    }

    # Verify all initiators are in host
    # Note: API 2.x returns 'wwns'/'iqns', API 1.x returns 'wwnlist'/'iqnlist' or 'wwn'/'iqn'
    my %existing_initiators;
    if ($host) {
        my $list;
        if ($initiator_type eq 'wwn') {
            $list = $host->{wwns} // $host->{wwnlist} // $host->{wwn};
        } else {
            $list = $host->{iqns} // $host->{iqnlist} // $host->{iqn};
        }
        if ($list && ref($list) eq 'ARRAY') {
            for my $init (@$list) {
                # Normalize for comparison (handles different WWN formats)
                my $normalized = ($initiator_type eq 'wwn') ? normalize_wwn($init) : lc($init);
                $existing_initiators{$normalized} = 1 if defined $normalized;
            }
        }
    }

    # Add missing initiators
    my @failed_initiators;
    for my $initiator (@initiators) {
        # Normalize for comparison
        my $normalized = ($initiator_type eq 'wwn') ? normalize_wwn($initiator) : lc($initiator);
        unless ($normalized && $existing_initiators{$normalized}) {
            eval { $api->host_add_initiator($host_name, $initiator, $initiator_type); };
            if ($@) {
                my $err = $@;
                if ($err =~ /already in use/i || $err =~ /already exists/i) {
                    # Initiator is registered with another host - this is a serious issue
                    push @failed_initiators, {
                        initiator => $initiator,
                        error => $err,
                    };
                } else {
                    warn "Warning: Failed to add initiator '$initiator' to host '$host_name': $err\n";
                }
            }
        }
    }

    # If any initiators failed due to conflicts, report them
    if (@failed_initiators) {
        my @msgs = map { "$_->{initiator}" } @failed_initiators;
        die "The following initiators are already registered with another Pure Storage host: " .
            join(", ", @msgs) . ". " .
            "Please remove the conflicting host entries from Pure Storage before continuing.";
    }

    return $host_name;
}

# Connect volume to all cluster hosts for migration support
# In per-node mode, volumes need to be connected to all nodes for live migration
# Disconnect a volume from every Pure host that currently has a connection
# to it. Used by cleanup paths after a partial _connect_to_all_hosts:
# the connect helper may have succeeded on hosts 1..K and failed on K+1,
# leaving the volume mapped to K hosts. Calling volume_delete in this state
# is dangerous: even though Pure (unlike ONTAP) will physically destroy
# the volume, the orphaned connection records cause iSCSI rescan on other
# cluster nodes to discover ghost LUNs that become stale multipath
# devices. With `no_path_retry queue` in defaults that is the same root
# cause as the production hang incident.
#
# Best-effort: every disconnect is wrapped in eval and warns on failure
# rather than dying — we never want a cleanup helper to itself fail and
# mask the original error.
sub _disconnect_from_all_hosts {
    my ($api, $vol) = @_;
    return unless $api && $vol;

    my $connections = eval { $api->volume_get_connections($vol); };
    return unless $connections && @$connections;

    for my $conn (@$connections) {
        next unless $conn->{name};
        eval { $api->volume_disconnect_host($vol, $conn->{name}); };
        if ($@) {
            warn "_disconnect_from_all_hosts: failed to disconnect $vol from $conn->{name}: $@";
        }
    }
}

sub _connect_to_all_hosts {
    my ($scfg, $api, $pure_volname) = @_;

    my $host_mode = $scfg->{'pure-host-mode'} // 'per-node';

    if ($host_mode eq 'shared') {
        # Shared mode: single host connection is sufficient
        my $host = _get_host_name($scfg);
        unless ($api->volume_is_connected($pure_volname, $host)) {
            $api->volume_connect_host($pure_volname, $host);
        }
        return ([$host], []);
    }

    # Per-node mode: connect to all PVE hosts for migration support
    my $cluster_name = $scfg->{'pure-cluster-name'} // 'pve';
    my $hosts = eval { $api->host_list("pve-${cluster_name}-*"); };
    $hosts //= [];

    my @connected_hosts;
    my @failed_hosts;

    # First, connect to current node's host (required)
    my $current_host = _get_host_name($scfg);
    eval {
        unless ($api->volume_is_connected($pure_volname, $current_host)) {
            $api->volume_connect_host($pure_volname, $current_host);
        }
        push @connected_hosts, $current_host;
    };
    if ($@) {
        die "Failed to connect volume to current node host '$current_host': $@";
    }

    # Then try to connect to other hosts (best effort for migration)
    for my $host (@$hosts) {
        next unless $host->{name};
        next if $host->{name} eq $current_host;  # Already connected

        eval {
            unless ($api->volume_is_connected($pure_volname, $host->{name})) {
                $api->volume_connect_host($pure_volname, $host->{name});
            }
            push @connected_hosts, $host->{name};
        };
        if ($@) {
            push @failed_hosts, $host->{name};
        }
    }

    return (\@connected_hosts, \@failed_hosts);
}

# Parse PVE volname to components
sub _parse_volname {
    my ($volname) = @_;

    # Format: images/vm-100-disk-0 or vm-100-disk-0 or base-100-disk-0
    # Linked clone format: base-100-disk-0/vm-101-disk-0
    $volname =~ s|^images/||;

    # Linked clone: base-100-disk-0/vm-101-disk-0
    # This is a clone linked to a base image
    if ($volname =~ m|^(base-(\d+)-disk-(\d+))/(vm-(\d+)-disk-(\d+))$|) {
        return {
            vmid     => $4,      # clone's VMID
            diskid   => $5,      # clone's disk ID
            format   => 'raw',
            type     => 'disk',
            isBase   => 0,
            basename => $1,      # base-100-disk-0
            basevmid => $2,      # base's VMID
        };
    # VM disk: vm-100-disk-0
    } elsif ($volname =~ /^vm-(\d+)-disk-(\d+)$/) {
        return {
            vmid   => $1,
            diskid => $2,
            format => 'raw',
            type   => 'disk',
            isBase => 0,
        };
    # Template base disk: base-100-disk-0
    } elsif ($volname =~ /^base-(\d+)-disk-(\d+)$/) {
        return {
            vmid   => $1,
            diskid => $2,
            format => 'raw',
            type   => 'disk',
            isBase => 1,
        };
    # Cloud-init: vm-100-cloudinit
    } elsif ($volname =~ /^vm-(\d+)-cloudinit$/) {
        return {
            vmid   => $1,
            format => 'raw',
            type   => 'cloudinit',
            isBase => 0,
        };
    # VM state: vm-100-state-snapname
    } elsif ($volname =~ /^vm-(\d+)-state-(.+)$/) {
        return {
            vmid     => $1,
            snapname => $2,
            format   => 'raw',
            type     => 'state',
            isBase   => 0,
        };
    }

    return undef;
}

# Get next available disk ID for a VM
sub _find_free_diskid {
    my ($scfg, $storeid, $vmid) = @_;

    my $api = _get_api($scfg);
    my $san_storage = $storeid;
    $san_storage =~ s/-/_/g;

    # List existing volumes for this VM
    my $pattern = "pve-${san_storage}-${vmid}-*";
    # Add pod prefix if configured
    my $pod = $scfg->{'pure-pod'};
    if ($pod) {
        $pattern = "${pod}::${pattern}";
    }
    my $volumes = $api->volume_list($pattern);

    my %used_ids;
    for my $vol (@$volumes) {
        # Strip pod prefix before decoding (e.g., "pod1::pve-..." -> "pve-...")
        my $volname_for_decode = _strip_pod_prefix($scfg, $vol->{name});
        my $decoded = decode_volume_name($volname_for_decode);
        if ($decoded && $decoded->{vmid} == $vmid && defined $decoded->{diskid}) {
            $used_ids{$decoded->{diskid}} = 1;
        }
    }

    # Find first unused ID
    for (my $id = 0; $id < 1000; $id++) {
        return $id unless $used_ids{$id};
    }

    die "No free disk ID found for VM $vmid";
}

# Cleanup orphaned temporary snapshot clones
# These may be left behind if PVE crashes during a copy operation
sub _cleanup_orphaned_temp_clones {
    my ($scfg, $storeid, $api) = @_;

    my $san_storage = $storeid;
    $san_storage =~ s/-/_/g;

    # Find all temp-snap-access volumes for this storage
    my $pattern = "pve-${san_storage}-*-temp-snap-access-*";
    # Add pod prefix if configured
    my $pod = $scfg->{'pure-pod'};
    if ($pod) {
        $pattern = "${pod}::${pattern}";
    }

    my $temp_vols = eval { $api->volume_list($pattern); };
    return unless $temp_vols && @$temp_vols;

    for my $vol (@$temp_vols) {
        next unless $vol->{name};

        # Safety: only delete volumes older than 1 hour
        # This prevents deleting volumes currently in use
        my $created = $vol->{created} // 0;
        # API 2.x returns ISO 8601 timestamp (e.g., "2025-01-15T10:30:00Z")
        # API 1.x returns epoch seconds
        if ($created && $created =~ /^\d{4}-\d{2}-\d{2}T/) {
            # Parse ISO 8601 to epoch (basic parsing without external modules)
            if ($created =~ /^(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2}):(\d{2})/) {
                require POSIX;
                require Time::Local;
                $created = eval { Time::Local::timegm($6, $5, $4, $3, $2 - 1, $1) } // 0;
            } else {
                $created = 0;
            }
        }
        my $age_seconds = time() - $created;

        if ($age_seconds > 3600) {  # 1 hour
            warn "Cleaning up orphaned temporary clone: $vol->{name} (age: ${age_seconds}s)\n";

            eval {
                # Get WWID for device cleanup
                my $wwid = $api->volume_get_wwid($vol->{name});
                if ($wwid) {
                    cleanup_lun_devices($wwid);
                }

                # Disconnect from all hosts
                my $connections = $api->volume_get_connections($vol->{name});
                for my $conn (@$connections) {
                    $api->volume_disconnect_host($vol->{name}, $conn->{name});
                }

                # Delete the volume
                $api->volume_delete($vol->{name});
            };
            if ($@) {
                warn "Failed to cleanup orphaned temp clone $vol->{name}: $@\n";
            }
        }
    }
}

#
# Multipath configuration
#

# Pure Storage multipath device configuration.
#
# The no_path_retry value is critical: without it, the device inherits the
# defaults section value, which on many sites is `queue` (NetApp's HA
# recommendation). Combined with a stale Pure device that's been deleted on
# the array, `queue` causes sync/blockdev/multipath -f to enter
# uninterruptible sleep. Always set no_path_retry explicitly here so the
# Pure device block overrides any dangerous default.
my $PURE_MULTIPATH_DEVICE = q{
    device {
        vendor "PURE"
        product "FlashArray"
        path_selector "queue-length 0"
        path_grouping_policy group_by_prio
        prio alua
        hardware_handler "1 alua"
        failback immediate
        no_path_retry 30
        fast_io_fail_tmo 5
        dev_loss_tmo 60
    }
};

# Plugin-managed multipath config marker. Bumping this version number causes
# _ensure_multipath_config to rewrite an existing file with the same marker
# so old installs (1.0.x) get the no_path_retry safety setting on upgrade.
use constant PURE_MULTIPATH_CONFIG_VERSION => '2';
use constant PURE_MULTIPATH_CONFIG_MARKER  => '# pure-multipath-config-version: ';

# Ensure multipath is configured for Pure Storage. Safe to call multiple
# times — it only writes if missing or if an existing plugin-managed file
# is older than the current version. Files NOT matching our marker are
# never overwritten (we don't touch user-edited or third-party configs).
sub _ensure_multipath_config {
    my $conf_file = '/etc/multipath.conf';
    my $conf_dir = '/etc/multipath/conf.d';
    my $pure_conf = "$conf_dir/pure-storage.conf";

    my $build_content = sub {
        my $c = "# Pure Storage FlashArray multipath configuration\n";
        $c .= "# Auto-generated by jt-pve-storage-purestorage plugin\n";
        $c .= PURE_MULTIPATH_CONFIG_MARKER . PURE_MULTIPATH_CONFIG_VERSION . "\n";
        $c .= "# DO NOT EDIT — to override, delete this file and put your own\n";
        $c .= "# config in /etc/multipath.conf or another file in conf.d/.\n\n";
        $c .= "devices {$PURE_MULTIPATH_DEVICE}\n";
        return $c;
    };

    # Method 1: Use conf.d directory if it exists (preferred, non-invasive)
    if (-d $conf_dir) {
        # Check if a plugin-managed file already exists and whether it's
        # the current version. If it's user-edited (no marker), leave it
        # alone — that's a sign the operator deliberately customised it.
        if (-f $pure_conf) {
            my $existing = '';
            if (open(my $fh, '<', $pure_conf)) {
                local $/;
                $existing = <$fh>;
                close($fh);
            }

            # Not plugin-managed → leave alone.
            unless ($existing =~ /\Q@{[ PURE_MULTIPATH_CONFIG_MARKER ]}\E(\d+)/) {
                return 1;
            }

            my $existing_version = $1;
            if ($existing_version eq PURE_MULTIPATH_CONFIG_VERSION) {
                return 1;  # already current
            }

            warn "Pure multipath config at $pure_conf is plugin-managed " .
                 "v$existing_version, upgrading to v" . PURE_MULTIPATH_CONFIG_VERSION .
                 " (adds no_path_retry / fast_io_fail_tmo safety settings)\n";
            # fall through to write
        }

        my $content = $build_content->();
        eval {
            open(my $fh, '>', $pure_conf) or die "Cannot write $pure_conf: $!";
            print $fh $content;
            close($fh);
        };
        if ($@) {
            warn "Failed to create Pure Storage multipath config: $@\n";
            return 0;
        }

        # Reload multipathd so the new device block takes effect.
        eval { multipath_reload(); };
        warn "Wrote Pure Storage multipath configuration: $pure_conf\n";
        return 1;
    }

    # Method 2: Modify /etc/multipath.conf directly
    if (-f $conf_file) {
        # Read existing config
        my $content;
        eval {
            open(my $fh, '<', $conf_file) or die "Cannot read $conf_file: $!";
            local $/;
            $content = <$fh>;
            close($fh);
        };
        if ($@) {
            warn "Failed to read multipath.conf: $@\n";
            return 0;
        }

        # Check if Pure Storage device already configured
        if ($content =~ /vendor\s+["']?PURE["']?/i) {
            return 1;  # Already configured
        }

        # Check if devices section exists
        if ($content =~ /^devices\s*\{/m) {
            # Add Pure device to existing devices section
            # Find the last closing brace of devices section and insert before it
            $content =~ s/(devices\s*\{.*?)(\n\})/$1$PURE_MULTIPATH_DEVICE$2/s;
        } else {
            # Append devices section
            $content .= "\n# Pure Storage FlashArray (auto-added by jt-pve-storage-purestorage)\n";
            $content .= "devices {$PURE_MULTIPATH_DEVICE}\n";
        }

        # Write updated config
        eval {
            open(my $fh, '>', $conf_file) or die "Cannot write $conf_file: $!";
            print $fh $content;
            close($fh);
        };
        if ($@) {
            warn "Failed to update multipath.conf: $@\n";
            return 0;
        }

        # Reload multipathd
        eval { multipath_reload(); };
        warn "Updated multipath.conf with Pure Storage configuration\n";
        return 1;
    }

    # Method 3: Create new /etc/multipath.conf
    my $content = "# Multipath configuration\n";
    $content .= "# Auto-generated by jt-pve-storage-purestorage plugin\n\n";
    $content .= "defaults {\n";
    $content .= "    user_friendly_names yes\n";
    $content .= "    find_multipaths yes\n";
    $content .= "}\n\n";
    $content .= "devices {$PURE_MULTIPATH_DEVICE}\n";

    eval {
        open(my $fh, '>', $conf_file) or die "Cannot write $conf_file: $!";
        print $fh $content;
        close($fh);
    };
    if ($@) {
        warn "Failed to create multipath.conf: $@\n";
        return 0;
    }

    # Reload multipathd
    eval { multipath_reload(); };
    warn "Created multipath.conf with Pure Storage configuration\n";
    return 1;
}

#
# Storage operations
#

sub activate_storage {
    my ($class, $storeid, $scfg, $cache) = @_;

    # Verify Pure Storage connectivity
    my $api = _get_api($scfg);

    # Verify we can connect to the array
    eval { $api->array_get(); };
    if ($@) {
        die "Cannot connect to Pure Storage array at $scfg->{'pure-portal'}: $@";
    }

    # Cleanup any orphaned temporary snapshot clones from previous crashes
    _cleanup_orphaned_temp_clones($scfg, $storeid, $api);

    # Ensure multipath is configured for Pure Storage
    _ensure_multipath_config();

    my $protocol = $scfg->{'pure-protocol'} // 'iscsi';

    if ($protocol eq 'fc') {
        # FC: Verify FC HBA is available
        unless (is_fc_available()) {
            die "FC protocol selected but no FC HBA found on this node. " .
                "Please install FC HBA or use 'pure-protocol iscsi'.";
        }

        # FC: Rescan for any existing LUNs
        rescan_fc_hosts(delay => 1);
        rescan_scsi_hosts(delay => 1);
        multipath_reload();

        # Trigger udev to update device info
        _udev_refresh();

        # Verify FC fabric connectivity to Pure Storage target ports
        my $fc_targets = eval { get_fc_targets(); } // [];
        my @online_targets = grep { $_->{is_target} && ($_->{port_state} // '') =~ /online/i } @$fc_targets;
        unless (@online_targets) {
            warn "WARNING: No FC target ports detected via fabric. " .
                 "Check FC switch zoning between this host and Pure Storage array.\n";
        }

    } else {
        # iSCSI: Get portals and login
        my $ports = $api->iscsi_get_ports();
        if (@$ports) {
            my $probe_timeout = $scfg->{'pure-portal-probe-timeout'} // 2;
            my @logged_in;
            my @unreachable;
            my @failed;

            for my $port (@$ports) {
                next unless $port->{portal};

                # Parse portal (format: ip:port or just ip)
                my ($ip, $port_num) = split(/:/, $port->{portal});
                $port_num //= 3260;

                my $target = $port->{iqn};
                next unless $target;

                # Fast path: if already logged in to this exact (portal,target)
                # pair, skip discovery+login. Discovery alone can take 30s on
                # an unresponsive portal and runs every time PVE re-activates
                # the storage (status polling, linked clones, etc.).
                my $portal_addr = "$ip:$port_num";
                if (eval { is_portal_logged_in($portal_addr, $target) }) {
                    push @logged_in, $portal_addr;
                    next;
                }

                # TCP pre-check: skip portals this host cannot reach so we do
                # NOT eat 30s discovery + 60s login timeouts per dead portal.
                # Pure exposes one iSCSI LIF per controller; with asymmetric
                # cabling (only one controller reachable) the dead LIFs would
                # otherwise stall every activate_storage() / status() call and
                # cascade into pvestatd timeouts that wedge the web UI.
                if ($probe_timeout > 0
                    && !probe_portal($ip, $port_num, timeout => $probe_timeout)) {
                    push @unreachable, $portal_addr;
                    next;
                }

                eval {
                    discover_targets($ip, port => $port_num);
                    login_target($ip, $target, port => $port_num);
                };
                if ($@) {
                    my $err = $@;
                    push @failed, "$portal_addr ($err)";
                    warn "Failed to connect to portal $ip: $err";
                } else {
                    push @logged_in, $portal_addr;
                }
            }

            if (@unreachable) {
                warn "Skipped " . scalar(@unreachable)
                    . " unreachable iSCSI portal(s) on Pure Storage array: "
                    . join(", ", @unreachable)
                    . " (no TCP response within ${probe_timeout}s).\n"
                    . "  If this is unexpected, check network/switch zoning"
                    . " between this node and the listed portals, or disable"
                    . " unused iSCSI services on the array.\n";
            }

            # If no portal is logged in and none was reachable, surface the
            # situation as a hard error rather than letting status() poll
            # forever against a storage that has zero usable paths.
            unless (@logged_in) {
                my $msg = "No iSCSI portal on Pure Storage is reachable from"
                    . " this node.";
                $msg .= " Unreachable: " . join(", ", @unreachable) if @unreachable;
                $msg .= " Failed: " . join("; ", @failed) if @failed;
                $msg .= "\n  Verify network connectivity to the array's iSCSI"
                    . " ports, or use 'pvesm set <storeid> --nodes <list>' to"
                    . " bind this storage only to nodes that can reach it.";
                die "$msg\n";
            }

            # Rescan for any existing LUNs after iSCSI login
            rescan_sessions();
            rescan_scsi_hosts(delay => 1);
            multipath_reload();

            # Trigger udev to update device info
            _udev_refresh();
        }
    }

    # Ensure host exists (common for both protocols)
    _ensure_host($scfg, $api);

    return 1;
}

sub deactivate_storage {
    my ($class, $storeid, $scfg, $cache) = @_;

    my $api = eval { _get_api($scfg); };
    unless ($api) {
        warn "Cannot connect to Pure Storage for cleanup: $@\n";
        return 1;  # Don't fail deactivation if API is unreachable
    }

    my $protocol = $scfg->{'pure-protocol'} // 'iscsi';

    # Get all volumes for this storage
    my $san_storage = $storeid;
    $san_storage =~ s/-/_/g;
    my $pod = $scfg->{'pure-pod'};
    my $pattern = "pve-${san_storage}-*";
    if ($pod) {
        $pattern = "${pod}::${pattern}";
    }

    my $volumes = eval { $api->volume_list($pattern); } // [];

    # Cleanup local devices for each volume (skip in-use devices to protect running VMs)
    my @skipped_in_use;
    for my $vol (@$volumes) {
        next unless $vol->{name};

        my $wwid = eval { $api->volume_get_wwid($vol->{name}); };
        next unless $wwid;

        # Check if device is in use before cleanup (protect running VMs)
        my $device = eval { get_device_by_wwid($wwid); };
        if ($device && -b $device && is_device_in_use($device)) {
            push @skipped_in_use, $vol->{name};
            next;
        }

        # Cleanup multipath and SCSI devices
        eval { cleanup_lun_devices($wwid); };
        if ($@) {
            warn "Failed to cleanup devices for $vol->{name}: $@\n";
        }
    }

    if (@skipped_in_use) {
        warn "Skipped cleanup for " . scalar(@skipped_in_use) . " in-use volume(s): " .
             join(', ', @skipped_in_use) . ". Ensure VMs are stopped before deactivating storage.\n";
    }

    # Disconnect volumes from this host on Pure Storage (skip in-use volumes)
    my $host_name = _get_host_name($scfg);
    my %in_use_set = map { $_ => 1 } @skipped_in_use;
    for my $vol (@$volumes) {
        next unless $vol->{name};
        next if $in_use_set{$vol->{name}};  # Don't disconnect in-use volumes

        eval {
            if ($api->volume_is_connected($vol->{name}, $host_name)) {
                $api->volume_disconnect_host($vol->{name}, $host_name);
            }
        };
        # Ignore errors - volume might already be disconnected
    }

    # Protocol-specific cleanup
    if ($protocol eq 'iscsi') {
        # For iSCSI: logout sessions if no more volumes are connected to this host
        my $remaining = eval { $api->host_get_volumes($host_name); } // [];

        if (@$remaining == 0) {
            # No more volumes connected, safe to logout iSCSI sessions
            my $ports = eval { $api->iscsi_get_ports(); } // [];
            for my $port (@$ports) {
                next unless $port->{portal} && $port->{iqn};
                my ($ip, $port_num) = split(/:/, $port->{portal});
                $port_num //= 3260;

                eval { logout_target($ip, $port->{iqn}, port => $port_num); };
                # Ignore logout errors
            }
            warn "Logged out from Pure Storage iSCSI sessions\n";
        } else {
            warn "Keeping iSCSI sessions active - " . scalar(@$remaining) .
                 " volumes still connected to host '$host_name'\n";
        }
    } elsif ($protocol eq 'fc') {
        # FC: no session logout needed (fabric-level connections)
        # Just log the deactivation for admin visibility
        my $remaining = eval { $api->host_get_volumes($host_name); } // [];
        if (@$remaining == 0) {
            warn "FC storage deactivated, all volumes disconnected from host '$host_name'\n";
        } else {
            warn "FC storage deactivated, local devices cleaned up. " .
                 scalar(@$remaining) . " volumes still connected on host '$host_name'\n";
        }
    }

    # Flush unused multipath maps
    eval { multipath_flush(); };

    return 1;
}

sub status {
    my ($class, $storeid, $scfg, $cache) = @_;

    # Fail-fast: if we cannot even build the API client (auth/host/etc) we
    # MUST NOT block PVE status polling. Return inactive immediately so the
    # web UI keeps responding instead of hanging on the API timeout.
    my $api = eval { _get_api($scfg); };
    if (!$api) {
        warn "Failed to connect to Pure Storage: $@";
        return (0, 0, 0, 0);
    }

    my $pod = $scfg->{'pure-pod'};

    eval {
        my $capacity = $api->get_managed_capacity($pod);

        $cache->{total}     = $capacity->{total};
        $cache->{used}      = $capacity->{used};
        $cache->{avail}     = $capacity->{available};
    };
    if ($@) {
        warn "Failed to get storage status: $@";
        return (0, 0, 0, 0);
    }

    # Run periodic background cleanup using the double-fork pattern: the
    # intermediate child forks the actual worker (grandchild) and exits
    # immediately. The grandchild gets reparented to init and is reaped
    # automatically — no zombie, and status() never blocks on cleanup work.
    my $intermediate_pid = fork();
    if (defined $intermediate_pid && $intermediate_pid == 0) {
        my $grandchild_pid = fork();
        if (defined $grandchild_pid && $grandchild_pid == 0) {
            # Grandchild — do the actual cleanup work.
            eval { _cleanup_orphaned_temp_clones($scfg, $storeid, $api); };
            eval { _cleanup_orphaned_devices($api, $storeid, $scfg); };
            POSIX::_exit(0);
        }
        # Intermediate exits immediately, leaving grandchild orphaned.
        POSIX::_exit(0);
    }
    waitpid($intermediate_pid, 0) if defined $intermediate_pid;

    return ($cache->{total}, $cache->{avail}, $cache->{used}, 1);
}

#
# Volume management
#

sub alloc_image {
    my ($class, $storeid, $scfg, $vmid, $fmt, $name, $size) = @_;

    die "unsupported format '$fmt'" if $fmt ne 'raw';

    my $api = _get_api($scfg);

    # Size is in kilobytes, convert to bytes
    my $size_bytes = $size * 1024;

    my $pure_volname_base;
    my $pve_volname;

    # Check if this is a special volume type (state, cloudinit)
    if ($name && $name =~ /^vm-(\d+)-state-(.+)$/) {
        # VM state volume for RAM snapshot
        my ($state_vmid, $snapname) = ($1, $2);
        $pure_volname_base = pve_volname_to_pure($storeid, $name);
        $pve_volname = $name;
    } elsif ($name && $name =~ /^vm-(\d+)-cloudinit$/) {
        # Cloud-init volume
        $pure_volname_base = pve_volname_to_pure($storeid, $name);
        $pve_volname = $name;
    } else {
        # Regular disk volume
        my $diskid;
        if ($name) {
            my $parsed = _parse_volname($name);
            $diskid = $parsed->{diskid} if $parsed;
        }
        $diskid //= _find_free_diskid($scfg, $storeid, $vmid);
        $pure_volname_base = encode_volume_name($storeid, $vmid, $diskid);
        $pve_volname = "vm-${vmid}-disk-${diskid}";
    }

    # Add pod prefix if configured
    my $pure_volname = _get_full_volname($scfg, $pure_volname_base);

    # Check if volume already exists
    my $existing = eval { $api->volume_get($pure_volname); };
    if ($existing) {
        # For state/cloudinit volumes, try to cleanup orphaned volumes from previous failed attempts
        if ($name && ($name =~ /^vm-\d+-state-/ || $name =~ /^vm-\d+-cloudinit$/)) {
            warn "Found orphaned state/cloudinit volume '$pure_volname', attempting cleanup...\n";

            # Try to disconnect and delete the orphaned volume
            eval {
                my $connections = $api->volume_get_connections($pure_volname);
                for my $conn (@$connections) {
                    $api->volume_disconnect_host($pure_volname, $conn->{name});
                }
                $api->volume_delete($pure_volname, skip_eradicate => 1);
            };
            if ($@) {
                die "Volume '$pure_volname' already exists and cleanup failed: $@\n" .
                    "Please manually delete this volume from Pure Storage UI.";
            }
            # Volume cleaned up, continue with creation
            warn "Orphaned volume cleaned up successfully, proceeding with creation\n";
        } else {
            die "Volume '$pure_volname' already exists on Pure Storage.";
        }
    }

    # Create volume, with disk-id collision retry for regular VM disks.
    # _find_free_diskid + volume_create has a TOCTOU window: two concurrent
    # alloc_image() calls for the same VM can both pick the same disk ID and
    # one will fail with "already exists". Catch that and bump the diskid.
    my $is_regular_disk = $pve_volname && $pve_volname =~ /^vm-\d+-disk-(\d+)$/;
    my $create_attempts = 0;
    while (1) {
        $create_attempts++;
        eval { $api->volume_create($pure_volname, $size_bytes); };
        last unless $@;

        my $err = $@;
        if ($is_regular_disk && $create_attempts < 5 &&
            $err =~ /already exists|duplicate|conflict|409/i) {
            warn "alloc_image: disk-id collision on '$pure_volname', retrying with next free id\n";
            my $new_diskid = _find_free_diskid($scfg, $storeid, $vmid);
            $pure_volname_base = encode_volume_name($storeid, $vmid, $new_diskid);
            $pure_volname = _get_full_volname($scfg, $pure_volname_base);
            $pve_volname = "vm-${vmid}-disk-${new_diskid}";
            next;
        }

        die "Failed to create volume '$pure_volname': " .
            PVE::Storage::Custom::PureStorage::API::translate_pure_error($err);
    }

    # Connect volume to all cluster hosts for migration support
    my ($connected_hosts, $failed_hosts);
    eval {
        ($connected_hosts, $failed_hosts) = _connect_to_all_hosts($scfg, $api, $pure_volname);
    };
    if ($@) {
        # Cleanup on failure. _connect_to_all_hosts may have partially
        # succeeded — disconnect every host it managed to connect before
        # destroying the volume, otherwise the orphaned host connections
        # cause ghost LUNs on other cluster nodes (Bug E from to_pure3).
        my $conn_err = $@;
        warn "Volume host connection failed, cleaning up volume '$pure_volname'\n";
        _disconnect_from_all_hosts($api, $pure_volname);
        eval { $api->volume_delete($pure_volname, skip_eradicate => 1); };
        die "Failed to connect volume to host: $conn_err";
    }

    # Log warning if some hosts failed (non-fatal, migration may be affected)
    if ($failed_hosts && @$failed_hosts) {
        warn "Warning: Volume '$pure_volname' not connected to hosts: " .
             join(', ', @$failed_hosts) . ". Live migration to these nodes may fail.\n";
    }

    # For state/cloudinit volumes, we need to ensure the device is available immediately
    # because PVE will try to use it right after alloc_image returns
    if ($name && ($name =~ /^vm-\d+-state-/ || $name =~ /^vm-\d+-cloudinit$/)) {
        my $protocol = $scfg->{'pure-protocol'} // 'iscsi';

        # Longer delay for Pure Storage to propagate the connection to all controllers
        warn "Waiting for Pure Storage to propagate connection...\n";
        sleep(3);

        # Get WWID for device identification
        my $wwid = eval { $api->volume_get_wwid($pure_volname); };
        unless ($wwid) {
            warn "Cannot get WWID for state volume '$pure_volname', cleaning up\n";
            # Disconnect first to avoid leaving orphaned host connections
            # that turn into ghost LUNs on other cluster nodes (Bug E).
            _disconnect_from_all_hosts($api, $pure_volname);
            eval { $api->volume_delete($pure_volname, skip_eradicate => 1); };
            die "Failed to get WWID for state volume '$pve_volname'.";
        }
        warn "State volume WWID: $wwid\n";

        # For iSCSI, verify sessions exist
        if ($protocol eq 'iscsi') {
            my $sessions = eval { get_sessions(); };
            if (!$sessions || @$sessions == 0) {
                warn "No active iSCSI sessions found! Attempting to re-establish...\n";
                # Try to re-activate storage to establish sessions. Use the
                # same TCP pre-check as activate_storage() so unreachable
                # portals are skipped fast instead of stalling alloc_image.
                my $probe_timeout = $scfg->{'pure-portal-probe-timeout'} // 2;
                eval {
                    my $ports = $api->iscsi_get_ports();
                    for my $port (@$ports) {
                        next unless $port->{portal} && $port->{iqn};
                        my ($ip, $port_num) = split(/:/, $port->{portal});
                        $port_num //= 3260;
                        if ($probe_timeout > 0
                            && !probe_portal($ip, $port_num, timeout => $probe_timeout)) {
                            warn "Skipping unreachable portal $ip:$port_num\n";
                            next;
                        }
                        eval {
                            discover_targets($ip, port => $port_num);
                            login_target($ip, $port->{iqn}, port => $port_num);
                        };
                    }
                };
                sleep(2);
                $sessions = eval { get_sessions(); };
                warn "After re-establish: " . (@$sessions // 0) . " iSCSI sessions active\n";
            } else {
                warn "Found " . scalar(@$sessions) . " active iSCSI sessions\n";
            }
        }

        # Wait for device with protocol-specific rescan in the loop
        my $timeout = $scfg->{'pure-device-timeout'} // 60;
        my $interval = 3;
        my $start_time = time();
        my $device;
        my $loop_count = 0;

        while ((time() - $start_time) < $timeout) {
            $loop_count++;

            # Protocol-specific rescan (must be in the loop!)
            if ($protocol eq 'fc') {
                warn "[$loop_count] Rescanning FC hosts...\n" if $loop_count <= 3;
                eval { rescan_fc_hosts(delay => 1); };
            } else {
                warn "[$loop_count] Rescanning iSCSI sessions...\n" if $loop_count <= 3;
                eval { rescan_sessions(); };
                # Give iSCSI time to process the rescan
                sleep(1);
            }

            # SCSI host rescan and multipath reload
            warn "[$loop_count] Rescanning SCSI hosts and multipath...\n" if $loop_count <= 3;
            eval { rescan_scsi_hosts(delay => 1); };
            eval { multipath_reload(); };

            # Trigger udev to update WWIDs (fixes stale WWID cache issue)
            _udev_refresh();

            # Check for device
            $device = get_multipath_device($wwid);
            $device //= get_device_by_wwid($wwid);

            if ($device && -b $device) {
                warn "Device found: $device\n";
                last;  # Device found!
            }

            warn "[$loop_count] Device not yet available, waiting...\n" if $loop_count <= 3;
            sleep($interval);
        }

        unless ($device && -b $device) {
            # Cleanup on failure
            warn "State volume device did not appear within ${timeout}s, cleaning up '$pure_volname'\n";

            # Collect diagnostic info before cleanup
            my $diag = "";
            if ($protocol eq 'iscsi') {
                my $sessions = eval { get_sessions(); } // [];
                $diag = "Active iSCSI sessions: " . scalar(@$sessions);
            } elsif ($protocol eq 'fc') {
                my $fc_wwpns = eval { get_fc_wwpns(online_only => 1); } // [];
                my $fc_targets = eval { get_fc_targets(); } // [];
                my @online_tgts = grep { $_->{is_target} && ($_->{port_state} // '') =~ /online/i } @$fc_targets;
                $diag = "Online FC HBA ports: " . scalar(@$fc_wwpns) .
                        ", Visible FC targets: " . scalar(@online_tgts);
            }

            # Disconnect from all hosts before delete (Bug E — orphaned
            # connections become ghost LUNs on other cluster nodes).
            _disconnect_from_all_hosts($api, $pure_volname);
            eval { $api->volume_delete($pure_volname, skip_eradicate => 1); };
            my $debug_cmds = "  multipath -ll (check multipath devices)\n" .
                "  ls -la /dev/disk/by-id/ | grep $wwid (check device symlinks)";
            if ($protocol eq 'fc') {
                $debug_cmds = "  cat /sys/class/fc_host/host*/port_state (check FC port status)\n" .
                    "  cat /sys/class/fc_remote_ports/rport-*/port_state (check FC targets)\n" .
                    $debug_cmds;
            } else {
                $debug_cmds = "  iscsiadm -m session (check iSCSI sessions)\n" .
                    "  iscsiadm -m session -P3 (show LUNs)\n" .
                    $debug_cmds;
            }
            die "Failed to discover device for state volume '$pve_volname' (WWID: $wwid). $diag\n" .
                "Check $protocol connectivity and multipath configuration.\n" .
                "Debug commands:\n" . $debug_cmds;
        }
    }

    # Return PVE volume name
    return $pve_volname;
}

sub free_image {
    my ($class, $storeid, $scfg, $volname, $isBase, $format) = @_;

    my $api = _get_api($scfg);
    my $pure_volname_base = pve_volname_to_pure($storeid, $volname);
    my $pure_volname = _get_full_volname($scfg, $pure_volname_base);

    # Check if volume exists on Pure Storage
    my $vol = eval { $api->volume_get($pure_volname); };
    unless ($vol) {
        warn "Volume '$pure_volname' not found on Pure Storage, may have been already deleted\n";
        return undef;
    }

    # Step 1: Get the WWID and verify the local device is not in use.
    my $wwid = eval { $api->volume_get_wwid($pure_volname); };

    if ($wwid) {
        my $device = get_device_by_wwid($wwid);
        if ($device && -b $device && is_device_in_use($device)) {
            # Provide detailed usage info so operators can self-diagnose.
            # Common case: host LVM auto-activated guest VGs on upgraded
            # PVE nodes missing global_filter in lvm.conf.
            my $details = eval { get_device_usage_details($device) } // '';
            my $msg = "Cannot delete volume '$volname': device $device is still in use.\n";
            if ($details) {
                $msg .= "\n$details\n";
            } else {
                $msg .= "Ensure VM is stopped and disk is not mounted.\n";
            }
            die $msg;
        }
    }

    # Step 2: Capture the multipath slave list BEFORE any unmap. After we
    # disconnect the volume on the array, an iSCSI rescan can make the
    # multipath device disappear and we lose the ability to enumerate the
    # underlying SCSI devices. We need that list to remove residual /dev/sdX
    # entries in step 5.
    my @scsi_slaves;
    my $local_mpath;
    if ($wwid) {
        $local_mpath = eval { get_multipath_device($wwid); };
        if ($local_mpath) {
            my $slaves_ref = eval { get_multipath_slaves($local_mpath) };
            @scsi_slaves = @{ $slaves_ref // [] };
        }
    }

    # Step 3: Disconnect from ALL hosts FIRST, BEFORE local cleanup.
    # If we cleaned local devices first and then disconnected, an in-flight
    # iSCSI rescan (e.g. from another node activating storage) could
    # re-import the LUN and recreate the multipath device behind us.
    my $connections = eval { $api->volume_get_connections($pure_volname); };
    if ($connections && @$connections) {
        for my $conn (@$connections) {
            eval { $api->volume_disconnect_host($pure_volname, $conn->{name}); };
            if ($@) {
                warn "Warning: Failed to disconnect $pure_volname from host $conn->{name}: $@\n";
            }
        }
    }

    # Step 4: Cleanup local multipath device.
    if ($wwid) {
        eval { cleanup_lun_devices($wwid); };
        if ($@) {
            warn "Warning: Failed to cleanup local devices for $volname: $@\n";
        }

        # Step 5: Remove any residual SCSI slave devices using the captured
        # list. cleanup_lun_devices already does this, but only after the
        # multipath -f succeeds. If multipath -f fell back to dmsetup, the
        # slave loop inside cleanup_lun_devices runs against an already-gone
        # /sys/block/.../slaves directory, so the slaves can leak.
        for my $slave (@scsi_slaves) {
            if (-b $slave) {
                eval { remove_scsi_device($slave); };
            }
        }

        # Step 6: Final multipath reload to settle any leftover state.
        eval { multipath_reload(); };
    }

    # Step 7: Destroy volume on Pure Storage (soft delete — Pure auto-eradicates
    # after the array's configured delay, default 24h, allowing recovery via
    # the Pure UI if this turns out to be wrong).
    eval { $api->volume_delete($pure_volname, skip_eradicate => 1); };
    if ($@) {
        die "Failed to destroy volume '$pure_volname': $@";
    }

    # Step 8: Conditional WWID untrack. If our local cleanup left a stale
    # device behind (e.g. multipath -f and dmsetup both failed), KEEP the
    # WWID tracked so the next status() orphan-cleanup pass can retry.
    # Otherwise untrack so we don't keep churning over a dead entry.
    if ($wwid) {
        my $still_present = eval { get_multipath_device($wwid); };
        if ($still_present) {
            warn "free_image: local multipath device for WWID $wwid still exists after cleanup; " .
                 "keeping WWID tracked so orphan cleanup can retry.\n";
        } else {
            eval { _untrack_wwid($storeid, $wwid); };
        }
    }

    # Check if this was the last disk for the VM, if so cleanup config volumes
    # Extract VMID from volname (vm-{vmid}-disk-{n} or base-{vmid}-disk-{n})
    if ($volname =~ /^(?:vm|base)-(\d+)-disk-\d+$/) {
        my $vmid = $1;

        # Check if any other disks remain for this VM
        my $san_storage = $storeid;
        $san_storage =~ s/-/_/g;
        my $disk_pattern = "pve-${san_storage}-${vmid}-disk*";
        my $pod = $scfg->{'pure-pod'};

        my $remaining = eval { $api->volume_list(pattern => $disk_pattern, pod => $pod); } // [];
        # Filter out destroyed volumes
        $remaining = [grep { !$_->{destroyed} } @$remaining];

        if (!@$remaining) {
            # No more disks, cleanup all config volumes for this VM
            eval { _cleanup_vm_config_volumes($api, $scfg, $storeid, $vmid); };
            if ($@) {
                warn "Config volume cleanup failed (non-fatal): $@\n";
            }
        }
    }

    return undef;
}

sub list_images {
    my ($class, $storeid, $scfg, $vmid, $vollist, $cache) = @_;

    my $api = _get_api($scfg);

    my @res;

    # Build filter pattern
    my $san_storage = $storeid;
    $san_storage =~ s/-/_/g;

    my $pod = $scfg->{'pure-pod'};
    my $pattern;
    if ($vmid) {
        $pattern = "pve-${san_storage}-${vmid}-*";
    } else {
        $pattern = "pve-${san_storage}-*";
    }

    # Add pod prefix to pattern if configured
    if ($pod) {
        $pattern = "${pod}::${pattern}";
    }

    my $volumes = $api->volume_list($pattern);

    # Batch query for template snapshots (optimization: single API call)
    # Query all pve-base snapshots for this storage
    my %is_template;
    my $batch_query_ok = 0;
    eval {
        my $base_pattern = "pve-${san_storage}-*.pve-base";
        # Add pod prefix if configured
        if ($pod) {
            $base_pattern = "${pod}::${base_pattern}";
        }
        my $base_snaps = $api->snapshot_list(undef, $base_pattern);
        $batch_query_ok = 1;  # Query succeeded (even if empty result)
        for my $snap (@$base_snaps) {
            next unless $snap->{name};
            # Extract volume name from snapshot name (remove .pve-base suffix)
            if ($snap->{name} =~ /^(.+)\.pve-base$/) {
                $is_template{$1} = 1;
            }
        }
    };
    # Fallback to individual queries ONLY if batch query failed (not if just
    # empty). Bound the per-volume loop with a wall-clock deadline so a slow
    # array doesn't cascade timeouts across hundreds of volumes; any volume
    # we don't get to is treated as non-template.
    if ($@ && !$batch_query_ok) {
        warn "Batch snapshot query failed, falling back to individual queries: $@\n";
        my $deadline = time() + 10;
        for my $vol (@$volumes) {
            if (time() > $deadline) {
                warn "list_images: template detection deadline reached, " .
                     "skipping remaining volumes (treated as non-template)\n";
                last;
            }
            next unless $vol->{name};
            my $snap_name = "$vol->{name}.pve-base";
            my $snap = eval { $api->snapshot_get($snap_name); };
            $is_template{$vol->{name}} = 1 if $snap;
        }
    }

    for my $vol (@$volumes) {
        next unless $vol->{name};

        # Strip pod prefix before decoding
        my $volname_for_decode = _strip_pod_prefix($scfg, $vol->{name});
        my $decoded = decode_volume_name($volname_for_decode);
        next unless $decoded;

        # Check if volume belongs to requested storage
        next if $decoded->{storage} ne $san_storage;

        # Generate PVE volume name
        my $pve_volname;
        if ($decoded->{type} eq 'disk') {
            my $prefix = $is_template{$vol->{name}} ? 'base' : 'vm';
            $pve_volname = "${prefix}-$decoded->{vmid}-disk-$decoded->{diskid}";
        } else {
            $pve_volname = pure_to_pve_volname($volname_for_decode);
        }
        next unless $pve_volname;

        my $volid = "$storeid:$pve_volname";

        # Filter by vollist if provided
        if ($vollist) {
            my $dominated = 0;
            foreach my $match_pattern (@$vollist) {
                if ($volid =~ /^\Q$match_pattern\E/) {
                    $dominated = 1;
                    last;
                }
            }
            next unless $dominated;
        }

        # API 2.x uses 'provisioned' for size, API 1.x uses 'size'
        # API 2.x uses 'space.total_physical' for used, API 1.x uses 'volumes' or 'total'
        my $vol_size = $vol->{provisioned} // $vol->{size} // 0;
        my $vol_used = $vol->{space}{total_physical} // $vol->{space}{total_used} // $vol->{volumes} // $vol->{total} // 0;

        push @res, {
            volid  => $volid,
            format => 'raw',
            size   => $vol_size,
            vmid   => $decoded->{vmid},
            used   => $vol_used,
        };
    }

    return \@res;
}

sub volume_size_info {
    my ($class, $scfg, $storeid, $volname, $timeout) = @_;

    my $api = _get_api($scfg);
    my $pure_volname = _get_full_volname($scfg, pve_volname_to_pure($storeid, $volname));

    my $vol = $api->volume_get($pure_volname);
    die "Volume '$pure_volname' not found" unless $vol;

    # API 2.x uses 'provisioned' for size, API 1.x uses 'size'
    my $vol_size = $vol->{provisioned} // $vol->{size} // 0;
    my $vol_used = $vol->{space}{total_physical} // $vol->{space}{total_used} // $vol->{volumes} // $vol->{total} // 0;

    return wantarray ?
        ($vol_size, 'raw', $vol_used, undef) :
        $vol_size;
}

sub volume_resize {
    my ($class, $scfg, $storeid, $volname, $size, $running) = @_;

    # Pure Storage supports online resize, no need to check $running
    # Note: $running parameter is kept for API compatibility

    my $api = _get_api($scfg);
    my $pure_volname = _get_full_volname($scfg, pve_volname_to_pure($storeid, $volname));

    # Get current size to prevent shrinking
    my $vol = $api->volume_get($pure_volname);
    die "Volume '$pure_volname' not found" unless $vol;

    # API 2.x uses 'provisioned', API 1.x uses 'size'
    my $current_size = $vol->{provisioned} // $vol->{size} // 0;

    if ($size < $current_size) {
        die "Cannot shrink volume: Pure Storage does not support volume shrinking.";
    }

    if ($size == $current_size) {
        return 1;
    }

    # Resize volume (Pure Storage supports online resize)
    $api->volume_resize($pure_volname, $size);

    # Pick up the new size on the host. Note: there are TWO different SCSI
    # rescan operations and they are NOT interchangeable:
    #
    #   - host scan (echo - - - > /sys/class/scsi_host/hostN/scan)
    #     -> discovers NEW devices on a SCSI host. Use this after
    #        alloc_image / activate_volume / clone_image.
    #
    #   - per-device rescan (echo 1 > /sys/block/sdX/device/rescan)
    #     -> re-reads attributes (capacity!) of an EXISTING device. Use
    #        this after volume_resize / volume_snapshot_rollback.
    #
    # The previous implementation used host scan after a resize, which
    # never updated the existing device's capacity. The array showed the
    # new size, the multipath device showed the old size, and QEMU's
    # block_resize then failed with "Cannot grow device files".
    #
    # Also: after refreshing each underlying SCSI path, the multipath
    # layer above still reports the old size until you tell multipathd
    # explicitly. multipath_resize_map() does that.
    if ($running) {
        my $wwid = eval { $api->volume_get_wwid($pure_volname); };
        if ($wwid) {
            my $device = get_device_by_wwid($wwid);
            if ($device && -b $device) {
                # 1. Per-slave SCSI rescan (re-reads capacity from each path)
                my $slaves = eval { get_multipath_slaves($device) } // [];
                for my $slave (@$slaves) {
                    eval { rescan_scsi_device($slave); };
                }

                # 2. Tell multipathd to update the map size on top of the
                #    refreshed paths.
                eval { multipath_resize_map($device); };

                # 3. udev refresh so /dev/disk/by-id/ size attributes update
                _udev_refresh();
            }
        }
    }

    return 1;
}

#
# Volume activation
#

sub activate_volume {
    my ($class, $storeid, $scfg, $volname, $snapname, $cache) = @_;

    my $api = _get_api($scfg);
    my $pure_volname = _get_full_volname($scfg, pve_volname_to_pure($storeid, $volname));
    my $protocol = $scfg->{'pure-protocol'} // 'iscsi';

    # If snapshot access requested, path() will handle temp clone creation
    # Just call path() to ensure the device is ready
    if ($snapname) {
        my ($device, $vmid, $format) = $class->path($scfg, $volname, $storeid, $snapname);
        die "Failed to activate snapshot access for $volname\@$snapname" unless $device && -b $device;
        return 1;
    }

    # Verify volume exists on Pure Storage
    my $vol = eval { $api->volume_get($pure_volname); };
    unless ($vol) {
        die "Cannot activate volume: '$pure_volname' not found on Pure Storage. " .
            "The volume may have been deleted externally.";
    }

    # Ensure volume is connected to this node's host
    my $host = _get_host_name($scfg);
    my $was_connected = $api->volume_is_connected($pure_volname, $host);

    unless ($was_connected) {
        eval { $api->volume_connect_host($pure_volname, $host); };
        if ($@) {
            if ($@ =~ /quota/i || $@ =~ /limit/i) {
                die "Cannot activate volume: connection limit exceeded. " .
                    "Pure Storage may have reached maximum LUN connections. Error: $@";
            }
            die "Failed to connect volume '$pure_volname' to host '$host': $@";
        }
    }

    # Rescan for the device based on protocol
    if ($protocol eq 'fc') {
        eval { rescan_fc_hosts(delay => 1); };
        if ($@) {
            warn "Warning: FC host rescan failed: $@\n";
        }
    } else {
        eval { rescan_sessions(); };
        if ($@) {
            warn "Warning: iSCSI session rescan failed: $@\n";
        }
    }

    # Common: Rescan SCSI hosts and reload multipath
    eval { rescan_scsi_hosts(); };
    if ($@) {
        warn "Warning: SCSI host rescan failed: $@\n";
    }

    eval { multipath_reload(); };
    if ($@) {
        warn "Warning: Multipath reload failed: $@\n";
    }

    # Get volume WWID for device identification
    my $wwid = eval { $api->volume_get_wwid($pure_volname); };
    unless ($wwid) {
        die "Cannot get WWID for volume '$pure_volname'. " .
            "This may indicate a Pure Storage API issue.";
    }

    # Wait for device to appear with protocol-specific rescan in loop
    my $timeout = $scfg->{'pure-device-timeout'} // 60;
    my %wait_opts = (timeout => $timeout);

    # Add protocol-specific rescan callback
    if ($protocol eq 'fc') {
        $wait_opts{fc_rescan} = sub { rescan_fc_hosts(delay => 1); };
    } else {
        $wait_opts{iscsi_rescan} = sub { rescan_sessions(); };
    }

    my $device = wait_for_multipath_device($wwid, %wait_opts);

    unless ($device) {
        # Device discovery failed - provide detailed diagnostics
        my $diag_msg = "Device for volume '$pure_volname' (WWID: $wwid) did not appear within ${timeout}s.\n";
        $diag_msg .= "Diagnostics:\n";
        $diag_msg .= "  - Protocol: $protocol\n";
        $diag_msg .= "  - Host: $host\n";
        $diag_msg .= "  - Volume connected: " . ($was_connected ? "yes (pre-existing)" : "yes (just connected)") . "\n";

        if ($protocol eq 'fc') {
            $diag_msg .= "  - Check: FC HBA status, FC switch zoning, fiber connections\n";
            $diag_msg .= "  - Try: 'cat /sys/class/fc_host/host*/port_state' to verify FC port status\n";
        } else {
            $diag_msg .= "  - Check: iSCSI sessions, network connectivity, target portal accessibility\n";
            $diag_msg .= "  - Try: 'iscsiadm -m session' to verify iSCSI sessions\n";
        }
        $diag_msg .= "  - Try: 'multipath -ll' to check multipath device status\n";

        die $diag_msg;
    }

    return 1;
}

sub deactivate_volume {
    my ($class, $storeid, $scfg, $volname, $snapname, $cache) = @_;

    my $api = _get_api($scfg);
    my $pure_volname = _get_full_volname($scfg, pve_volname_to_pure($storeid, $volname));

    # If this was a snapshot access, cleanup the temporary clone
    if ($snapname) {
        _cleanup_temp_snap_clone($scfg, $storeid, $volname, $snapname);
        return 1;
    }

    my $wwid = eval { $api->volume_get_wwid($pure_volname); };

    if ($wwid) {
        my $device = get_device_by_wwid($wwid);
        if ($device && -b $device) {
            # Use timeout-bounded run_command — bare system('sync')/blockdev
            # can enter D state on a wedged device.
            eval { PVE::Tools::run_command(['/bin/sync'], timeout => 10); };
            eval { PVE::Tools::run_command(['/sbin/blockdev', '--flushbufs', $device], timeout => 10); };
        }
    }

    return 1;
}

# Track temporary clones created for snapshot access (for cleanup)
my %_temp_snap_clones;

sub path {
    my ($class, $scfg, $volname, $storeid, $snapname) = @_;

    my $parsed = _parse_volname($volname);
    die "Cannot parse volume name: $volname" unless $parsed;

    my $api = _get_api($scfg);
    my $pure_volname = _get_full_volname($scfg, pve_volname_to_pure($storeid, $volname));

    my $target_vol;
    my $is_temp_clone = 0;

    if ($snapname) {
        # Snapshot access requested - Pure snapshots cannot be mounted directly
        # Create a temporary clone from the snapshot for reading
        my $snap_suffix = encode_snapshot_name($snapname);
        my $full_snap_name = "${pure_volname}.${snap_suffix}";

        # Check if snapshot exists
        my $snap = eval { $api->snapshot_get($full_snap_name); };
        unless ($snap) {
            die "Snapshot '$full_snap_name' not found on Pure Storage";
        }

        # Create temporary clone name with timestamp for uniqueness
        my $timestamp = time();
        my $temp_clone_name = "${pure_volname}-temp-snap-access-${timestamp}-$$";

        # Check if we already have a temp clone for this snapshot
        my $cache_key = "${storeid}:${volname}:${snapname}";
        if ($_temp_snap_clones{$cache_key}) {
            $target_vol = $_temp_snap_clones{$cache_key};
            # Verify it still exists
            my $existing = eval { $api->volume_get($target_vol); };
            unless ($existing) {
                delete $_temp_snap_clones{$cache_key};
                $target_vol = undef;
            }
        }

        unless ($target_vol) {
            # Create temporary clone from snapshot
            eval { $api->volume_clone($temp_clone_name, $full_snap_name); };
            if ($@) {
                die "Failed to create temporary clone for snapshot access: $@";
            }

            # Connect to current host
            my $host = _get_host_name($scfg);
            eval { $api->volume_connect_host($temp_clone_name, $host); };
            if ($@) {
                # Save the original error before any inner eval, otherwise
                # the cleanup eval below clobbers $@ and we die with the
                # wrong message.
                my $connect_err = $@;
                # Defensive disconnect: volume_connect_host may have
                # actually made the connection on the array even though
                # the response was lost (network glitch / API timeout).
                # Without this, the cleanup volume_delete leaves an
                # orphaned host connection — same Bug E pattern as
                # alloc_image / clone_image.
                _disconnect_from_all_hosts($api, $temp_clone_name);
                eval { $api->volume_delete($temp_clone_name, skip_eradicate => 1); };
                die "Failed to connect temporary clone to host: $connect_err";
            }

            $target_vol = $temp_clone_name;
            $_temp_snap_clones{$cache_key} = $target_vol;
            $is_temp_clone = 1;
        }
    } else {
        $target_vol = $pure_volname;
    }

    # Get WWID
    my $wwid = eval { $api->volume_get_wwid($target_vol); };
    if (!$wwid) {
        die "Volume '$target_vol' not found on Pure Storage or has no WWID";
    }

    # Rescan if this is a new temp clone
    if ($is_temp_clone) {
        my $protocol = $scfg->{'pure-protocol'} // 'iscsi';
        if ($protocol eq 'fc') {
            rescan_fc_hosts(delay => 1);
        } else {
            rescan_sessions();
        }
        rescan_scsi_hosts();
        multipath_reload();

        # Trigger udev to update WWIDs (fixes stale WWID cache issue)
        _udev_refresh();
    }

    # Try multipath first
    my $device = get_multipath_device($wwid);
    $device //= get_device_by_wwid($wwid);

    # Retry loop for newly-attached LUNs. After alloc_image() creates a LUN
    # the kernel may not have discovered it yet; one rescan is often not
    # enough, especially with multiple iSCSI portals or FC fabrics.
    if (!$device || ! -b $device) {
        my $max_wait = $scfg->{'pure-device-timeout'} // 30;
        my $start = time();
        my $protocol = $scfg->{'pure-protocol'} // 'iscsi';

        while ((time() - $start) < $max_wait) {
            if ($protocol eq 'fc') {
                eval { rescan_fc_hosts(delay => 1); };
            } else {
                eval { rescan_sessions(); };
            }
            eval { rescan_scsi_hosts(); };
            eval { multipath_reload(); };

            # Trigger udev to update WWIDs (fixes stale WWID cache issue)
            _udev_refresh();

            $device = get_multipath_device($wwid);
            $device //= get_device_by_wwid($wwid);
            last if $device && -b $device;

            sleep(2);
        }
    }

    # Wait for device if temp clone (separate logic because temp clones often
    # need a longer wait — the array has to provision the clone first).
    if ($is_temp_clone && (!$device || ! -b $device)) {
        my $timeout = $scfg->{'pure-device-timeout'} // 60;
        my $protocol = $scfg->{'pure-protocol'} // 'iscsi';
        my %wait_opts = (timeout => $timeout);

        if ($protocol eq 'fc') {
            $wait_opts{fc_rescan} = sub { rescan_fc_hosts(delay => 1); };
        } else {
            $wait_opts{iscsi_rescan} = sub { rescan_sessions(); };
        }

        $device = wait_for_multipath_device($wwid, %wait_opts);
    }

    if (!$device || ! -b $device) {
        die "Device for volume '$target_vol' (WWID: $wwid) not found locally. " .
            "Check SAN connectivity and run 'multipath -ll' to diagnose.";
    }

    # Track this WWID locally so cluster orphan cleanup can find stale
    # devices later. Only track real volumes, not temp snapshot clones
    # (those have their own short-lived lifecycle).
    if (!$is_temp_clone) {
        eval { _track_wwid($storeid, $wwid); };
    }

    return ($device, $parsed->{vmid}, 'raw');
}

# Cleanup temporary snapshot clones
# Called after copy operations complete
sub _cleanup_temp_snap_clone {
    my ($scfg, $storeid, $volname, $snapname) = @_;

    my $cache_key = "${storeid}:${volname}:${snapname}";
    my $temp_vol = $_temp_snap_clones{$cache_key};
    return unless $temp_vol;

    my $api = _get_api($scfg);

    # Get WWID for device cleanup
    my $wwid = eval { $api->volume_get_wwid($temp_vol); };

    # Cleanup local devices first
    if ($wwid) {
        eval { cleanup_lun_devices($wwid); };
    }

    # Disconnect and delete temp volume
    eval {
        my $connections = $api->volume_get_connections($temp_vol);
        for my $conn (@$connections) {
            $api->volume_disconnect_host($temp_vol, $conn->{name});
        }
        $api->volume_delete($temp_vol);
    };

    delete $_temp_snap_clones{$cache_key};
}

sub filesystem_path {
    my ($class, $scfg, $volname, $snapname) = @_;

    my ($path, $vmid, $format) = $class->path($scfg, $volname, $scfg->{storage}, $snapname);
    return wantarray ? ($path, $vmid, $format) : $path;
}

#
# Snapshot operations
#

sub volume_snapshot {
    my ($class, $scfg, $storeid, $volname, $snap) = @_;

    my $api = _get_api($scfg);
    my $pure_volname = _get_full_volname($scfg, pve_volname_to_pure($storeid, $volname));
    my $snap_suffix = encode_snapshot_name($snap);
    my $full_snap_name = "${pure_volname}.${snap_suffix}";

    # Check if source volume exists
    my $vol = eval { $api->volume_get($pure_volname); };
    unless ($vol) {
        die "Cannot create snapshot: volume '$pure_volname' not found on Pure Storage";
    }

    # Check if snapshot already exists
    my $existing = eval { $api->snapshot_get($full_snap_name); };
    if ($existing) {
        die "Snapshot '$snap' already exists for volume '$volname'";
    }

    # Best-effort flush of host-side dirty buffers BEFORE the storage-level
    # snapshot. For running VMs, qemu's own freeze handles consistency at
    # the filesystem layer; this flush only catches the case where the
    # device has dirty page cache from non-qemu access (e.g. backup tool
    # writing directly to a stopped-VM volume). Skip if device is in use
    # so we don't block on a busy live migration.
    my $wwid = eval { $api->volume_get_wwid($pure_volname); };
    if ($wwid) {
        my $device = get_device_by_wwid($wwid);
        if ($device && -b $device && !is_device_in_use($device)) {
            eval { PVE::Tools::run_command(['/bin/sync'], timeout => 10); };
            warn "pre-snapshot sync failed/timed out: $@" if $@;
            eval { PVE::Tools::run_command(['/sbin/blockdev', '--flushbufs', $device], timeout => 10); };
            warn "pre-snapshot blockdev --flushbufs failed for $device: $@" if $@;
        }
    }

    # Create snapshot
    eval { $api->snapshot_create($pure_volname, $snap_suffix); };
    if ($@) {
        die "Failed to create snapshot '$snap' for volume '$volname': " .
            PVE::Storage::Custom::PureStorage::API::translate_pure_error($@);
    }

    # Backup VM config to Pure Storage
    # Extract VMID from volname (vm-{vmid}-disk-{n} or base-{vmid}-disk-{n})
    if ($volname =~ /^(?:vm|base)-(\d+)-disk-\d+$/) {
        my $vmid = $1;
        eval { _backup_vm_config($scfg, $storeid, $api, $vmid, $snap); };
        if ($@) {
            warn "VM config backup failed (non-fatal): $@\n";
        }
    }

    return 1;
}

sub volume_snapshot_delete {
    my ($class, $scfg, $storeid, $volname, $snap, $running) = @_;

    my $api = _get_api($scfg);
    my $pure_volname = _get_full_volname($scfg, pve_volname_to_pure($storeid, $volname));
    my $snap_suffix = encode_snapshot_name($snap);
    my $full_snap_name = "${pure_volname}.${snap_suffix}";

    # Check if snapshot exists before deleting
    my $existing = eval { $api->snapshot_get($full_snap_name); };
    unless ($existing) {
        warn "Snapshot '$snap' for volume '$volname' not found on Pure Storage, may have been already deleted\n";
        return 1;  # Not an error - idempotent delete
    }

    # Check if snapshot is being used as source for any clones
    # Pure Storage will reject deletion if snapshot has dependents
    # Only destroy (not eradicate) to allow recovery from Pure Storage UI
    # Pure Storage will auto-eradicate based on array's eradication delay setting
    eval { $api->snapshot_delete($full_snap_name, skip_eradicate => 1); };
    if ($@) {
        if ($@ =~ /has dependent volume/i || $@ =~ /in use/i || $@ =~ /cannot be deleted/i) {
            die "Cannot delete snapshot '$snap': it is being used as source for linked clones. " .
                "Delete the dependent volumes first.";
        }
        die "Failed to delete snapshot '$snap' for volume '$volname': $@";
    }

    # Delete corresponding config backup volume
    # Extract VMID from volname (vm-{vmid}-disk-{n} or base-{vmid}-disk-{n})
    if ($volname =~ /^(?:vm|base)-(\d+)-disk-\d+$/) {
        my $vmid = $1;
        eval { _delete_config_volume($api, $scfg, $storeid, $vmid, $snap); };
        if ($@) {
            warn "Config volume cleanup failed (non-fatal): $@\n";
        }
    }

    return 1;
}

sub volume_snapshot_rollback {
    my ($class, $scfg, $storeid, $volname, $snap) = @_;

    my $api = _get_api($scfg);
    my $pure_volname = _get_full_volname($scfg, pve_volname_to_pure($storeid, $volname));
    my $snap_suffix = encode_snapshot_name($snap);
    my $full_snap_name = "${pure_volname}.${snap_suffix}";

    # Validate: Check if target volume exists
    my $vol = eval { $api->volume_get($pure_volname); };
    unless ($vol) {
        die "Cannot rollback: volume '$pure_volname' not found on Pure Storage";
    }

    # Validate: Check if snapshot exists
    my $snapshot = eval { $api->snapshot_get($full_snap_name); };
    unless ($snapshot) {
        die "Cannot rollback: snapshot '$snap' for volume '$volname' not found on Pure Storage";
    }

    # Safety check: Verify device is not in use before rollback
    # Rollback replaces volume contents - this is destructive
    my $wwid = eval { $api->volume_get_wwid($pure_volname); };
    if ($wwid) {
        my $device = get_device_by_wwid($wwid);
        if ($device && -b $device) {
            if (is_device_in_use($device)) {
                die "Cannot rollback volume '$volname': device $device is still in use. " .
                    "Ensure VM is stopped before rollback.";
            }
        }
    }

    # Perform rollback - overwrite volume from snapshot
    eval { $api->volume_overwrite($pure_volname, $full_snap_name); };
    if ($@) {
        die "Failed to rollback volume '$volname' to snapshot '$snap': $@";
    }

    # Same per-device rescan + multipath map resize as volume_resize: the
    # snapshot may have a different capacity than the current volume, and
    # the kernel won't pick that up from a host scan alone.
    #
    # Additionally, after a rollback the kernel buffer cache may still
    # hold pages from the post-snapshot content. Without invalidation,
    # subsequent reads can silently return stale data. blockdev
    # --flushbufs invalidates the cache for the multipath device.
    if ($wwid) {
        my $device = get_device_by_wwid($wwid);
        if ($device && -b $device) {
            # 1. Per-slave SCSI rescan
            my $slaves = eval { get_multipath_slaves($device) } // [];
            for my $slave (@$slaves) {
                eval { rescan_scsi_device($slave); };
            }

            # 2. Refresh multipath map size
            eval { multipath_resize_map($device); };

            # 3. CRITICAL: invalidate kernel buffer cache so subsequent
            #    reads see the snapshot content, not stale post-snapshot
            #    pages.
            eval { PVE::Tools::run_command(['/sbin/blockdev', '--flushbufs', $device], timeout => 10); };

            # 4. udev refresh
            _udev_refresh();
        }
    }

    return 1;
}

sub volume_snapshot_list {
    my ($class, $scfg, $storeid, $volname) = @_;

    my $api = _get_api($scfg);
    my $pure_volname = _get_full_volname($scfg, pve_volname_to_pure($storeid, $volname));

    my $snapshots = $api->snapshot_list($pure_volname, "${pure_volname}.pve-snap-*");

    my @result;
    for my $snap (@$snapshots) {
        my $decoded = decode_snapshot_name($snap->{name});
        next unless $decoded;

        # decode_snapshot_name returns raw suffix (e.g., "pve-snap-backup1")
        # Strip the "pve-snap-" prefix to get the original PVE snapshot name
        my $snap_name = $decoded->{snapname};
        $snap_name =~ s/^pve-snap-//;

        push @result, {
            name   => $snap_name,
            ctime  => $snap->{created} // 0,
        };
    }

    return \@result;
}

#
# Feature support
#

sub volume_has_feature {
    my ($class, $scfg, $feature, $storeid, $volname, $snapname, $running, $opts) = @_;

    if ($feature eq 'clone') {
        return 1 if $snapname;
        return 1;
    }

    my $features = {
        snapshot   => { current => 1, snap => 1 },
        copy       => { base => 1, snap => 1, current => 1 },
        sparseinit => { base => 1, current => 1 },
        rename     => { current => 1 },
        template   => { current => 1 },
    };

    my $key = $snapname ? 'snap' : 'current';

    return 1 if defined($features->{$feature}) && $features->{$feature}{$key};
    return 0;
}

sub parse_volname {
    my ($class, $volname) = @_;

    my $parsed = _parse_volname($volname);
    die "unable to parse purestorage volume name '$volname'\n" unless $parsed;

    # Return format: ($vtype, $name, $vmid, $basename, $basevmid, $isBase, $format)
    if ($parsed->{type} eq 'disk') {
        my $isBase = $parsed->{isBase} ? 1 : 0;
        my $basename = $parsed->{basename};  # For linked clones: base-102-disk-0
        my $basevmid = $parsed->{basevmid};  # For linked clones: 102
        return ('images', $volname, $parsed->{vmid}, $basename, $basevmid, $isBase, $parsed->{format});
    } elsif ($parsed->{type} eq 'cloudinit') {
        return ('images', $volname, $parsed->{vmid}, undef, undef, 0, $parsed->{format});
    } elsif ($parsed->{type} eq 'state') {
        return ('images', $volname, $parsed->{vmid}, undef, undef, 0, $parsed->{format});
    }

    return undef;
}

#
# Template support
#

sub create_base {
    my ($class, $storeid, $scfg, $volname) = @_;

    my ($vtype, $name, $vmid, $basename, $basevmid, $isBase, $format) =
        $class->parse_volname($volname);

    die "create_base on wrong vtype '$vtype'\n" if $vtype ne 'images';
    die "create_base not possible with base image\n" if $isBase;

    my $api = _get_api($scfg);
    my $pure_volname = _get_full_volname($scfg, pve_volname_to_pure($storeid, $volname));

    # Verify volume exists on Pure Storage
    my $vol = eval { $api->volume_get($pure_volname); };
    unless ($vol) {
        die "Cannot create template: volume '$pure_volname' not found on Pure Storage\n";
    }

    # Safety check: Verify the volume is not currently in use
    # Converting to template while VM is running could cause issues
    my $wwid = eval { $api->volume_get_wwid($pure_volname); };
    if ($wwid) {
        my $device = get_device_by_wwid($wwid);
        if ($device && -b $device) {
            if (is_device_in_use($device)) {
                die "Cannot convert to template: volume '$volname' is currently in use. " .
                    "Please stop the VM first.\n";
            }
        }
    }

    # Create pve-base snapshot for future linked cloning
    # This snapshot serves as the base for all linked clones
    my $base_suffix = 'pve-base';
    my $full_snap_name = "${pure_volname}.${base_suffix}";

    my $existing_snap = eval { $api->snapshot_get($full_snap_name); };
    if ($existing_snap) {
        warn "Template snapshot already exists for '$volname', reusing existing snapshot\n";
    } else {
        eval { $api->snapshot_create($pure_volname, $base_suffix); };
        if ($@) {
            if ($@ =~ /quota/i || $@ =~ /capacity/i) {
                die "Cannot create template: insufficient capacity for base snapshot. $@\n";
            }
            die "Failed to create template snapshot for '$volname': $@\n";
        }
    }

    # Generate new PVE volume name (vm-XXX-disk-N -> base-XXX-disk-N)
    my $newname = $name;
    $newname =~ s/^vm-/base-/;

    return $newname;
}

sub rename_volume {
    my ($class, $scfg, $storeid, $source_volname, $target_vmid, $target_volname) = @_;

    my ($vtype, $source_name, $source_vmid, undef, undef, $isBase, $format) =
        $class->parse_volname($source_volname);

    die "rename_volume on wrong vtype '$vtype'\n" if $vtype ne 'images';

    my $api = _get_api($scfg);

    # Determine target volume name if not provided
    if (!$target_volname) {
        $target_volname = $class->find_free_diskname($storeid, $scfg, $target_vmid, $format);
    }

    # Get source and target Pure volume names
    my $source_pure_vol = _get_full_volname($scfg, pve_volname_to_pure($storeid, $source_volname));
    my $target_pure_vol = _get_full_volname($scfg, pve_volname_to_pure($storeid, $target_volname));

    # Check volumes
    my $vol = $api->volume_get($source_pure_vol);
    die "Source volume '$source_pure_vol' not found\n" unless $vol;

    my $existing = $api->volume_get($target_pure_vol);
    die "Target volume '$target_pure_vol' already exists\n" if $existing;

    # Rename
    $api->volume_rename($source_pure_vol, $target_pure_vol);

    return "${storeid}:${target_volname}";
}

sub find_free_diskname {
    my ($class, $storeid, $scfg, $vmid, $fmt, $add_fmt_suffix) = @_;

    my $disk_list = $class->list_images($storeid, $scfg, $vmid);

    my %used_ids;
    for my $disk (@$disk_list) {
        if ($disk->{volid} =~ /(?:vm|base)-$vmid-disk-(\d+)/) {
            $used_ids{$1} = 1;
        }
    }

    for (my $id = 0; $id < 1000; $id++) {
        unless ($used_ids{$id}) {
            return "vm-${vmid}-disk-${id}";
        }
    }

    die "No free disk ID found for VM $vmid\n";
}

#
# Clone support
#
# NOTE: PVE Clone Architecture Limitation
# =======================================
# PVE has two clone modes:
# - Linked Clone: PVE calls clone_image() -> Uses Pure Storage instant clone (fast!)
# - Full Clone: PVE calls alloc_image() + qemu-img data copy -> Slow block copy
#
# This is a PVE design decision, not a storage plugin limitation. PVE intentionally
# uses data copy for Full Clone to ensure complete independence from the source.
#
# However, Pure Storage's volume clone already creates independent volumes instantly!
# The clone_image function below supports both:
# - Clone from snapshot (Linked Clone)
# - Clone from volume directly (Full Clone via this function - instant)
#
# Unfortunately, PVE's GUI "Full Clone" option bypasses clone_image entirely.
#
# WORKAROUND for users who need instant Full Clone:
# 1. Use "Linked Clone" from PVE GUI (this calls clone_image -> instant)
# 2. After clone completes, delete the source snapshot if you need independence
#
# Or use pvesm command directly:
#   pvesm alloc <storage> <vmid> <volname> <size>  # Creates empty volume
#   # Then manually clone via Pure Storage management interface
#

sub clone_image {
    my ($class, $scfg, $storeid, $volname, $vmid, $snap) = @_;

    my $api = _get_api($scfg);

    # Parse source volume name
    my $parsed = _parse_volname($volname);
    die "Cannot parse volume name: $volname" unless $parsed;

    # Get parent Pure volume name (with pod prefix)
    my $parent_pure_vol = _get_full_volname($scfg, pve_volname_to_pure($storeid, $volname));

    # Validate: Check if parent volume exists
    my $parent_vol = eval { $api->volume_get($parent_pure_vol); };
    unless ($parent_vol) {
        die "Cannot clone: source volume '$parent_pure_vol' not found on Pure Storage";
    }

    # Determine source for clone
    my $source;
    my $source_type;  # For error messages: 'snapshot' or 'base'
    my $is_linked_to_base = 0;  # Track if this is a linked clone from template

    if ($snap) {
        # Clone from specific snapshot (linked clone from VM snapshot)
        my $snap_suffix = encode_snapshot_name($snap);
        $source = "${parent_pure_vol}.${snap_suffix}";
        $source_type = "snapshot '$snap'";

        # Validate: Check if snapshot exists
        my $snap_exists = eval { $api->snapshot_get($source); };
        unless ($snap_exists) {
            die "Cannot clone from snapshot: snapshot '$snap' for volume '$volname' not found. " .
                "Please ensure the snapshot exists before cloning.";
        }
    } else {
        # No snapshot specified - check if it's a template or full clone
        my $base_snap = "${parent_pure_vol}.pve-base";

        my $existing = eval { $api->snapshot_get($base_snap); };
        if ($existing) {
            # Has pve-base snapshot - this is a template, use linked clone
            $source = $base_snap;
            $source_type = "base template";
            $is_linked_to_base = 1;
        } elsif ($parsed->{isBase}) {
            # Is a template but no pve-base snapshot yet - create it
            eval { $api->snapshot_create($parent_pure_vol, 'pve-base'); };
            if ($@) {
                die "Failed to create base snapshot for template '$volname': $@";
            }
            $source = $base_snap;
            $source_type = "base template";
            $is_linked_to_base = 1;
        } else {
            # Regular volume - do full clone directly from volume
            # Pure Storage supports instant clone from volume (not just snapshot)
            $source = $parent_pure_vol;
            $source_type = "volume (full clone)";
        }
    }

    # Generate new disk ID for clone (use _find_free_diskid for gap-filling consistency)
    my $new_diskid = _find_free_diskid($scfg, $storeid, $vmid);
    my $new_volname = "vm-${vmid}-disk-${new_diskid}";

    # Generate Pure volume name for clone (with pod prefix)
    my $clone_pure_vol = _get_full_volname($scfg, encode_volume_name($storeid, $vmid, $new_diskid));

    # Disk-id collision retry: same TOCTOU window as alloc_image —
    # _find_free_diskid + volume_clone is not atomic. Two concurrent clones
    # for the same VM can both pick the same disk id and one will fail
    # with "already exists". Catch that and retry with the next free id.
    my $clone_attempts = 0;
    while (1) {
        $clone_attempts++;

        # Check if target volume already exists (atomic-ish check; the
        # volume_clone below is the real arbiter).
        my $existing_clone = eval { $api->volume_get($clone_pure_vol); };
        if ($existing_clone) {
            if ($clone_attempts < 5) {
                warn "clone_image: target '$clone_pure_vol' already exists, retrying with next free id\n";
                $new_diskid = _find_free_diskid($scfg, $storeid, $vmid);
                $new_volname = "vm-${vmid}-disk-${new_diskid}";
                $clone_pure_vol = _get_full_volname($scfg, encode_volume_name($storeid, $vmid, $new_diskid));
                next;
            }
            die "Clone target volume '$clone_pure_vol' already exists on Pure Storage. " .
                "This may indicate a naming conflict.";
        }

        # Create clone from source (snapshot or volume)
        eval { $api->volume_clone($clone_pure_vol, $source); };
        last unless $@;

        my $err = $@;
        if ($clone_attempts < 5 && $err =~ /already exists|duplicate|conflict|409/i) {
            warn "clone_image: disk-id collision on '$clone_pure_vol', retrying with next free id\n";
            $new_diskid = _find_free_diskid($scfg, $storeid, $vmid);
            $new_volname = "vm-${vmid}-disk-${new_diskid}";
            $clone_pure_vol = _get_full_volname($scfg, encode_volume_name($storeid, $vmid, $new_diskid));
            next;
        }

        if ($err =~ /not found/i) {
            die "Failed to create clone from $source_type: source not found. $err";
        }
        die "Failed to create clone from $source_type: " .
            PVE::Storage::Custom::PureStorage::API::translate_pure_error($err);
    }

    # Connect cloned volume to all cluster hosts for migration support
    my ($connected_hosts, $failed_hosts);
    eval {
        ($connected_hosts, $failed_hosts) = _connect_to_all_hosts($scfg, $api, $clone_pure_vol);
    };
    if ($@) {
        # Cleanup on failure. Same Bug E pattern as alloc_image:
        # _connect_to_all_hosts may have partially succeeded — disconnect
        # every host it managed to connect before destroying the volume,
        # otherwise orphaned host connections become ghost LUNs on other
        # cluster nodes (the same root cause as the production hang
        # incident with `no_path_retry queue` defaults).
        my $conn_err = $@;
        warn "Clone host connection failed, cleaning up volume '$clone_pure_vol'\n";
        _disconnect_from_all_hosts($api, $clone_pure_vol);
        eval { $api->volume_delete($clone_pure_vol, skip_eradicate => 1); };
        if ($@) {
            warn "Warning: Failed to cleanup clone volume after error: $@\n";
        }
        die "Failed to connect cloned volume to host: $conn_err";
    }

    # Log warning if some hosts failed (non-fatal, migration may be affected)
    if ($failed_hosts && @$failed_hosts) {
        warn "Warning: Clone '$clone_pure_vol' not connected to hosts: " .
             join(', ', @$failed_hosts) . ". Live migration to these nodes may fail.\n";
    }

    # Return proper volume name format
    # For linked clones from template: base-102-disk-0/vm-104-disk-0
    # For clones from snapshot or full clone: vm-104-disk-0
    if ($is_linked_to_base) {
        # volname is base-102-disk-0, return base-102-disk-0/vm-104-disk-0
        return "$volname/$new_volname";
    }
    return $new_volname;
}

1;

__END__

=head1 NAME

PVE::Storage::Custom::PureStoragePlugin - Pure Storage FlashArray Storage Plugin for Proxmox VE

=head1 SYNOPSIS

Add storage configuration in /etc/pve/storage.cfg:

    purestorage: pure1
        pure-portal 192.168.1.100
        pure-api-token xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx
        content images

=head1 DESCRIPTION

This plugin enables Proxmox VE to use Pure Storage FlashArray for VM disk storage
via iSCSI or Fibre Channel protocol.

Key features:

=over 4

=item * Direct volume provisioning (no LUN indirection)

=item * Snapshot create/delete/rollback

=item * Instant clone via Pure Storage snapshots

=item * Multipath I/O support

=item * Cluster-aware for live migration

=back

=head1 CONFIGURATION OPTIONS

=over 4

=item B<pure-portal> - Pure Storage management IP/hostname (required)

=item B<pure-api-token> - API token for authentication (recommended)

=item B<pure-username> - API username (alternative to token)

=item B<pure-password> - API password (alternative to token)

=item B<pure-ssl-verify> - Verify SSL certificates (default: no)

=item B<pure-protocol> - SAN protocol: iscsi or fc (default: iscsi)

=item B<pure-host-mode> - 'per-node' or 'shared' host (default: per-node)

=item B<pure-cluster-name> - Cluster name for host naming

=back

=head1 AUTHOR

Jason Cheng (jasoncheng7115)

=head1 LICENSE

AGPL-3.0+

=cut
