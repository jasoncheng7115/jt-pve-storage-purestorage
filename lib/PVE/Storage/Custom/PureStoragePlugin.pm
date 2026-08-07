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
    pve_volname_to_pure
    pure_to_pve_volname
    storeid_to_pure_prefix
);
use PVE::Storage::Custom::PureStorage::ISCSI qw(
    get_initiator_name
    probe_portal
    discover_targets
    login_target
    logout_target
    get_sessions
    get_session_states
    rescan_sessions
    is_portal_logged_in
);
use PVE::Storage::Custom::PureStorage::Multipath qw(
    rescan_scsi_hosts
    rescan_scsi_device
    multipath_reload
    multipath_reload_throttled
    describe_wwid_state
    multipath_flush
    multipath_resize_map
    get_multipath_device
    get_device_by_wwid
    wait_for_multipath_device
    cleanup_lun_devices
    is_device_in_use
    device_usage_state
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

# The storage API version this plugin claims.
#
# It has to be negotiated rather than hardcoded, because PVE::Storage treats
# the two directions very differently when it loads a third-party plugin:
#
#   api() > PVE::Storage::APIVER     HARD REJECT. The plugin never loads and
#                                    every purestorage storage disappears from
#                                    the node.
#   api() < APIVER - APIAGE          rejected as too old, same outcome.
#   api() != APIVER (but in range)   loads, and PVE warns "implementing an
#                                    older storage API, an upgrade is
#                                    recommended" on EVERY load of
#                                    PVE::Storage -- once per pvesm/qm/pct
#                                    call and once per daemon start.
#
# Proxmox VE 9 raised APIVER twice inside the 9.1 point releases (13 -> 14 ->
# 15) and the constants live in libpve-storage-perl, which versions
# independently of pve-manager. No single hardcoded number is right on every
# node. Claiming what the running PVE asks for, capped at the highest version
# whose delta is actually implemented here, is both quiet and safe: api() is
# only a load-time gate. Nothing in PVE branches on the value afterwards --
# it calls plugin methods with its own current signatures either way.
#
# Raise APIVERSION_MAX only after implementing that version's delta:
#   14  volume_resize gained a $snapname parameter (handled: refused, because
#       this plugin does snapshots on the array, not as a volume chain)
#   15  get_identity()
use constant APIVERSION_MAX => 15;
use constant APIVERSION_MIN => 9;

# What to claim when PVE::Storage is not loaded at all, i.e. `perl -c` and the
# unit tests. Any value in range does; this is the version the plugin was
# first written against, and the one every Proxmox VE 9.0/9.1/9.2 storage
# library accepts.
use constant APIVERSION => 13;
use constant MIN_APIVERSION => APIVERSION_MIN;

# Mark as shared storage (accessible from multiple nodes)
push @PVE::Storage::Plugin::SHARED_STORAGE, 'purestorage';

#
# Plugin registration
#

sub api {
    my $pve = eval {
        PVE::Storage->can('APIVER') ? PVE::Storage::APIVER() : undef;
    };

    return APIVERSION unless defined $pve && $pve =~ /^\d+\z/;  ## audit-ok: the documented fallback when PVE::Storage is absent

    my $claim = $pve < APIVERSION_MAX ? $pve : APIVERSION_MAX;
    $claim = APIVERSION_MIN if $claim < APIVERSION_MIN;

    return $claim;
}

sub type {
    return 'purestorage';
}

# Return a stable, unique identifier for this storage instance. Added to the
# base PVE::Storage::Plugin in PVE 9.2 (the base default die()s) and invoked via
# the new GET /nodes/<node>/storage/<storage>/identity endpoint (primarily for
# PBS instance matching; the Web UI may poll it for any storage). Without this
# override the base die() surfaces as an error in the Web UI. The identity is
# the management portal plus the optional pod, which together pin a storage to
# one array (and one ActiveCluster pod) deterministically.
sub get_identity {
    my ($class, $scfg, $storeid) = @_;
    my $portal = $scfg->{'pure-portal'} // '';
    my $pod    = $scfg->{'pure-pod'}    // '';
    return "purestorage:${portal}:${pod}";
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
        # Keep the array credentials out of /etc/pve/storage.cfg.
        #
        # PVE reads this list in PVE::Storage::Plugin::sensitive_properties()
        # and, in the storage-config API, pulls those keys out of the request
        # before the config is written, handing them to on_add_hook /
        # on_update_hook instead. Without it the list falls back to a
        # hardcoded `encryption-key keyring master-pubkey password`, which
        # covers neither of ours — so the API token sat in storage.cfg in
        # cleartext and `GET /storage/<id>` returned it to anyone holding
        # Datastore.Allocate on that storage, which is not root. A Pure API
        # token is typically array-wide, so that is full control of the
        # FlashArray, not just of this storage.
        'sensitive-properties' => {
            'pure-api-token' => 1,
            'pure-password'  => 1,
        },
    };
}

sub properties {
    return {
        'pure-portal' => {
            description => "Pure Storage FlashArray management address. Use the"
                . " array's VIRTUAL management IP (vir0), or a hostname that"
                . " resolves to it — NOT the address of an individual"
                . " controller (ct0.eth0 / ct1.eth0). A FlashArray has three"
                . " management addresses: one per controller plus a virtual IP"
                . " bound to whichever controller currently holds the"
                . " management primary role. Pointed at a controller's own"
                . " address, the plugin loses the REST API the moment that"
                . " controller fails over, and the storage goes inactive"
                . " (running guests keep running — only operations needing the"
                . " array's API stop). This is a fixed property and cannot be"
                . " changed with 'pvesm set'; see the README section"
                . " 'Management address: use the virtual IP' for the"
                . " remove-and-re-add procedure.",
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
        'pure-config-backup-timeout' => {
            description => "Timeout in seconds for the auxiliary 1 MB config-"
                . " backup volume's multipath device to appear during snapshot"
                . " operations. The config backup is non-critical (used only"
                . " by pve-pure-config-get for disaster recovery), so a"
                . " separate short timeout avoids stalling every snapshot"
                . " when the volume's device is slow to surface on degraded"
                . " multipath. Defaults to 15 seconds; raise toward"
                . " pure-device-timeout if your fabric is consistently slow.",
            type => 'integer',
            minimum => 5,
            maximum => 60,
            default => 15,
        },
        'pure-status-timeout' => {
            description => "Timeout in seconds for REST calls on the pvestatd"
                . " health path (activate_storage + the foreground of status)."
                . " This path is polled every ~10s and PVE processes storages"
                . " sequentially, so a slow array would otherwise back up the"
                . " whole pvestatd cycle and starve sibling storages on the"
                . " same node into 'inactive'. The health client makes a"
                . " single attempt (no retries) — the next poll IS the retry,"
                . " so dropping per-call retries costs nothing. The data path"
                . " (alloc/free/clone) and the background reaper keep the"
                . " resilient client. On a heavily-loaded-but-healthy array"
                . " status may briefly show 'inactive' and recover next poll;"
                . " running VMs are unaffected (devices stay mapped). Raise"
                . " this on slow/high-latency management networks.",
            type => 'integer',
            minimum => 2,
            maximum => 60,
            default => 5,
        },
        'pure-activate-deadline' => {
            description => "Cumulative wall-clock budget in seconds for the"
                . " iSCSI portal discover/login loop in activate_storage."
                . " Per-portal timeouts (probe/discovery/login) bound each"
                . " portal but NOT the loop total; several reachable-but-"
                . "hanging LIFs can still stall pvestatd. Once the budget is"
                . " spent AND at least one portal is already logged in, the"
                . " remaining portals are deferred to a later activation. The"
                . " budget is never enforced while zero paths are up (we must"
                . " get >=1 path or fail honestly) and never interrupts an"
                . " in-progress login, so it cannot mark a slow-but-reachable"
                . " storage inactive. Set to 0 to disable the budget.",
            type => 'integer',
            minimum => 0,
            maximum => 300,
            default => 30,
        },
        'pure-pod' => {
            description => "Pod name for ActiveCluster configurations. Required when File service is enabled.",
            type => 'string',
            optional => 1,
        },
        'pure-pod-usage-metric' => {
            description => "Which Pure pod space figure is reported to Proxmox"
                . " VE as 'used' when the pod has a quota_limit set."
                . " 'provisioned' (default) is the sum of the provisioned"
                . " sizes of the pod's volumes — this is what the array"
                . " checks when deciding whether the NEXT volume create or"
                . " grow in the pod is allowed, so it is the figure that"
                . " predicts allocation failures. Because Pure volumes are"
                . " thin, a pod can read as 100% full while almost nothing"
                . " has been written to it, and writing into the existing"
                . " volumes keeps working. 'virtual' reports host-written"
                . " logical bytes instead, which matches the intuitive"
                . " 'how full is it' reading but does NOT predict when an"
                . " allocation will be refused. 'physical' reports the"
                . " post-deduplication bytes actually consumed on the array."
                . " Only affects reporting; it never changes what the array"
                . " enforces.",
            type => 'string',
            enum => ['provisioned', 'virtual', 'physical'],
            default => 'provisioned',
            optional => 1,
        },
        'pure-rescan-interval' => {
            description => "Minimum seconds between the SAN rescans that"
                . " activate_storage performs (iSCSI session rescan, SCSI"
                . " host scan, multipath reconfigure, udev trigger)."
                . " Proxmox VE calls activate_storage on every pvestatd"
                . " poll (~10s), so running those unconditionally means a"
                . " host-wide 'multipathd reconfigure' and 'udevadm"
                . " trigger' six times a minute on every node, which keeps"
                . " device-mapper in flux and competes with device"
                . " discovery during VM start/backup. A rescan is always"
                . " performed immediately when this node logs in to a new"
                . " iSCSI portal; this interval bounds the periodic"
                . " safety-net rescan in between. Set to 0 to rescan on"
                . " every activation (legacy behaviour).",
            type => 'integer',
            minimum => 0,
            maximum => 3600,
            default => 300,
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
        'pure-config-backup-timeout' => { optional => 1 },
        'pure-status-timeout' => { optional => 1 },
        'pure-activate-deadline' => { optional => 1 },
        'pure-pod'           => { optional => 1 },
        'pure-pod-usage-metric' => { optional => 1 },
        'pure-rescan-interval'  => { optional => 1 },
        nodes                => { optional => 1 },
        disable              => { optional => 1 },
        content              => { optional => 1 },
        shared               => { optional => 1 },
    };
}

#
# Helper methods
#


#
# Array credentials
#
# Stored under /etc/pve/priv/storage/, which pmxcfs keeps root-only, exactly
# as PBSPlugin and CIFSPlugin store theirs. See plugindata() for why.
#

sub _secret_file {
    my ($storeid, $kind) = @_;
    # The storeid is used verbatim, as PBSPlugin does: PVE's pve-storage-id
    # format permits only [a-z0-9-_.] and requires a leading letter, so it can
    # never escape the directory. Sanitising it here would instead risk two
    # distinct storeids ("a.b" and "a-b") colliding on one file.
    return "/etc/pve/priv/storage/${storeid}.$kind";
}

sub _set_secret {
    my ($storeid, $kind, $value) = @_;
    mkdir '/etc/pve/priv/storage';
    PVE::Tools::file_set_contents(_secret_file($storeid, $kind), "$value\n", 0600);
    return 1;
}

sub _delete_secret {
    my ($storeid, $kind) = @_;
    my $file = _secret_file($storeid, $kind);
    unlink($file) if -e $file;
    return 1;
}

sub _get_secret {
    my ($storeid, $kind) = @_;
    my $file = _secret_file($storeid, $kind);
    return undef unless -f $file;
    my $val = eval { PVE::Tools::file_get_contents($file) };
    return undef unless defined $val;
    chomp $val;
    return length($val) ? $val : undef;
}

# Resolve the credentials for a storage: the out-of-config secret wins, and
# the value in $scfg is the fallback.
#
# The fallback is what makes this safe to roll out. An existing installation
# has its token in storage.cfg and no secret file; nothing about it changes
# until the operator next sets the token, at which point PVE routes the value
# to on_update_hook and it moves to the file. A PVE storage update is a MERGE
# (`$scfg->{$k} = $opts->{$k}` over the new keys only), so an unrelated
# `pvesm set` can never drop the in-config token either.
sub _resolve_credentials {
    my ($scfg, $storeid) = @_;

    return (
        api_token => _get_secret($storeid, 'pure-token') // $scfg->{'pure-api-token'},
        username  => $scfg->{'pure-username'},
        password  => _get_secret($storeid, 'pure-pw') // $scfg->{'pure-password'},
    );
}

# Called when a storage is added. %param holds ONLY the sensitive properties;
# a key that is absent was not supplied. Any pre-existing file for this
# storeid is a leftover from a storage of the same name that was removed, so
# clearing it is correct here (same as PBSPlugin).
# Refuse a storage whose name collides with an existing one on the same array.
#
# Every Pure object this plugin owns is named from the storeid put through
# storeid_to_pure_prefix(), and that transform is NOT injective: it deletes
# characters it cannot use (so a dot disappears) and then maps '-' to '_'.
# PVE storage ids may contain all three, so these are distinct storages that
# produce one prefix:
#
#     pure-prod   ->  pure_prod
#     pure_prod   ->  pure_prod
#     pure-p.rod  ->  pure_prod
#
# The prefix is the ONLY thing that scopes ownership -- list_images(), the
# orphan reaper, the temp-clone reaper and the config-volume cleanup all ask
# the array for "pve-<prefix>-*" and treat every answer as theirs. Two
# colliding storages on the same array therefore share one namespace: each
# lists the other's disks as its own, and deleting a volume through one can
# destroy a volume the other's guests are running on.
#
# Making the transform injective is not an option -- it would rename every
# volume that already exists. Refusing the collision at the moment it is
# created costs nothing and is the only point where the operator can still
# choose a different name.
#
# Scoped to the same portal and pod, because a different array or a different
# pod is a different namespace. Two portals that happen to address the SAME
# array (say vir0 and a controller address) would slip through; the message
# names that case so the operator can recognise it.
sub _assert_storeid_prefix_unique {
    my ($storeid, $scfg) = @_;

    my $cfg = eval { PVE::Storage::config() };
    return unless $cfg && ref($cfg->{ids}) eq 'HASH';

    my $ours   = eval { storeid_to_pure_prefix($storeid) };
    return unless defined $ours && length $ours;
    my $portal = $scfg->{'pure-portal'} // '';
    my $pod    = $scfg->{'pure-pod'}    // '';

    for my $other (sort keys %{ $cfg->{ids} }) {
        next if $other eq $storeid;
        my $o = $cfg->{ids}->{$other};
        next unless ref($o) eq 'HASH' && ($o->{type} // '') eq 'purestorage';
        next unless ($o->{'pure-portal'} // '') eq $portal;
        next unless ($o->{'pure-pod'}    // '') eq $pod;

        my $theirs = eval { storeid_to_pure_prefix($other) };
        next unless defined $theirs && $theirs eq $ours;

        die "Storage '$storeid' would use the same Pure volume names as the "
          . "existing storage '$other' on array '$portal'"
          . ($pod ? " (pod '$pod')" : "") . ".\n"
          . "  Both names reduce to the prefix '$ours': Pure volume names "
          . "drop characters they cannot use and map '-' to '_', so "
          . "'$storeid' and '$other' are indistinguishable on the array.\n"
          . "  Sharing a prefix means each storage lists the other's disks "
          . "as its own and can delete them. Choose a storage id that "
          . "differs by more than '-', '_' or '.'.\n";
    }

    return;
}

sub on_add_hook {
    my ($class, $storeid, $scfg, %param) = @_;

    _assert_storeid_prefix_unique($storeid, $scfg);

    for my $p (['pure-api-token', 'pure-token'], ['pure-password', 'pure-pw']) {
        my ($opt, $kind) = @$p;
        if (defined(my $val = $param{$opt})) {
            _set_secret($storeid, $kind, $val);
        } else {
            _delete_secret($storeid, $kind);
        }
    }

    return;
}

# Called when a storage is updated. Here `exists` and `defined` mean different
# things and both matter: extract_sensitive_params() sets the key to undef for
# an explicit `--delete`, sets it to the value when one is given, and leaves
# it absent when the property was not touched at all. Acting on an absent key
# would wipe a credential the operator never mentioned.
sub on_update_hook {
    my ($class, $storeid, $scfg, %param) = @_;

    for my $p (['pure-api-token', 'pure-token'], ['pure-password', 'pure-pw']) {
        my ($opt, $kind) = @$p;
        next unless exists $param{$opt};
        if (defined $param{$opt}) {
            _set_secret($storeid, $kind, $param{$opt});
        } else {
            _delete_secret($storeid, $kind);
        }
    }

    return;
}

# The full form, which is what PVE actually calls for us (it picks
# on_update_hook_full whenever the plugin's api() is >= 13, and ours is 13).
#
# Taking this form instead of the short one buys a one-command migration.
# $scfg here is the LIVE existing config hashref that PVE writes out
# immediately afterwards:
#
#     $plugin->on_update_hook_full($storeid, $scfg, $opts, $delete, $sensitive);
#     if ($delete) { delete $scfg->{$k} for $delete->@* }
#     $scfg->{$k} = $opts->{$k} for keys %$opts;
#     PVE::Storage::write_config($cfg);
#
# so deleting the legacy in-config credential here removes it from
# storage.cfg. Without that, an operator upgrading from a release that stored
# the token in the config could not get rid of the cleartext copy:
# `pvesm set <id> --pure-api-token <token>` writes the secret file but the old
# line survives (an update is a merge), and `--delete pure-api-token` is
# reported to us as an explicit deletion, so it would remove the secret file
# too and lock them out of their own array.
#
# Order matters: write the secret first. _set_secret dies on failure, which
# aborts the whole update before PVE writes the config, so we can never end up
# having dropped the old credential without having stored the new one.
sub on_update_hook_full {
    my ($class, $storeid, $scfg, $update, $delete, $sensitive) = @_;

    # Warn, do not die. An operator who already has a colliding pair (created
    # before this check existed, or by changing pure-pod so that two storages
    # met in one namespace) must still be able to edit the storage -- refusing
    # here would lock them out of the very commands that fix it, including
    # setting credentials.
    eval { _assert_storeid_prefix_unique($storeid, $scfg); };
    warn $@ if $@;

    for my $p (['pure-api-token', 'pure-token'], ['pure-password', 'pure-pw']) {
        my ($opt, $kind) = @$p;
        next unless exists $sensitive->{$opt};

        if (defined $sensitive->{$opt}) {
            _set_secret($storeid, $kind, $sensitive->{$opt});
            # Retire the cleartext copy a pre-1.1.25 release left behind.
            #
            # This is the one moment in the whole migration where a
            # mixed-version cluster can bite, so say so here rather than only
            # in the README. /etc/pve is replicated, so the secret file
            # reaches every node immediately — but a node still running a
            # pre-1.1.25 plugin does not know to read it, and the cleartext
            # copy it WAS reading has just been removed. That node's storage
            # stops authenticating until its package is upgraded.
            if (defined $scfg->{$opt}) {
                warn "Storage '$storeid': moved '$opt' out of storage.cfg into "
                   . _secret_file($storeid, $kind) . " (root-only).\n"
                   . "  IMPORTANT: every node in this cluster must be running "
                   . "plugin version 1.1.25 or later before this takes effect "
                   . "safely. Older nodes read the credential from "
                   . "storage.cfg, which no longer holds it, and will fail to "
                   . "authenticate against the array. Check with:\n"
                   . "    pvesh get /nodes --output-format json | "
                   . "grep -o '\"node\":\"[^\"]*\"'\n"
                   . "    # then on each: dpkg -l jt-pve-storage-purestorage\n";
                delete $scfg->{$opt};
            }
        } else {
            _delete_secret($storeid, $kind);
            delete $scfg->{$opt};
        }
    }

    return;
}

sub on_delete_hook {
    my ($class, $storeid, $scfg) = @_;

    _delete_secret($storeid, 'pure-token');
    _delete_secret($storeid, 'pure-pw');

    return;
}

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

sub _cleanup_lock_file {
    my ($storeid) = @_;
    return _wwid_lock_dir() . '/' . _safe_storeid($storeid) . '-cleanup.lock';
}

# Storage health/monitoring tunables (NetApp v0.2.10 parity). Events are logged
# via warn() so pvestatd routes them to the journal; filter with
# `journalctl -t pvestatd | grep pure-storage`. Severity is carried in the
# message text ([ERROR]/[WARNING]/[INFO]) for monitoring pickup.
use constant STATUS_FAIL_THRESHOLD => 3;     # consecutive failed polls => outage

# How old a temp snapshot clone must be before a node that CANNOT prove it
# owns it will tear it down.
#
# Ownership is normally decided by "is this clone connected to a host other
# than mine?", because a temp clone is connected only to the node that made
# it. With pure-host-mode = shared every node reports the SAME host name, so
# that question answers "it is mine" for a clone made anywhere in the cluster
# -- and the creating node's own is_device_in_use() protects only itself. A
# second node would then disconnect and destroy a clone the first node is
# reading from, which is the incident the ownership check was added for.
#
# There is no signal in shared mode that distinguishes the nodes, so instead
# of guessing, wait out any plausible operation. A day is far longer than a
# qemu-img convert or a container backup and still bounds the leak.
use constant TEMP_CLONE_UNOWNED_MIN_AGE => 86400;

# Pure rejects a volume name longer than this outright; it does not truncate.
# Confirmed by the array's own error text: "Volume name must be between 1 and
# 63 characters (alphanumeric, '_' and '-') in length and begin and end with a
# letter or number."
use constant MAX_PURE_VOLUME_NAME => 63;
use constant OUTAGE_REEMIT_SECONDS => 30;    # re-emit outage ERROR at most this often
use constant CAPACITY_WARN_PCT     => 90;
use constant CAPACITY_CRIT_PCT     => 95;
use constant CAPACITY_COOLDOWN_SEC => 3600;  # 1h between capacity warnings

sub _health_state_file {
    my ($storeid) = @_;
    return _wwid_lock_dir() . '/' . _safe_storeid($storeid) . '-health.json';
}

sub _read_health_state {
    my ($storeid) = @_;
    my $file = _health_state_file($storeid);
    return {} unless -f $file;
    open(my $fh, '<', $file) or return {};
    local $/;
    my $json = <$fh>;
    close($fh);
    my $data = eval { decode_json($json) } // {};
    return ref($data) eq 'HASH' ? $data : {};
}

sub _write_health_state {
    my ($storeid, $state) = @_;
    my $dir = _wwid_lock_dir();
    return unless -d $dir;
    my $file = _health_state_file($storeid);
    my $tmp = "$file.tmp.$$";
    open(my $fh, '>', $tmp) or return;
    print $fh encode_json($state // {});
    close($fh);
    rename($tmp, $file) or unlink($tmp);
}

# Outage detection: count consecutive status() failures and emit an ERROR once
# the array has missed STATUS_FAIL_THRESHOLD polls in a row, re-emitting at most
# every OUTAGE_REEMIT_SECONDS while still down. A single transient failure does
# not alarm.
sub _record_status_failure {
    my ($storeid, $reason) = @_;
    $reason //= 'unknown error';
    chomp $reason;
    my $h = _read_health_state($storeid);
    $h->{fail_count} = ($h->{fail_count} // 0) + 1;
    my $now = time();
    if ($h->{fail_count} >= STATUS_FAIL_THRESHOLD) {
        if (!$h->{down} || ($now - ($h->{last_outage_emit} // 0)) >= OUTAGE_REEMIT_SECONDS) {
            warn "pure-storage: [ERROR] storage '$storeid' OUTAGE — Pure FlashArray API " .
                 "unreachable for $h->{fail_count} consecutive status polls. Last error: $reason\n";
            $h->{last_outage_emit} = $now;
        }
        $h->{down} = 1;
    }
    _write_health_state($storeid, $h);
}

# Success path: log recovery if we were down, reset the failure counter, and
# emit capacity-health warnings at >=90% (WARNING) / >=95% (ERROR) used, each
# rate-limited to once per CAPACITY_COOLDOWN_SEC.
sub _record_status_ok {
    my ($storeid, $total, $used, $is_pod) = @_;
    my $h = _read_health_state($storeid);
    if ($h->{down}) {
        warn "pure-storage: [INFO] storage '$storeid' RECOVERED — Pure FlashArray API reachable again.\n";
    }
    $h->{fail_count} = 0;
    $h->{down}       = 0;

    my $now = time();
    if ($total && $total > 0) {
        my $pct   = ($used // 0) / $total * 100;
        my $scope = $is_pod ? 'pod quota' : 'array';
        if ($pct >= CAPACITY_CRIT_PCT) {
            if (($now - ($h->{cap_crit_emit} // 0)) >= CAPACITY_COOLDOWN_SEC) {
                warn sprintf("pure-storage: [ERROR] storage '%s' capacity CRITICAL — %.1f%% used " .
                    "(>= %d%%). New allocations may fail; free space or expand the %s.\n",
                    $storeid, $pct, CAPACITY_CRIT_PCT, $scope);
                $h->{cap_crit_emit} = $now;
            }
        } elsif ($pct >= CAPACITY_WARN_PCT) {
            if (($now - ($h->{cap_warn_emit} // 0)) >= CAPACITY_COOLDOWN_SEC) {
                warn sprintf("pure-storage: [WARNING] storage '%s' capacity high — %.1f%% used " .
                    "(>= %d%% of %s).\n", $storeid, $pct, CAPACITY_WARN_PCT, $scope);
                $h->{cap_warn_emit} = $now;
            }
        } else {
            # Back below thresholds — clear cooldowns so a future breach warns promptly.
            delete $h->{cap_crit_emit};
            delete $h->{cap_warn_emit};
        }
    }
    _write_health_state($storeid, $h);
}

# Explain a pod that reports as full, once per CAPACITY_COOLDOWN_SEC.
#
# A pod-backed storage reports total = the pod's quota_limit and used = a pod
# space figure (pure-pod-usage-metric, default 'provisioned'). Because Pure
# volumes are thin, a pod holding one 32 GiB volume reports 32 GiB provisioned
# with ~0 bytes written — so setting a 3 GiB quota afterwards makes Proxmox VE
# show the storage as 100% full immediately, while writing into the existing
# volume keeps working. Both halves of that are correct: the array WILL refuse
# the next volume create or grow in the pod, and it will NOT refuse writes to
# volumes that already exist. Nothing in the numbers says so, though, so say it
# explicitly and print the raw figures the array returned.
sub _warn_pod_quota_exhausted {
    my ($storeid, $scfg, $capacity) = @_;

    return unless ref($capacity) eq 'HASH';
    return unless ($capacity->{quota_source} // '') eq 'pod';

    my $total    = $capacity->{total}    // 0;
    my $raw_used = $capacity->{raw_used} // 0;
    return unless $total > 0 && $raw_used >= $total;

    my $h = _read_health_state($storeid);
    my $now = time();
    return if ($now - ($h->{pod_quota_emit} // 0)) < CAPACITY_COOLDOWN_SEC;

    my $space = ref($capacity->{raw_space}) eq 'HASH' ? $capacity->{raw_space} : {};
    my $raw = join(', ', map { "$_=" . ($space->{$_} // 'n/a') }
        grep { defined $space->{$_} }
        qw(total_provisioned virtual total_physical total_used unique snapshots));

    my $msg = sprintf(
        "pure-storage: [WARNING] storage '%s' pod '%s' is at or over its quota: "
        . "quota_limit=%d bytes, %s=%d bytes.\n"
        . "  This means the array will REFUSE the next volume create or grow in "
        . "this pod. It does NOT mean the pod is out of physical space, and it "
        . "does not stop writes to volumes that already exist — Pure volumes are "
        . "thin, so provisioned size counts against the quota from the moment a "
        . "volume is created, whether or not data has been written to it.\n"
        . "  To fix: raise the pod quota (Storage > Pods > Edit, or "
        . "'purepod setattr --quota-limit'), or free provisioned capacity by "
        . "destroying and eradicating unused volumes in the pod.\n"
        . "  To report host-written bytes instead of provisioned size, set "
        . "'pure-pod-usage-metric virtual' — note that reading will no longer "
        . "predict when an allocation is refused.\n",
        $storeid, ($scfg->{'pure-pod'} // '?'), $total,
        ($capacity->{metric} // 'provisioned'), $raw_used);
    $msg .= "  Raw pod space from the array: $raw\n" if $raw;
    $msg .= "  Pod is stretched over $capacity->{array_count} arrays; some Pure "
          . "pod space figures are reported per array replica.\n"
        if ($capacity->{array_count} // 0) > 1;

    warn $msg;

    $h->{pod_quota_emit} = $now;
    _write_health_state($storeid, $h);
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

# Orphan reaper safety tunables. The background reaper acts on a point-in-time
# array snapshot; a single incomplete or racy snapshot must NOT be enough to
# tear down a live device. Two independent guards (cross-project hardening from
# the NetApp reaper incident where a freshly-added, in-use LUN was reaped):
#   - GRACE: never reap a WWID first seen less than this many seconds ago. This
#     protects a just-added LUN during the window after map/connect but before
#     qemu opens it, when is_device_in_use() legitimately reports "idle"
#     (no mount, no holder, no open fd yet).
#   - MISS THRESHOLD: only reap after the WWID has been observed absent from the
#     array for this many consecutive cleanup passes (hysteresis), so one
#     transient/incomplete array response cannot trigger teardown.
use constant ORPHAN_GRACE_SECONDS  => 600;
use constant ORPHAN_MISS_THRESHOLD => 3;

# Normalise a tracking-file entry to { first_seen => epoch, miss => N }.
# Backward compatible: older state files stored a bare epoch timestamp as the
# value, so a plain scalar is read as first_seen with miss=0.
sub _wwid_entry {
    my ($val) = @_;
    if (ref($val) eq 'HASH') {
        return {
            first_seen => $val->{first_seen} // time(),
            miss       => $val->{miss}       // 0,
        };
    }
    return { first_seen => (defined($val) && $val ? $val + 0 : time()), miss => 0 };
}

sub _track_wwid {
    my ($storeid, $wwid) = @_;
    return unless $wwid;
    _with_wwid_lock($storeid, sub {
        my $state = _read_wwid_state($storeid);
        return if $state->{lc($wwid)};
        $state->{lc($wwid)} = { first_seen => time(), miss => 0 };
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

# Build the set of WWIDs tracked by OTHER purestorage storages on this node.
# Phase 3 warns about Pure multipath devices that are neither on THIS storage's
# array nor in THIS storage's tracking file. On a host with more than one
# purestorage storage (multiple pods, or multiple arrays) a sibling storage's
# live device satisfies both "not ours" conditions and would be mis-flagged as
# a stale orphan, telling the operator to run `multipath -f` on an in-use disk
# that belongs to a different storage. Our state directory is private to this
# plugin, so every *-wwids.json in it belongs to a purestorage storage; union
# the siblings' tracked WWIDs and skip them. (Cross-project parity with
# jt-pve-storage-netapp v0.2.15.)
sub _sibling_tracked_wwids {
    my ($storeid) = @_;
    my %sib;
    my $dir = _wwid_state_dir();
    my $self_file = _wwid_state_file($storeid);
    for my $file (glob("$dir/*-wwids.json")) {
        next if $file eq $self_file;
        my $data = eval {
            open(my $fh, '<', $file) or return undef;
            local $/;
            my $json = <$fh>;
            close($fh);
            decode_json($json);
        };
        next unless ref($data) eq 'HASH';
        $sib{lc($_)} = 1 for keys %$data;
    }
    return \%sib;
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

    my $san_storage = storeid_to_pure_prefix($storeid);

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
        # Derive the WWID from the serial already present in the volume_list
        # response instead of issuing a per-volume volume_get_wwid() call.
        # That call was an extra REST round-trip per volume on EVERY pvestatd
        # poll (~10s); on a storage with hundreds/thousands of volumes it
        # multiplied background API load and risked hitting Pure's rate limit.
        # Fall back to the per-volume lookup only when serial is absent.
        my $wwid = $vol->{serial}
            ? eval { $api->serial_to_wwid($vol->{serial}); }
            : undef;
        $wwid = eval { $api->volume_get_wwid($vol->{name}); } unless $wwid;
        next unless $wwid;
        $alive{lc($wwid)} = 1;
    }

    # Reconcile the tracking file against this array snapshot in a single
    # locked read-modify-write: reset the absence counter for every WWID the
    # array still reports, register newly-seen WWIDs, and increment the
    # absence counter for tracked WWIDs the array no longer reports. Phase 2
    # decides what to tear down from this reconciled snapshot. Doing it in one
    # locked pass also replaces the old per-WWID _track_wwid() loop (one lock
    # acquisition instead of N).
    my $tracked = {};
    _with_wwid_lock($storeid, sub {
        my $state = _read_wwid_state($storeid);
        for my $w (keys %$state) {
            my $e = _wwid_entry($state->{$w});
            $e->{miss} = $alive{$w} ? 0 : $e->{miss} + 1;
            $state->{$w} = $e;
        }
        for my $w (keys %alive) {
            $state->{$w} //= { first_seen => time(), miss => 0 };
        }
        _write_wwid_state($storeid, $state);
        %$tracked = %$state;
    });

    # Phase 2: for each tracked WWID the array no longer has, clean its local
    # stale device — but only once two independent safety guards agree it is
    # genuinely orphaned, never on a single absent observation:
    #   - grace period: skip WWIDs first seen within ORPHAN_GRACE_SECONDS
    #     (protects a just-added LUN before qemu opens it), and
    #   - hysteresis: skip until the WWID has been absent from the array for
    #     ORPHAN_MISS_THRESHOLD consecutive passes (absorbs a transient or
    #     incomplete array response, e.g. a paginated list returning short).
    # is_device_in_use() below remains the final gate; these two guards exist
    # because is_device_in_use() cannot see a LUN that is mapped but not yet
    # opened by qemu — exactly the just-added case from the NetApp incident.
    for my $wwid (keys %$tracked) {
        next if $alive{$wwid};

        my $entry = _wwid_entry($tracked->{$wwid});
        next if (time() - $entry->{first_seen}) < ORPHAN_GRACE_SECONDS;
        next if $entry->{miss} < ORPHAN_MISS_THRESHOLD;

        my $mpath = eval { get_multipath_device($wwid); };
        if ($mpath && -b $mpath) {
            warn "orphan cleanup: stale Pure device $mpath (wwid $wwid) — array no longer has this volume (absent $entry->{miss} consecutive passes), cleaning up\n";
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
    my $sibling = _sibling_tracked_wwids($storeid);
    for my $dev (@$local) {
        my $w = lc($dev->{wwid} // '');
        next unless $w;
        next if $alive{$w};
        next if $tracked->{$w};
        next if $sibling->{$w};   # owned by another purestorage storage on this host

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
    my ($scfg, $storeid, %opts) = @_;

    # The storeid is REQUIRED: it is how we find the credentials, which now
    # live outside storage.cfg. Die loudly rather than silently falling back
    # to the in-config value, so a call site that forgot to pass it fails in
    # testing instead of quietly working on legacy installs and breaking on
    # new ones. tools/audit-invariants.pl enforces this statically too.
    die "internal error: _get_api() called without a storeid\n"
        unless defined $storeid && length $storeid;

    # The pvestatd health path (activate_storage + the foreground of status)
    # must fail fast so one slow array does not back up the whole sequential
    # pvestatd cycle and starve sibling storages into 'inactive'. When called
    # with status => 1 we hand back a short-timeout, single-attempt client.
    # The data path and the background reaper omit the flag and get the
    # resilient default client. The two clients are cached under distinct keys
    # so they never clobber each other.
    my $status_path = $opts{status} ? 1 : 0;

    # Cache key. NOTE: $scfg->{storage} is always undef — PVE's storage config
    # hash does not carry the storage id — so this used to degrade to keying on
    # the portal alone. Two storages pointing at the same array with different
    # API tokens (or different pure-status-timeout values) would then share one
    # cached client, and whichever one built it first won for the whole TTL.
    # Key on everything that actually distinguishes a client.
    my %creds = _resolve_credentials($scfg, $storeid);

    my $cache_key = join("\0",
        $scfg->{'pure-portal'}     // '',
        $creds{api_token}          // '',
        $creds{username}           // '',
        $scfg->{'pure-ssl-verify'} // 0,
        $status_path,
        $status_path ? ($scfg->{'pure-status-timeout'} // 5) : '',
    );

    # Return cached client if available, fresh, and from same process
    # (forked workers must not share session tokens)
    if (my $cached = $api_cache{$cache_key}) {
        my $cache_age = time() - ($cached->{timestamp} // 0);
        if ($cache_age < API_CACHE_TTL &&
            $cached->{host} eq $scfg->{'pure-portal'} &&
            ($cached->{pid} // 0) == $$) {
            return $cached->{api};
        }
    }

    my $ssl_verify = $scfg->{'pure-ssl-verify'} // 0;

    unless ($creds{api_token} || ($creds{username} && $creds{password})) {
        die "No Pure Storage credentials for '$storeid'. Set them with "
          . "'pvesm set $storeid --pure-api-token <token>' (or "
          . "--pure-username/--pure-password); they are stored outside "
          . "storage.cfg in /etc/pve/priv/storage/.\n";
    }

    my %client_opts = (
        host       => $scfg->{'pure-portal'},
        api_token  => $creds{api_token},
        username   => $creds{username},
        password   => $creds{password},
        ssl_verify => $ssl_verify,
    );
    if ($status_path) {
        $client_opts{timeout}     = $scfg->{'pure-status-timeout'} // 5;
        $client_opts{retry_count} = 1;
    }

    # Inherit an already-established session from any other cached client for
    # the same array. Building a client otherwise costs a GET /api/api_version
    # plus a POST /login, and the background reaper builds a fresh one on
    # every pass because it runs in a fork. The API version is cached inside
    # API.pm per host; the token is passed here. A stale token simply yields
    # one 401, after which _request() re-logs in and retries.
    for my $other (values %api_cache) {
        next unless $other->{host} && $other->{host} eq ($scfg->{'pure-portal'} // '');
        my $tok = eval { $other->{api}->get_session_token(); };
        next unless $tok;
        $client_opts{session_token} = $tok;
        last;
    }

    my $api = PVE::Storage::Custom::PureStorage::API->new(%client_opts);

    $api_cache{$cache_key} = {
        api       => $api,
        host      => $scfg->{'pure-portal'},
        timestamp => time(),
        pid       => $$,
    };

    return $api;
}

# Look up a volume's WWID before a destructive operation.
#
# Every destructive path used to do this:
#
#   my $wwid = eval { $api->volume_get_wwid($pure_volname); };
#   if ($wwid) { ...the entire local in-use safety check... }
#   ...destroy / overwrite anyway...
#
# so a single transient REST failure silently disabled the guard and let the
# destroy or overwrite run unprotected. The eval was there to tolerate a
# volume with no local device, but it could not tell that apart from "the
# array did not answer".
#
# This helper makes the failure explicit: one bounded retry, then refuse.
# Refusing costs the operator a retry; proceeding costs them a volume.
sub _require_wwid_for_guard {
    my ($api, $pure_volname, $operation) = @_;

    my $wwid;
    my $err;
    for my $attempt (1 .. 2) {
        $wwid = eval { $api->volume_get_wwid($pure_volname); };
        $err = $@;
        last unless $err;
        sleep(1) if $attempt == 1;
    }

    if ($err) {
        chomp $err;
        die "Refusing to $operation '$pure_volname': its WWID could not be "
          . "read from the array, so the local safety check that verifies "
          . "the device is not in use cannot run. Retry once the array is "
          . "reachable. Underlying error: $err\n";
    }

    unless (defined $wwid && length $wwid) {
        die "Refusing to $operation '$pure_volname': the array returned no "
          . "serial for this volume, so its local device cannot be "
          . "identified and the in-use safety check cannot run. Verify the "
          . "volume in the Pure UI.\n";
    }

    return $wwid;
}

# Run the local in-use guard for a destructive operation on $wwid.
# Dies unless the device is positively determined to be idle — an
# undetermined answer is treated exactly like "in use", because for a raw
# LUN attached to a running VM the checks that can fail are the same checks
# that would otherwise report the VM.
sub _assert_device_idle {
    my ($wwid, $volname, $operation) = @_;

    # The device lookup itself can fail (multipathd unresponsive, a
    # /dev/disk/by-id stat that hit the block layer's uninterruptible wait).
    # "I could not look for the device" is not the same as "there is no
    # device", so do not let an exception here read as the latter.
    my $device = eval { get_device_by_wwid($wwid); };
    if (my $err = $@) {
        chomp $err;
        die "Refusing to $operation '$volname': could not look up the local "
          . "device for WWID $wwid, so the in-use safety check cannot run "
          . "($err). Check 'systemctl status multipathd' and retry.\n";
    }
    return unless $device;   # no local device on this node: nothing to protect

    my ($state, $reason) = device_usage_state($device);
    return if $state eq 'idle';

    if ($state eq 'unknown') {
        die "Refusing to $operation '$volname': cannot determine whether "
          . "device $device is still in use ($reason). Treating an "
          . "undetermined answer as in-use on purpose — proceeding could "
          . "destroy data belonging to a running guest. Resolve the "
          . "condition above and retry.\n";
    }

    my $msg = "Cannot $operation '$volname': device $device is still in use "
            . "($reason).\n";
    my $details = eval { get_device_usage_details($device) } // '';
    $msg .= "\n$details\n" if $details;
    die $msg;
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
    multipath_reload_throttled();

    # Use a shorter, separate timeout for the config-backup volume:
    # it's a 1 MB auxiliary volume used only by pve-pure-config-get for
    # disaster recovery — non-critical. Skipping it after a brief wait
    # is preferable to stalling every snapshot operation by the full
    # pure-device-timeout (default 60s) when multipath is slow to
    # surface the new device (e.g., degraded paths).
    my $timeout = $scfg->{'pure-config-backup-timeout'} // 15;
    my %wait_opts = (timeout => $timeout);
    if ($protocol eq 'fc') {
        $wait_opts{fc_rescan} = sub { rescan_fc_hosts(delay => 1); };
    } else {
        $wait_opts{iscsi_rescan} = sub { rescan_sessions(); };
    }
    my $device = wait_for_multipath_device($wwid, %wait_opts);

    unless ($device) {
        warn "Config backup volume's multipath device did not surface " .
             "within ${timeout}s (WWID $wwid). Skipping the config " .
             "backup for this snapshot — this is non-fatal; the config " .
             "backup is only used by pve-pure-config-get for disaster " .
             "recovery. Raise pure-config-backup-timeout if your fabric " .
             "is consistently slow.\n";
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
    my $san_storage = storeid_to_pure_prefix($storeid);

    # volume_list() takes ONE positional argument. This used to be called as
    # volume_list(pattern => ..., pod => ...), so $pattern bound to the
    # literal string "pattern" and the array was asked for a volume with
    # that exact name — it always came back empty and this function has
    # never actually deleted anything. Its caller in free_image() had the
    # identical mistake, which made the "is this the VM's last disk?" test
    # always true; the two bugs cancelled out into "config volumes leak".
    # Fixing only one side would have started destroying config backups on
    # the FIRST disk deletion of a multi-disk VM, while snapshots of the
    # remaining disks still referenced them. Both are fixed together.
    my $pattern = "pve-${san_storage}-${vmid}-vmconf-*";
    my $pod = $scfg->{'pure-pod'};
    $pattern = "${pod}::${pattern}" if $pod;

    my $volumes = eval { $api->volume_list($pattern); } // [];

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

# Per-process caches for two things activate_storage() asks the array on every
# pvestatd poll but which change very rarely: the host object's existence and
# the list of iSCSI ports. Each was one REST call per poll per node per
# storage. TTL matches API_CACHE_TTL so the whole client is rebuilt on the
# same cadence.
#
# The risk of caching is bounded: if the host object is deleted on the array
# mid-window, volume_connect_host() fails with a clear error and the next
# _ensure_host() (within the TTL) recreates it. A newly added iSCSI LIF is
# picked up within the TTL rather than immediately.
my %host_verified;
my %iscsi_ports_cache;

sub _cached_iscsi_ports {
    my ($api, $portal) = @_;
    my $c = $iscsi_ports_cache{$portal};
    return $c->{ports} if $c && (time() - $c->{ts}) < API_CACHE_TTL && ($c->{pid} // 0) == $$;
    my $ports = $api->iscsi_get_ports();
    $iscsi_ports_cache{$portal} = { ports => $ports, ts => time(), pid => $$ };
    return $ports;
}

# Warn when another node in this cluster produces the same Pure host name.
#
# encode_host_name() truncates the node name to 20 characters, so node names
# that are longer and share a 20-character prefix land on ONE host object:
#
#     virtualization-node-01  ->  pve-pve-virtualization-node-
#     virtualization-node-02  ->  pve-pve-virtualization-node-
#
# Whichever node registers first creates the host; the second finds it and
# adds its own initiator to it. Both nodes then ARE that host as far as the
# array is concerned, and every ownership decision that asks "is this volume
# connected to a host other than mine?" answers wrongly -- including the
# temp-clone reaper's check, which exists precisely to stop one node tearing
# down another node's in-use clone.
#
# This only reports. Changing the host name would orphan the connections that
# already exist under the old one, and the initiator would come back from the
# array as "already in use by another host", so the rename has to be an
# operator decision made during maintenance, not something an upgrade does
# silently.
sub _warn_host_name_collision {
    my ($scfg, $host_name) = @_;

    # In 'shared' mode every node deliberately uses one host object; there is
    # nothing to tell apart and nothing to warn about.
    return if ($scfg->{'pure-host-mode'} // 'per-node') eq 'shared';

    my $nodes = eval { PVE::Cluster::get_nodelist() };
    return unless ref($nodes) eq 'ARRAY' && @$nodes > 1;

    my $me = eval { PVE::INotify::nodename() } // '';
    my $cluster = $scfg->{'pure-cluster-name'} // 'pve';

    my @clash = grep {
        $_ ne $me && encode_host_name($cluster, $_) eq $host_name
    } @$nodes;
    return unless @clash;

    my $flag = "/var/run/pve-storage-purestorage/hostname-clash-$host_name";
    $flag =~ s/[^\w\/.\-]/_/g;
    if (-e $flag && (time() - (stat($flag))[9] // 0) < 3600) {
        return;
    }
    if (open(my $fh, '>', $flag)) { close($fh); }

    warn "Pure host name '$host_name' is also produced by node(s) "
       . join(', ', map { "'$_'" } @clash) . " in this cluster: node names "
       . "are truncated to 20 characters for the array, and these share a "
       . "prefix.\n"
       . "  Those nodes share ONE host object on the array, so their "
       . "initiators are pooled and this plugin cannot tell them apart. "
       . "Disconnecting a volume on one node removes it from the other, and "
       . "the temp-clone reaper's per-node ownership check does not hold.\n"
       . "  Fixing it means giving the nodes names that differ within their "
       . "first 20 characters. That is a maintenance operation; this plugin "
       . "will not rename the host object on its own because the existing "
       . "volume connections hang off the current name.\n";

    return;
}

# Ensure host exists and has current node's initiator
sub _ensure_host {
    my ($scfg, $api, %opts) = @_;

    my $host_name = _get_host_name($scfg);

    my $cache_key = ($scfg->{'pure-portal'} // '') . "\0$host_name";
    unless ($opts{force}) {
        my $c = $host_verified{$cache_key};
        return $host_name
            if $c && (time() - $c->{ts}) < API_CACHE_TTL && ($c->{pid} // 0) == $$;
    }

    # Below the cache on purpose. activate_storage() calls this on every
    # pvestatd poll, and the whole point of the check above is that the poll
    # path does no work when nothing has changed. The collision cannot appear
    # without a node joining or being renamed, so once per TTL is plenty.
    _warn_host_name_collision($scfg, $host_name);
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

    # Only now, having actually confirmed the host and its initiators, record
    # it as verified. Marking it before the work would turn a transient
    # failure into a whole TTL of skipped checks.
    $host_verified{$cache_key} = { ts => time(), pid => $$ };

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
    if ($@) {
        # Cannot enumerate, so cannot disconnect. Say so loudly: the caller is
        # a cleanup path that is about to destroy the volume, and leaving
        # connections behind is what turns into ghost LUNs on other nodes.
        warn "_disconnect_from_all_hosts: could not list host connections for "
           . "$vol ($@); any remaining connections must be removed manually "
           . "from the Pure UI.\n";
        return;
    }
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
    # Backup fleecing image: vm-100-fleece-0
    } elsif ($volname =~ /^vm-(\d+)-fleece-(\d+)$/) {
        return {
            vmid     => $1,
            fleeceid => $2,
            format   => 'raw',
            type     => 'fleece',
            isBase   => 0,
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

    my $api = _get_api($scfg, $storeid);
    my $san_storage = storeid_to_pure_prefix($storeid);

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

    my $san_storage = storeid_to_pure_prefix($storeid);

    # Find all snapshot-access clones for this storage. Two globs because the
    # marker was shortened from "-temp-snap-access-" to "-tsa-" (the old one
    # pushed the name past the array's 63-character limit); clones created
    # before that change still have to be collected.
    my @patterns = ("pve-${san_storage}-*-tsa-*",
                    "pve-${san_storage}-*-temp-snap-access-*");
    # Add pod prefix if configured
    my $pod = $scfg->{'pure-pod'};
    @patterns = map { "${pod}::$_" } @patterns if $pod;

    # One list call per marker. A single wider glob would work too, but it
    # would drag in every volume whose name merely starts the same way, and
    # this runs against the array.
    my %by_name;
    for my $pattern (@patterns) {
        my $found = eval { $api->volume_list($pattern); } // [];
        $by_name{ $_->{name} } = $_ for grep { $_->{name} } @$found;
    }
    my $temp_vols = [ values %by_name ];
    return unless @$temp_vols;

    # Exact shape of the names path() generates:
    #   [<pod>::]pve-<storage>-...-temp-snap-access-<unix-ts>-<pid>
    # The glob handed to the array is deliberately loose (Pure's filter has
    # no anchoring), so re-match locally against the precise form before
    # touching anything. This reaper is the only place in the plugin that
    # ERADICATES rather than soft-destroys, so "it looked a bit like ours"
    # is not a good enough reason to act on a volume.
    my $strict_re = qr/^pve-\Q$san_storage\E-.+-(?:tsa|temp-snap-access)-(\d+)-(\d+)$/;
    my $my_host = _get_host_name($scfg);

    for my $vol (@$temp_vols) {
        next unless $vol->{name};

        my $bare = _strip_pod_prefix($scfg, $vol->{name});
        my ($name_ts) = $bare =~ $strict_re;
        unless (defined $name_ts) {
            warn "temp-clone cleanup: skipping '$vol->{name}' — it matched the "
               . "array-side pattern but not the exact name this plugin "
               . "generates, so it is not ours to delete.\n";
            next;
        }

        # Safety: only delete volumes older than 1 hour
        # This prevents deleting volumes currently in use.
        #
        # Timestamp units matter here and used to be inverted: REST 2.x
        # returns integer MILLISECONDS since the epoch, REST 1.x returns an
        # ISO 8601 string. The old code assumed the opposite (ISO for 2.x,
        # epoch SECONDS otherwise), so on every 2.x array `time() - $created`
        # came out around -1.7e12 — never greater than 3600 — and orphaned
        # temp snapshot clones were never reaped. Each leaked clone holds a
        # volume slot, a host connection on every node, and a stale multipath
        # device. pure_time_to_epoch() normalises both forms.
        my $created = PVE::Storage::Custom::PureStorage::API::pure_time_to_epoch(
            $vol->{created});
        next unless $created;   # unknown age: never assume it is stale

        # Two independent age sources must BOTH agree the volume is stale:
        # the array's created timestamp, and the unix timestamp path() baked
        # into the name at creation. They come from different clocks and
        # different code paths, so a bug or unit mix-up in either one cannot
        # on its own authorise an eradication.
        my $age_seconds      = time() - $created;
        my $age_from_name    = time() - $name_ts;

        # Same reasoning as the sweep: with pure-host-mode = shared the
        # foreign-connection check below cannot tell whose clone this is, so
        # age is the only signal left and one hour is not enough of it.
        my $min_age = (($scfg->{'pure-host-mode'} // 'per-node') eq 'shared')
            ? TEMP_CLONE_UNOWNED_MIN_AGE : 3600;

        if ($age_seconds > $min_age && $age_from_name > $min_age) {
            warn "Cleaning up orphaned temporary clone: $vol->{name} (age: ${age_seconds}s)\n";

            # Ownership check: a temp clone is connected only to the node
            # that created it. Every node runs this reaper, so without this a
            # snapshot-source operation running longer than an hour on node A
            # — a qemu-img convert of a large disk is routinely longer — gets
            # its device yanked by node B, which has no local device for the
            # clone, sails past cleanup_lun_devices(), disconnects it from
            # ALL hosts and destroys it. Node A's own reaper is protected by
            # is_device_in_use(); node B had nothing to protect it.
            #
            # Orphans left by a crashed node are still reaped — by that node
            # when it comes back, which is the correct owner anyway.
            my $conns = eval { $api->volume_get_connections($vol->{name}); };
            if ($@) {
                warn "temp-clone cleanup: cannot list connections for "
                   . "$vol->{name}, skipping this pass: $@\n";
                next;
            }
            my @foreign = grep { ($_->{name} // '') ne $my_host } @{ $conns // [] };
            if (@foreign) {
                warn "temp-clone cleanup: skipping $vol->{name} — still "
                   . "connected to " . join(', ', map { $_->{name} } @foreign)
                   . ". It belongs to another node, which may still be reading "
                   . "from it; that node will reap it.\n";
                next;
            }

            eval {
                # Get WWID for device cleanup. Prefer the serial already
                # present in the volume_list response and compute the WWID
                # locally (pure string math, no REST round-trip); fall back
                # to the per-volume lookup only when serial is absent. This
                # runs from the status() background reaper on every poll, so
                # an extra GET per temp volume here is the same N+1 shape the
                # orphan reaper already avoids in _cleanup_orphaned_devices.
                my $wwid = $vol->{serial}
                    ? $api->serial_to_wwid($vol->{serial})
                    : undef;
                $wwid //= $api->volume_get_wwid($vol->{name});
                if ($wwid) {
                    cleanup_lun_devices($wwid);
                }

                # Disconnect from all hosts
                my $connections = $api->volume_get_connections($vol->{name});
                for my $conn (@$connections) {
                    $api->volume_disconnect_host($vol->{name}, $conn->{name});
                }

                # Soft-destroy, not eradicate. This used to call
                # volume_delete() with no skip_eradicate, i.e. DELETE
                # /volumes — permanent, with no recovery window at all,
                # from an automated background reaper. Pure still frees
                # the name immediately (the tombstone rename in
                # volume_delete does that) and eradicates on the array's
                # normal schedule, so the only thing given up is the
                # volume-count slot for the eradication delay. That is a
                # cheap price for making every automated deletion in this
                # plugin recoverable.
                $api->volume_delete($vol->{name}, skip_eradicate => 1);
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

# Wall-clock of the last SAN rescan performed by activate_storage, per storeid.
# Process-wide: pvestatd is long-lived, so this survives across polls and is
# what actually bounds the rescan rate.
my %_last_activate_rescan;

# Decide whether activate_storage should perform its SAN rescan this time.
#
# Proxmox VE calls activate_storage() from storage_info() on EVERY pvestatd
# poll (~10s), sequentially across all storages — see PVE::Storage::storage_info.
# The previous implementation unconditionally ran, per poll and per node:
#   rescan_sessions() + rescan_scsi_hosts() + multipathd reconfigure +
#   udevadm trigger --subsystem-match=block + udevadm settle
# i.e. a host-wide multipath rebuild and a re-trigger of every block device on
# the system, six times a minute, forever. That is expensive on its own (it
# serialises ahead of every other storage's status poll) and actively harmful
# while something else is trying to discover a device: a backup or VM start
# waiting for a new LUN is racing a reconfigure that keeps tearing the map
# table down and rebuilding it.
#
# Discovery of genuinely new LUNs does not depend on this periodic rescan:
# activate_volume(), path() and alloc_image() each run their own targeted
# rescan/wait for the WWID they need. What remains here is a safety net for
# LUNs mapped out-of-band (another node, the Pure UI), so a slow cadence is
# sufficient. A rescan is still performed immediately, ignoring the interval,
# whenever this call actually logged in to a new portal.
sub _should_rescan_after_activate {
    my ($storeid, $scfg, $forced) = @_;

    return 1 if $forced;

    my $interval = $scfg->{'pure-rescan-interval'} // 300;
    return 1 if $interval <= 0;

    my $last = $_last_activate_rescan{$storeid} // 0;
    return 0 if (time() - $last) < $interval;
    return 1;
}

sub _mark_activate_rescan {
    my ($storeid) = @_;
    $_last_activate_rescan{$storeid} = time();
}

sub activate_storage {
    my ($class, $storeid, $scfg, $cache) = @_;

    # Verify Pure Storage connectivity. activate_storage runs on the pvestatd
    # health path, so use the short-timeout, single-attempt client (status =>
    # 1): a slow array fails this fast instead of stalling the poll cycle.
    my $api = _get_api($scfg, $storeid, status => 1);

    # Verify we can connect to the array
    eval { $api->array_get(); };
    if ($@) {
        die "Cannot connect to Pure Storage array at $scfg->{'pure-portal'}: $@";
    }

    # NOTE: orphaned temp-clone cleanup deliberately does NOT run here. It
    # disconnects and destroys volumes on the array — mutating, potentially
    # slow work that has no business on a path Proxmox VE polls every ~10s
    # with the short-timeout health client. status() already forks it into
    # the background reaper, under a lock, with the resilient client.

    # Ensure multipath is configured for Pure Storage
    _ensure_multipath_config();

    my $protocol = $scfg->{'pure-protocol'} // 'iscsi';

    if ($protocol eq 'fc') {
        # FC: Verify FC HBA is available
        unless (is_fc_available()) {
            die "FC protocol selected but no FC HBA found on this node. " .
                "Please install FC HBA or use 'pure-protocol iscsi'.";
        }

        # FC: periodic safety-net rescan for LUNs mapped out-of-band. There is
        # no login step on FC, so there is nothing that can force it; the
        # interval is the only gate.
        if (_should_rescan_after_activate($storeid, $scfg, 0)) {
            _mark_activate_rescan($storeid);
            rescan_fc_hosts(delay => 1);
            rescan_scsi_hosts(delay => 1);
            multipath_reload_throttled();

            # Trigger udev to update device info
            _udev_refresh();
        }

        # Verify FC fabric connectivity to Pure Storage target ports
        my $fc_targets = eval { get_fc_targets(); } // [];
        my @online_targets = grep { $_->{is_target} && ($_->{port_state} // '') =~ /online/i } @$fc_targets;
        unless (@online_targets) {
            warn "WARNING: No FC target ports detected via fabric. " .
                 "Check FC switch zoning between this host and Pure Storage array.\n";
        }

    } else {
        # iSCSI: Get portals and login
        my $ports = _cached_iscsi_ports($api, $scfg->{'pure-portal'} // '');
        if (@$ports) {
            my $probe_timeout = $scfg->{'pure-portal-probe-timeout'} // 2;
            my $activate_deadline = $scfg->{'pure-activate-deadline'} // 30;
            my $loop_start = time();
            my @logged_in;
            my @reach_ports;   # port objects we have a usable path to (for HA advisory)
            my @unreachable;
            my @failed;
            my @deferred;
            # Set when this call actually establishes a NEW session (as
            # opposed to finding every portal already logged in). A new
            # session can expose LUNs nothing else is going to look for, so it
            # forces the rescan below past the pure-rescan-interval gate.
            my $forced_rescan = 0;

            # Snapshot the iSCSI session list ONCE before the loop. The
            # per-portal fast-path check below used to call is_portal_logged_in
            # (→ iscsiadm -m session) for every portal; with N LIFs that is N
            # unbounded external commands per activation, none of them covered
            # by the wall-clock budget. One snapshot, reused for every portal.
            my $sessions_snapshot = eval { get_sessions(); } // [];

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
                if (is_portal_logged_in($portal_addr, $target, $sessions_snapshot)) {
                    push @logged_in, $portal_addr;
                    push @reach_ports, $port;
                    next;
                }

                # Wall-clock budget: per-portal timeouts (probe 2s, discovery
                # 30s, login 60s) bound EACH portal but not the loop total.
                # Several reachable-but-hanging LIFs can still stall pvestatd.
                # Once the budget is spent AND we already have >=1 path up,
                # defer the rest to a later activation. Gated so it can never
                # mark a slow-but-reachable storage inactive: we never defer
                # while zero paths are up (must get >=1 path or fail honestly),
                # and the check is at the TOP of the iteration so it never
                # interrupts an in-progress login.
                if ($activate_deadline > 0
                    && @logged_in
                    && (time() - $loop_start) >= $activate_deadline) {
                    push @deferred, $portal_addr;
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
                    push @reach_ports, $port;
                    $forced_rescan = 1;
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

            if (@deferred) {
                warn "Deferred login to " . scalar(@deferred)
                    . " iSCSI portal(s) on Pure Storage array: "
                    . join(", ", @deferred)
                    . " (activate_storage wall-clock budget of"
                    . " ${activate_deadline}s spent with "
                    . scalar(@logged_in) . " path(s) already up).\n"
                    . "  These portals will be retried on a later activation."
                    . " If they should already be reachable, investigate why"
                    . " their discovery/login is slow, or raise"
                    . " 'pure-activate-deadline'.\n";
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

            # Controller-redundancy advisory (NetApp v0.2.11 parity): if every
            # reachable iSCSI portal resolves to a SINGLE Pure controller, this
            # node has no controller-level path redundancy — a controller
            # failover or reboot drops all paths at once. Pure port names are
            # "CT0.*" / "CT1.*"; only advise when every reachable portal parsed
            # to a controller (avoids false positives on unexpected name forms).
            # Rate-limited to once per 24h via a flag file in /var/run.
            {
                my %ctrl;
                my $parsed = 0;
                for my $p (@reach_ports) {
                    if (($p->{name} // '') =~ /^(ct\d+)/i) {
                        $ctrl{lc($1)} = 1;
                        $parsed++;
                    }
                }
                if (@reach_ports && $parsed == scalar(@reach_ports) && keys(%ctrl) == 1) {
                    my ($only) = keys %ctrl;
                    my $flag = _wwid_lock_dir() . '/single-controller-warned-' . _safe_storeid($storeid);
                    my $emit = 1;
                    if (-f $flag) {
                        $emit = 0 if (time() - (stat($flag))[9]) < 86400;
                    }
                    if ($emit) {
                        warn "pure-storage: [WARNING] storage '$storeid' has reachable iSCSI paths on "
                            . "only ONE Pure controller (" . uc($only) . ") from this node. There is no "
                            . "controller-level path redundancy: a controller failover or reboot will "
                            . "drop all paths at once. Verify cabling/zoning so this node reaches a LIF "
                            . "on BOTH controllers (CT0 and CT1).\n";
                        eval { open(my $fh, '>', $flag); close($fh); };
                    }
                }
            }

            # Rescan for LUNs. Forced when this call actually established a
            # new session (there may be LUNs behind it that nothing else will
            # look for); otherwise rate-limited by pure-rescan-interval, see
            # _should_rescan_after_activate for why that matters.
            if (_should_rescan_after_activate($storeid, $scfg, $forced_rescan)) {
                _mark_activate_rescan($storeid);
                rescan_sessions();
                rescan_scsi_hosts(delay => 1);
                multipath_reload_throttled();

                # Trigger udev to update device info
                _udev_refresh();
            }
        }
    }

    # Ensure host exists (common for both protocols)
    _ensure_host($scfg, $api);

    return 1;
}

sub deactivate_storage {
    my ($class, $storeid, $scfg, $cache) = @_;

    my $api = eval { _get_api($scfg, $storeid); };
    unless ($api) {
        warn "Cannot connect to Pure Storage for cleanup: $@\n";
        return 1;  # Don't fail deactivation if API is unreachable
    }

    my $protocol = $scfg->{'pure-protocol'} // 'iscsi';

    # Get all volumes for this storage
    my $san_storage = storeid_to_pure_prefix($storeid);
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

        # Derive the WWID from the serial the list response already carried
        # instead of issuing a per-volume REST round-trip. On a storage with
        # hundreds of volumes the old form was an N+1 storm against the
        # array's management gateway, fired exactly when a node is shutting
        # down or a storage is being disabled cluster-wide. Fall back to the
        # per-volume lookup only when serial is absent.
        my $wwid = $vol->{serial}
            ? eval { $api->serial_to_wwid($vol->{serial}); }
            : undef;
        $wwid = eval { $api->volume_get_wwid($vol->{name}); } unless $wwid;
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

    # NOTE: no global multipath flush here. `multipath -F` would flush every
    # unused map on the host, including maps owned by other storage plugins
    # and by the customer's own LUNs — multipath_flush() deliberately croaks
    # when called without a device for exactly that reason, so the previous
    # `eval { multipath_flush(); }` here could only ever throw and be
    # swallowed. Per-volume cleanup above already removed our own maps.

    return 1;
}

sub status {
    my ($class, $storeid, $scfg, $cache) = @_;

    # Fail-fast: if we cannot even build the API client (auth/host/etc) we
    # MUST NOT block PVE status polling. Return inactive immediately so the
    # web UI keeps responding instead of hanging on the API timeout. Use the
    # short-timeout, single-attempt health client (status => 1) so a slow
    # array fails this poll quickly instead of backing up the sequential
    # pvestatd cycle and starving sibling storages on this node.
    my $api = eval { _get_api($scfg, $storeid, status => 1); };
    if (!$api) {
        my $err = $@ || 'API client init failed';
        warn "Failed to connect to Pure Storage: $err";
        _record_status_failure($storeid, $err);
        return (0, 0, 0, 0);
    }

    my $pod = $scfg->{'pure-pod'};

    eval {
        my $capacity = $api->get_managed_capacity(
            $pod, usage_metric => $scfg->{'pure-pod-usage-metric'});

        $cache->{total}     = $capacity->{total};
        $cache->{used}      = $capacity->{used};
        $cache->{avail}     = $capacity->{available};

        _warn_pod_quota_exhausted($storeid, $scfg, $capacity);
    };
    if ($@) {
        my $err = $@;
        warn "Failed to get storage status: $err";
        _record_status_failure($storeid, $err);
        return (0, 0, 0, 0);
    }

    # Outage recovery + capacity-health monitoring (NetApp v0.2.10 parity).
    _record_status_ok($storeid, $cache->{total}, $cache->{used}, $pod ? 1 : 0);

    # Run periodic background cleanup using the double-fork pattern: the
    # intermediate child forks the actual worker (grandchild) and exits
    # immediately. The grandchild gets reparented to init and is reaped
    # automatically — no zombie, and status() never blocks on cleanup work.
    my $intermediate_pid = fork();
    if (defined $intermediate_pid && $intermediate_pid == 0) {
        my $grandchild_pid = fork();
        if (defined $grandchild_pid && $grandchild_pid == 0) {
            # Grandchild — do the actual cleanup work, but only one pass per
            # storeid at a time. status() forks a cleanup pass on every
            # pvestatd poll (~10s). On a large array a single pass can exceed
            # that interval (it walks every tracked WWID and every Pure
            # multipath device), so without this guard passes would stack:
            # several concurrent grandchildren all hitting the REST API and
            # the local block layer, multiplying load and risking API rate
            # limiting. A non-blocking flock makes overlapping polls skip the
            # work instead of piling on. The lock auto-releases when this
            # process exits (even on crash), so it can never wedge.
            my $got_lock = 0;
            my $lock_fh;
            if (open($lock_fh, '>', _cleanup_lock_file($storeid))) {
                $got_lock = flock($lock_fh, LOCK_EX | LOCK_NB);
            }
            if ($got_lock) {
                # The reaper runs detached in the grandchild and is not on the
                # pvestatd critical path, so it uses the resilient default
                # client (longer timeout + retries), NOT the short health
                # client the foreground used above. _get_api rebuilds a fresh
                # client here anyway because the cached entry's pid no longer
                # matches this forked process.
                my $bg_api = eval { _get_api($scfg, $storeid); };
                if ($bg_api) {
                    eval { _cleanup_orphaned_temp_clones($scfg, $storeid, $bg_api); };
                    eval { _cleanup_orphaned_devices($bg_api, $storeid, $scfg); };
                }
            }
            POSIX::_exit(0);
        }
        # Intermediate exits immediately, leaving grandchild orphaned.
        POSIX::_exit(0);
    }
    # Reap the intermediate child without ever blocking. It only forks the
    # grandchild and _exit()s, so it is gone almost immediately — but this
    # runs on the pvestatd poll path, and fork() itself can block under
    # memory pressure or a cgroup pids limit. A bounded poll keeps the
    # storage status cycle moving; an unreaped child is collected by the
    # next call or by init.
    if (defined $intermediate_pid) {
        my $deadline = time() + 5;
        while (time() < $deadline) {
            last if waitpid($intermediate_pid, POSIX::WNOHANG()) != 0;
            select(undef, undef, undef, 0.05);
        }
    }

    return ($cache->{total}, $cache->{avail}, $cache->{used}, 1);
}

#
# Volume management
#

sub alloc_image {
    my ($class, $storeid, $scfg, $vmid, $fmt, $name, $size) = @_;

    die "unsupported format '$fmt'" if $fmt ne 'raw';

    my $api = _get_api($scfg, $storeid);

    # Size is in kilobytes, convert to bytes
    my $size_bytes = $size * 1024;

    my $pure_volname_base;
    my $pve_volname;

    # Check if this is a special volume type (state, cloudinit, fleece).
    #
    # PVE asks for a specific name in four places, and we must honour it in
    # all of them — LVMPlugin and ZFSPoolPlugin accept any "vm-<vmid>-<...>"
    # for the same reason:
    #   QemuConfig.pm          "vm-<vmid>-state-<snap>"   RAM snapshot
    #   API2/Qemu, Cloudinit   "vm-<vmid>-cloudinit"      cloud-init drive
    #   VZDump/QemuServer.pm   "vm-<vmid>-fleece-<n>"     backup fleecing
    #   API2/Storage/Content   whatever the operator typed to `pvesm alloc`
    #
    # Anything not recognised used to fall through to the regular-disk branch,
    # which IGNORED the requested name and allocated "vm-<vmid>-disk-<N>"
    # instead. Fleecing images therefore came back looking like ordinary VM
    # disks and consumed a disk id. Refuse instead: a silent substitution
    # would hide the next special name PVE invents, whereas an error names the
    # problem on the first backup that hits it.
    if ($name && $name =~ /^vm-(\d+)-state-(.+)$/) {
        # VM state volume for RAM snapshot
        my ($state_vmid, $snapname) = ($1, $2);
        $pure_volname_base = pve_volname_to_pure($storeid, $name);
        $pve_volname = $name;
    } elsif ($name && $name =~ /^vm-(\d+)-cloudinit$/) {
        # Cloud-init volume
        $pure_volname_base = pve_volname_to_pure($storeid, $name);
        $pve_volname = $name;
    } elsif ($name && $name =~ /^vm-(\d+)-fleece-(\d+)$/) {
        # Backup fleecing image
        $pure_volname_base = pve_volname_to_pure($storeid, $name);
        $pve_volname = $name;
    } elsif ($name && $name !~ /^(?:vm|base)-\d+-disk-\d+$/) {
        die "Cannot allocate volume '$name' on storage '$storeid': the "
          . "purestorage plugin does not know how to name that on the array. "
          . "It understands vm-<vmid>-disk-<n>, vm-<vmid>-cloudinit, "
          . "vm-<vmid>-state-<snapshot> and vm-<vmid>-fleece-<n>. Allocating "
          . "under a different name would silently give you a volume called "
          . "something else.\n";
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
        if ($name && ($name =~ /^vm-\d+-state-/ || $name =~ /^vm-\d+-cloudinit$/
                      || $name =~ /^vm-\d+-fleece-\d+$/)) {
            warn "Found orphaned state/cloudinit volume '$pure_volname', attempting cleanup...\n";

            # This was the ONLY destructive path in the plugin with no in-use
            # check at all: it disconnected and destroyed whatever it found
            # under the name. A vm-<id>-state-<snap> volume holding a live
            # suspended guest's RAM image would be thrown away with nothing
            # but a warn() to show for it. Apply the same guard every other
            # destroy path uses; refusing here is safe because PVE will
            # surface the error and the operator can clean up deliberately.
            my $orphan_wwid = _require_wwid_for_guard(
                $api, $pure_volname, 'replace existing state/cloudinit volume');
            _assert_device_idle(
                $orphan_wwid, $pve_volname // $name,
                'replace existing state/cloudinit volume');

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
    if ($name && ($name =~ /^vm-\d+-state-/ || $name =~ /^vm-\d+-cloudinit$/
                  || $name =~ /^vm-\d+-fleece-\d+$/)) {
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
            eval { multipath_reload_throttled(); };

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

    my $api = _get_api($scfg, $storeid);
    my $pure_volname_base = pve_volname_to_pure($storeid, $volname);
    my $pure_volname = _get_full_volname($scfg, $pure_volname_base);

    # Check if volume exists on Pure Storage
    my $vol = eval { $api->volume_get($pure_volname); };
    unless ($vol) {
        warn "Volume '$pure_volname' not found on Pure Storage, may have been already deleted\n";
        return undef;
    }

    # Step 1: Get the WWID and verify the local device is not in use.
    # Both halves refuse rather than fall through: a WWID lookup failure used
    # to skip the whole check, and an undetermined in-use answer used to read
    # as "idle". Either one let free_image destroy a volume a running guest
    # was using.
    my $wwid = _require_wwid_for_guard($api, $pure_volname, 'delete volume');
    _assert_device_idle($wwid, $volname, 'delete volume');

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
    my $connections;
    {
        my $err;
        for my $attempt (1 .. 2) {
            $connections = eval { $api->volume_get_connections($pure_volname); };
            $err = $@;
            last unless $err;
            sleep(1) if $attempt == 1;
        }
        if ($err) {
            chomp $err;
            # Deleting a volume we could not disconnect leaves orphaned host
            # connections behind. Other cluster nodes then discover a LUN
            # whose volume no longer exists, which becomes a stale multipath
            # device — the exact failure that motivated the whole residual
            # cleanup architecture. Refuse and let the operator retry.
            die "Refusing to delete volume '$pure_volname': its host "
              . "connections could not be listed, so they cannot be removed "
              . "first. Deleting now would leave ghost LUNs on the other "
              . "cluster nodes. Retry once the array is reachable. "
              . "Underlying error: $err\n";
        }
    }
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
                # Pass the WWID: this list was captured before the array-side
                # disconnect, and the kernel may have reused the /dev/sdX name
                # for an unrelated LUN in the meantime.
                eval { remove_scsi_device($slave, expect_wwid => $wwid); };
            }
        }

        # Step 6: Final multipath reload to settle any leftover state.
        eval { multipath_reload_throttled(); };
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
        my $san_storage = storeid_to_pure_prefix($storeid);
        my $disk_pattern = "pve-${san_storage}-${vmid}-disk*";
        my $pod = $scfg->{'pure-pod'};
        $disk_pattern = "${pod}::${disk_pattern}" if $pod;

        # See _cleanup_vm_config_volumes: this was passing named arguments to
        # a positional-only function, so $remaining was always empty and this
        # branch always believed it had just removed the VM's last disk.
        my $remaining = eval { $api->volume_list($disk_pattern); };
        if ($@) {
            # Could not establish whether other disks remain. Do NOT guess:
            # guessing "none left" destroys the config backups that the other
            # disks' snapshots still point at. Leaving them costs 1 MB each.
            warn "Could not list remaining disks for VM $vmid, skipping config "
               . "volume cleanup (they will be removed with the VM's last "
               . "disk on a later attempt): $@\n";
            $remaining = undef;
        }
        # Filter out destroyed volumes
        $remaining = [grep { !$_->{destroyed} } @{ $remaining // [] }]
            if defined $remaining;

        if (defined $remaining && !@$remaining) {
            # No more disks, cleanup all config volumes for this VM
            eval { _cleanup_vm_config_volumes($api, $scfg, $storeid, $vmid); };
            if ($@) {
                warn "Config volume cleanup failed (non-fatal): $@\n";
            }
        }
    }

    return undef;
}


# If this volume is a linked clone of one of our templates, return the base
# volume's PVE volname ("base-102-disk-0"); otherwise undef.
#
# Pure records a cloned volume's origin in the `source` field. We only accept
# a source that is specifically a ".pve-base" snapshot, because that is the
# exact and only thing clone_image() clones from when it produces the
# "base/clone" volid form. A source pointing at a plain volume or at a
# ".pve-snap-*" snapshot is a full clone or a clone from a user snapshot, and
# those correctly carry the bare volname — matching on them would invent a
# dependency that does not exist and produce the mirror-image of the bug this
# is here to fix.
#
# Returns undef when the array does not report `source` at all, which is the
# safe direction: no change from previous behaviour.
#
# `source` itself is confirmed: Pure's generated client declares it on the
# Volume model from API 2.0 onward as "A reference to the originating volume as
# a result of a volume copy", and it is a FixedReference object in 2.x versus a
# plain string in 1.x -- hence the ref() check below.
#
# What the documentation does NOT settle is whether a copy made from a SNAPSHOT
# reports the snapshot or the parent volume. REST 1.17 documents the POST
# parameter as "the name of a volume or snapshot whose data is copied", but no
# GET example shows a snapshot-form value. If an array reports the parent
# volume, this returns undef and linked clones keep their bare name, i.e. the
# pre-v1.1.24 behaviour. To settle it on a live array, take a linked clone and
# look at what the volume reports:
#
#   curl -sk -H "x-auth-token: $TOK" \
#     "https://<array>/api/2.26/volumes?names=<clone>" | jq '.items[].source'
#
# A value ending in `.pve-base` means this works; the parent volume name means
# it silently does not, and widening the match is NOT the fix -- a full clone
# reports its parent too, so accepting that would invent a dependency that does
# not exist.
sub _linked_clone_base {
    my ($scfg, $vol) = @_;

    my $src = $vol->{source};
    $src = $src->{name} if ref($src) eq 'HASH';
    return undef unless defined $src && length $src;

    $src = _strip_pod_prefix($scfg, $src);
    return undef unless $src =~ /^(.+)\.pve-base$/;

    my $base_pure = $1;
    my $decoded = decode_volume_name($base_pure);
    return undef unless $decoded && ($decoded->{type} // '') eq 'disk';

    return "base-$decoded->{vmid}-disk-$decoded->{diskid}";
}

sub list_images {
    my ($class, $storeid, $scfg, $vmid, $vollist, $cache) = @_;

    my $api = _get_api($scfg, $storeid);

    my @res;

    # Build filter pattern
    my $san_storage = storeid_to_pure_prefix($storeid);

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

        # Linked clones must be reported in the "base-X-disk-N/vm-Y-disk-M"
        # form, exactly as clone_image() returned it and as it is stored in
        # the guest config. RBDPlugin does the same thing from the rbd
        # image's parent snapshot; this is the Pure equivalent, keyed off the
        # volume's clone source.
        #
        # Reporting the bare "vm-Y-disk-M" instead is not cosmetic. In
        # PVE::QemuServer::update_disk_config (which `qm rescan` drives), the
        # config's volid marks the volume referenced, and the volid WE report
        # is what gets checked against that set. If they disagree, the volume
        # looks unreferenced and PVE calls add_unused_volume() — the guest
        # ends up with an "unusedN" entry pointing at the very same Pure
        # volume its scsi0 is running on, and removing that unused disk in
        # the GUI destroys the live disk.
        if ($decoded->{type} eq 'disk' && !$is_template{$vol->{name}}) {
            if (my $base = _linked_clone_base($scfg, $vol)) {
                $pve_volname = "$base/$pve_volname";
            }
        }

        my $volid = "$storeid:$pve_volname";

        # Filter by vollist if provided.
        #
        # $vollist holds complete volids — PVE::Storage::vdisk_list() runs
        # each entry through parse_volume_id() before handing them down — so
        # the comparison must be exact, which is what the base plugin does.
        # This used to be a PREFIX match, which silently returned extra
        # volumes as soon as one disk id was a prefix of another: filtering
        # for "store:vm-10-disk-1" also matched "store:vm-10-disk-10" and
        # "store:vm-10-disk-11". No current PVE caller passes a vollist, but
        # returning volumes the caller did not ask for is the kind of thing
        # that turns into "migration moved a disk I did not select".
        if ($vollist) {
            next unless grep { $_ eq $volid } @$vollist;
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

    my $api = _get_api($scfg, $storeid);
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
    my ($class, $scfg, $storeid, $volname, $size, $running, $snapname) = @_;

    # Pure Storage supports online resize, no need to check $running
    # Note: $running parameter is kept for API compatibility

    # API version 14 added $snapname, for storages that keep snapshots as a
    # chain of volumes and therefore have a resizable object per snapshot.
    # Ours live on the array and are not resizable, so resizing the parent
    # volume instead -- which is what silently dropping the parameter would
    # do -- would grow the wrong thing. PVE only reaches this with
    # 'snapshot-as-volume-chain' set, which this plugin does not offer, so
    # this is a guard against a future caller rather than a live path. The
    # base plugin refuses the same case with the same reasoning.
    die "resizing a snapshot is not supported by the Pure Storage plugin "
        . "(volume '$volname', snapshot '$snapname'). Snapshots live on the "
        . "array and have no independently resizable object; resize the "
        . "volume itself instead.\n"
        if defined($snapname) && $snapname ne '';

    my $api = _get_api($scfg, $storeid);
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
    #
    # This is deliberately NOT gated on $running. It used to be, and that left
    # a stopped VM's device at its old size: resize while stopped, start the
    # VM, and qemu opens /dev/mapper/<wwid> which still reports the old
    # capacity, so the guest sees the old disk. The refresh is cheap and is a
    # no-op when this node has no local device for the volume, so there is no
    # reason to skip it. _refresh_local_capacity() in activate_volume covers
    # the other half of the problem: a resize performed on a different node.
    #
    # The whole block is best-effort: the array-side resize has ALREADY
    # succeeded by this point, so a local refresh failure must not make PVE
    # report the resize as failed — it would then show the old size while the
    # array shows the new one, and a retry would be rejected as a shrink.
    eval {
        my $wwid = eval { $api->volume_get_wwid($pure_volname); };
        if ($wwid) {
            my $device = eval { get_device_by_wwid($wwid); };
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
    };
    warn "Volume '$volname' was resized on the array, but refreshing the local "
       . "device capacity failed. The guest may see the old size until this "
       . "node rescans (starting the guest triggers a rescan): $@" if $@;

    return 1;
}

#
# Volume activation
#


# Make the local block device agree with the array about this volume's size.
#
# Capacity changes do not propagate to a host on their own in any way we can
# rely on. volume_resize() refreshes the node it runs on, but a Proxmox VE
# cluster can resize a disk on node A and start the guest on node B, and node
# B has then never been told. The multipath map there keeps reporting the old
# capacity, qemu opens it at that size, and the guest sees the old disk —
# silently, with no error anywhere.
#
# activate_volume() already fetches the volume object (to check existence), so
# the array-side size is in hand for free. Compare it against what the kernel
# thinks and only do the (more expensive) per-path rescan when they disagree,
# which is almost never. Purely corrective: never shrinks anything, and any
# failure is a warning, because a size mismatch must not block starting a
# guest that would otherwise work.
sub _refresh_local_capacity {
    my ($device, $expected_bytes, $volname) = @_;

    return unless $device && defined $expected_bytes && $expected_bytes > 0;

    my $actual;
    eval {
        my $out = '';
        PVE::Tools::run_command(['/sbin/blockdev', '--getsize64', $device],
            timeout => 10, outfunc => sub { $out .= shift });
        $out =~ s/\s+//g;
        $actual = $out =~ /^\d+$/ ? $out + 0 : undef;
    };
    return unless defined $actual;
    return if $actual == $expected_bytes;

    warn "Volume '$volname': local device $device reports $actual bytes but the "
       . "array reports $expected_bytes. Refreshing the local capacity — the "
       . "volume was most likely resized from another node.\n";

    eval {
        my $slaves = get_multipath_slaves($device) // [];
        for my $slave (@$slaves) {
            eval { rescan_scsi_device($slave); };
        }
        multipath_resize_map($device);
        _udev_refresh();
    };
    warn "Volume '$volname': capacity refresh failed (the guest may see the "
       . "old size until this node rescans): $@" if $@;
}

sub activate_volume {
    my ($class, $storeid, $scfg, $volname, $snapname, $cache) = @_;

    my $api = _get_api($scfg, $storeid);
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

    # Get volume WWID for device identification
    my $wwid = eval { $api->volume_get_wwid($pure_volname); };
    unless ($wwid) {
        die "Cannot get WWID for volume '$pure_volname'. " .
            "This may indicate a Pure Storage API issue.";
    }

    # Fast path: the device is usually already present (the volume was
    # connected before, or another activation on this node already discovered
    # it). Check before doing anything expensive. The old order rescanned the
    # transport, scanned every SCSI host and issued a host-wide `multipathd
    # reconfigure` FIRST, unconditionally — so the common case paid the full
    # cost, and worse, activate_volume is on the path of VM start and backup
    # preparation, where that reconfigure churns maps other operations are
    # concurrently trying to use.
    {
        my $existing = eval { get_device_by_wwid($wwid); };
        if ($existing && -b $existing) {
            _refresh_local_capacity($existing,
                $vol->{provisioned} // $vol->{size}, $volname);
            eval { _track_wwid($storeid, $wwid); };
            return 1;
        }
    }

    # Not present yet: rescan for it. wait_for_multipath_device() below runs
    # its own escalation ladder (transport rescan -> SCSI host scan -> udev ->
    # throttled reconfigure), so do not duplicate the expensive steps here.
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

    eval { rescan_scsi_hosts(); };
    if ($@) {
        warn "Warning: SCSI host rescan failed: $@\n";
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
        # Device discovery failed. Capture the host-side state NOW, while it
        # is still the state that produced the failure — by the time an
        # operator runs 'multipath -ll' by hand the transient is long gone,
        # which is exactly what made this class of report unanswerable.
        my $diag_msg = "Device for volume '$pure_volname' (WWID: $wwid) did not appear within ${timeout}s.\n";
        $diag_msg .= "Diagnostics:\n";
        $diag_msg .= "  - Protocol: $protocol\n";
        $diag_msg .= "  - Host: $host\n";
        $diag_msg .= "  - Volume connected: " . ($was_connected ? "yes (pre-existing)" : "yes (just connected)") . "\n";

        my $state = eval { describe_wwid_state($wwid); } // '';
        $diag_msg .= "$state\n" if $state;

        if ($protocol eq 'fc') {
            my $fc_targets = eval { get_fc_targets(); } // [];
            my @online = grep { $_->{is_target} && ($_->{port_state} // '') =~ /online/i } @$fc_targets;
            $diag_msg .= "  - FC targets visible: " . scalar(@online) . " online of "
                . scalar(@$fc_targets) . " total\n";
            $diag_msg .= "  - Check: FC HBA status, FC switch zoning, fiber connections\n";
            $diag_msg .= "  - Try: 'cat /sys/class/fc_host/host*/port_state' to verify FC port status\n";
        } else {
            # Session state matters specifically: rescan_sessions() only
            # rescans sessions the kernel reports as LOGGED_IN, so a session
            # sitting in FAILED/REOPEN is silently skipped and no amount of
            # waiting will surface a LUN behind it.
            my $sessions = eval { get_session_states(); } // [];
            if (@$sessions) {
                $diag_msg .= "  - iSCSI sessions (" . scalar(@$sessions) . "):\n";
                for my $s (@$sessions) {
                    $diag_msg .= "      $s->{session}: state="
                        . ($s->{state} // 'unreadable')
                        . " portal=" . ($s->{portal} // '?') . "\n";
                }
                my @bad = grep { ($_->{state} // '') ne 'LOGGED_IN' } @$sessions;
                $diag_msg .= "    NOTE: " . scalar(@bad) . " session(s) are not LOGGED_IN."
                    . " LUN rescan is only issued on LOGGED_IN sessions, so a LUN"
                    . " reachable only through those paths cannot be discovered until"
                    . " they recover.\n" if @bad;
            } else {
                $diag_msg .= "  - iSCSI sessions: NONE. This node has no iSCSI session to"
                    . " the array, so no LUN can appear. Check network reachability to"
                    . " the array's iSCSI portals.\n";
            }
            $diag_msg .= "  - Try: 'iscsiadm -m session' to verify iSCSI sessions\n";
        }
        $diag_msg .= "  - Try: 'multipath -ll' to check multipath device status\n";
        $diag_msg .= "  - If the device shows up healthy moments later, raise"
            . " 'pure-device-timeout' (currently ${timeout}s).\n";

        die $diag_msg;
    }

    # Track the WWID so cluster residual cleanup can find a stale device for
    # it later. path() has always done this, but a node can legitimately
    # activate a volume without path() being called on it, and an untracked
    # WWID is invisible to the orphan reaper once the volume is gone from the
    # array (Phase 1 can only re-import WWIDs that still exist there).
    _refresh_local_capacity($device, $vol->{provisioned} // $vol->{size}, $volname);

    eval { _track_wwid($storeid, $wwid); };

    return 1;
}

sub deactivate_volume {
    my ($class, $storeid, $scfg, $volname, $snapname, $cache) = @_;

    my $api = _get_api($scfg, $storeid);
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

    my $api = _get_api($scfg, $storeid);
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
        # The marker is "-tsa-", not the "-temp-snap-access-" this used to
        # generate. Pure rejects a volume name over 63 characters outright --
        # "Volume name must be between 1 and 63 characters (alphanumeric, '_'
        # and '-') in length and begin and end with a letter or number" -- and
        # the old 36-character suffix left room for a storage id of only 10.
        # `purestorage` is 11, so the most obvious name anyone would pick
        # already broke snapshot access: backing up from a snapshot, qemu-img
        # convert out of one, a container backup. The shorter marker raises the
        # workable storage id to 23, one below the 24 the schema allows.
        #
        # Both reapers recognise the old marker as well, so clones created
        # before this release are still collected.
        my $temp_clone_name = "${pure_volname}-tsa-${timestamp}-$$";

        if (length($temp_clone_name) > MAX_PURE_VOLUME_NAME) {
            die "Cannot create the snapshot access volume for '$volname': the "
              . "name would be " . length($temp_clone_name) . " characters "
              . "and the array accepts at most " . MAX_PURE_VOLUME_NAME . ".\n"
              . "  Name: $temp_clone_name\n"
              . "  It is the volume name plus 23 characters, and the volume "
              . "name is derived from the storage id, so the storage id is "
              . "what pushes it over. Use a storage id of at most 23 "
              . "characters; the disk volumes themselves are unaffected and "
              . "need no change.\n";
        }

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
        multipath_reload_throttled();

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
            # Throttled: a host-wide `multipathd reconfigure` every 2 seconds
            # rebuilds every map on the node and can transiently hide the very
            # map being waited for.
            multipath_reload_throttled();

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

    my $api = _get_api($scfg, $storeid);

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
        # Soft-destroy for the same reason as the orphan reaper above:
        # no automated path in this plugin should perform an unrecoverable
        # eradication.
        $api->volume_delete($temp_vol, skip_eradicate => 1);
    };

    delete $_temp_snap_clones{$cache_key};
}

# Sweep temporary snapshot-access clones belonging to one volume.
#
# Why this exists: Proxmox VE gives the plugin no reliable hook to release a
# snapshot-access clone. Container backup is the clear case —
# PVE::VZDump::LXC calls activate_volumes($cfg, $volids, 'vzdump'), which
# lands in our path() and creates a clone on the array, connects it to this
# host and waits for its multipath device. It then mounts it, rsyncs, umounts,
# and deletes the 'vzdump' snapshot. It never calls deactivate_volume() at
# all — grep VZDump/LXC.pm for it and you get zero hits — so
# _cleanup_temp_snap_clone() is never invoked and the clone survives the
# backup. That is one leaked Pure volume, one host connection and one local
# multipath device per container mountpoint per backup run.
#
# The orphan reaper does eventually collect them, but it only starts counting
# at one hour, and on any API 2.x array it never fired at all before v1.1.22
# (its age test read millisecond timestamps as seconds). Sites doing nightly
# container backups have therefore been accumulating these since the plugin
# was first installed.
#
# volume_snapshot_delete() is the deterministic trigger PVE does give us: the
# backup deletes its 'vzdump' snapshot when it finishes, and a user deleting a
# snapshot has equally finished with any clone taken from it.
#
# Safety gates, same as the background reaper:
#   - the name must match exactly what path() generates
#   - min_age seconds must have passed (a clone created seconds ago may belong
#     to a concurrent operation in another process on this node)
#   - it must not be connected to any host other than this one
#   - cleanup_lun_devices() croaks if the local device is in use, which aborts
#     before the delete
sub _sweep_temp_snap_clones {
    my ($scfg, $storeid, $api, $pure_volname, %opts) = @_;

    my $min_age = $opts{min_age} // 60;
    my $my_host = _get_host_name($scfg);

    # In shared host mode the connection tells us nothing about which node
    # made this clone, so the host check below cannot establish ownership.
    # Fall back to age alone, at a threshold no live operation reaches.
    my $unowned = ($scfg->{'pure-host-mode'} // 'per-node') eq 'shared';
    $min_age = TEMP_CLONE_UNOWNED_MIN_AGE
        if $unowned && $min_age < TEMP_CLONE_UNOWNED_MIN_AGE;

    my $bare_vol = _strip_pod_prefix($scfg, $pure_volname);
    # Both markers, old and new -- see _cleanup_orphaned_temp_clones().
    my @patterns = ("${bare_vol}-tsa-*", "${bare_vol}-temp-snap-access-*");
    @patterns = map { "$scfg->{'pure-pod'}::$_" } @patterns
        if $scfg->{'pure-pod'};

    my %by_name;
    for my $pattern (@patterns) {
        my $found = eval { $api->volume_list($pattern); } // [];
        $by_name{ $_->{name} } = $_ for grep { $_->{name} } @$found;
    }
    my $vols = [ values %by_name ];
    return 0 unless @$vols;

    my $strict_re = qr/^\Q$bare_vol\E-(?:tsa|temp-snap-access)-(\d+)-(\d+)$/;
    my $removed = 0;

    for my $vol (@$vols) {
        next unless $vol->{name};
        my ($ts) = _strip_pod_prefix($scfg, $vol->{name}) =~ $strict_re;
        next unless defined $ts;
        next if (time() - $ts) < $min_age;

        my $conns = eval { $api->volume_get_connections($vol->{name}); };
        next if $@;
        next if grep { ($_->{name} // '') ne $my_host } @{ $conns // [] };

        eval {
            my $wwid = $vol->{serial}
                ? $api->serial_to_wwid($vol->{serial})
                : $api->volume_get_wwid($vol->{name});
            cleanup_lun_devices($wwid) if $wwid;

            for my $conn (@{ $conns // [] }) {
                $api->volume_disconnect_host($vol->{name}, $conn->{name});
            }
            $api->volume_delete($vol->{name}, skip_eradicate => 1);
            $removed++;
        };
        if ($@) {
            warn "temp-clone sweep: could not release $vol->{name} "
               . "(will be retried by the background reaper): $@";
        }
    }

    return $removed;
}

sub filesystem_path {
    my ($class, $scfg, $volname, $snapname) = @_;

    # PVE's storage config hash does NOT carry the storage id — $scfg->{storage}
    # is always undef (verified against PVE::Storage::config on 9.x). The old
    # body passed it straight through as the storeid, so every call died deep
    # inside Naming.pm with a bare "storage is required" and no indication of
    # where it came from.
    #
    # Every Pure volume name is derived from the storeid, so this method simply
    # cannot be implemented without one. Nothing in PVE reaches it for this
    # plugin today: the base-class methods that use filesystem_path
    # (activate_volume, volume_size_info) are all overridden here, and
    # PVE::Storage::abs_filesystem_path goes through PVE::Storage::path, which
    # does pass the storeid. Fail loudly and legibly if a future caller shows up.
    my $storeid = $scfg->{storage};  ## audit-ok: A9 - read deliberately, only to
                                     ## produce the actionable error below.
    die "filesystem_path is not supported by the purestorage plugin "
        . "(volume '$volname'): Pure volume names are derived from the storage "
        . "id, which is not available in this call. Use "
        . "PVE::Storage::path()/\$plugin->path(\$scfg, \$volname, \$storeid) instead.\n"
        unless defined $storeid && length $storeid;

    my ($path, $vmid, $format) = $class->path($scfg, $volname, $storeid, $snapname);
    return wantarray ? ($path, $vmid, $format) : $path;
}

#
# Snapshot operations
#

# The base implementations of these two go through filesystem_path(), which
# this plugin cannot implement (Pure volume names are derived from the
# storeid, which PVE does not pass to it). Left inherited, a caller would get
# a confusing "filesystem_path is not supported" error, and base
# rename_snapshot() would additionally have attempted a filesystem rename().
#
# Neither is reachable today: every base call site is gated on
# `snapshot-as-volume-chain`, which is not among our options(), and the
# QemuServer call sites sit behind do_snapshots_type() eq 'external', which
# needs volume_qemu_snapshot_method() to return 'mixed' -- it returns
# 'storage' for our raw volumes. Refuse explicitly so that a future caller
# gets a straight answer instead of an error about a method it never named.
sub rename_snapshot {
    my ($class, $scfg, $storeid, $volname, $source_snap, $target_snap) = @_;

    die "renaming a snapshot is not supported by the Pure Storage plugin "
        . "(volume '$volname', '$source_snap' -> '$target_snap'). Snapshot "
        . "names encode the PVE snapshot name and are created and removed "
        . "together with it.\n";
}

sub volume_snapshot_info {
    my ($class, $scfg, $storeid, $volname) = @_;

    die "volume_snapshot_info is not supported by the Pure Storage plugin "
        . "(volume '$volname'): it describes a qcow2 volume chain, and "
        . "snapshots here live on the array. Use volume_snapshot_list().\n";
}

# Ask PVE to freeze a container's filesystem around volume_snapshot().
#
# PVE::LXC::Config::__snapshot_freeze() cgroup-freezes the container's
# processes unconditionally, but only calls fsfreeze_mountpoint() for
# mountpoints whose storage answers 1 here. Freezing the processes stops new
# writes; it does not flush the dirty pages the host kernel is already holding
# for that filesystem, and our snapshot is taken by the array over REST, out
# of band from this host's block layer. Without the fsfreeze, a running
# container's snapshot -- including a vzdump backup in snapshot mode -- is
# crash-consistent rather than filesystem-consistent.
#
# PVE::Storage::RBDPlugin does the same, for the same reason: a snapshot taken
# by a remote system cannot see this host's cache. Local-snapshot storages
# (LVM-thin, ZFS) inherit the base 0 because the same kernel owns both the
# filesystem and the snapshot.
#
# QEMU guests are unaffected either way: their filesystem quiescing is done by
# the guest agent from PVE::QemuConfig, which never consults this method.
#
# Failure is handled by PVE: fsfreeze_mountpoint() is called inside an eval
# and the thaw runs even when the snapshot itself dies, so a freeze that fails
# warns rather than leaving the container wedged.
sub volume_snapshot_needs_fsfreeze {
    return 1;
}

sub volume_snapshot {
    my ($class, $scfg, $storeid, $volname, $snap) = @_;

    my $api = _get_api($scfg, $storeid);
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
    # snapshot. The array copies what it has received; anything still sitting
    # in this host's page cache is not in the snapshot.
    #
    # This used to skip the flush when the device was in use, to avoid
    # blocking on a busy host. That was backwards. "In use" is precisely the
    # case that has dirty pages: an LXC container's filesystem is mounted by
    # the HOST kernel, so its writes land in host page cache, and PVE's
    # container freeze (AbstractConfig::snapshot_create -> __snapshot_freeze)
    # only cgroup-freezes the processes -- it stops new writes without pushing
    # the existing dirty ones out. A running qemu guest is the opposite case:
    # it holds the device O_DIRECT, so there is little host cache to flush and
    # only the guest agent can quiesce the guest's own filesystem. So the
    # flush costs a running VM almost nothing and is the whole point for a
    # running container.
    #
    # Both calls are bounded and non-fatal: the snapshot is still worth taking
    # if the host is too busy to flush in time, it is just less consistent.
    # See also volume_snapshot_needs_fsfreeze(), which asks PVE to freeze a
    # container's filesystem properly around this call.
    my $wwid = eval { $api->volume_get_wwid($pure_volname); };
    if ($wwid) {
        my $device = get_device_by_wwid($wwid);
        if ($device && -b $device) {
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

    my $api = _get_api($scfg, $storeid);
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

    # Release any snapshot-access clone taken from this volume. Deleting the
    # snapshot means the caller is done with it, and for container backups
    # this is the ONLY hook PVE gives us — VZDump::LXC never calls
    # deactivate_volume(), so without this the clone leaks until the
    # background reaper picks it up an hour later (and, before v1.1.22 on an
    # API 2.x array, never). See _sweep_temp_snap_clones.
    eval {
        my $n = _sweep_temp_snap_clones($scfg, $storeid, $api, $pure_volname);
        warn "Released $n temporary snapshot-access clone(s) for '$volname'\n" if $n;
    };
    warn "Temporary snapshot-clone sweep failed (non-fatal): $@\n" if $@;

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

    my $api = _get_api($scfg, $storeid);
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

    # Safety check: verify the device is not in use before rollback.
    # This is the most destructive operation the plugin performs — the
    # overwrite replaces the volume's contents outright and, unlike a
    # destroy, has NO eradication-delay recovery window. Neither a failed
    # WWID lookup nor an undetermined in-use answer may skip the guard.
    my $wwid = _require_wwid_for_guard($api, $pure_volname, 'roll back volume');
    _assert_device_idle($wwid, $volname, 'roll back volume');

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

    my $api = _get_api($scfg, $storeid);
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
            # PVE expects epoch SECONDS. Pure REST 2.x reports milliseconds,
            # 1.x reports an ISO 8601 string; passing either through verbatim
            # rendered snapshot dates in the Web UI as garbage (a millisecond
            # value read as seconds lands ~53000 years in the future).
            ctime  => PVE::Storage::Custom::PureStorage::API::pure_time_to_epoch(
                $snap->{created}),
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
    } elsif ($parsed->{type} eq 'fleece') {
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

    my $api = _get_api($scfg, $storeid);
    my $pure_volname = _get_full_volname($scfg, pve_volname_to_pure($storeid, $volname));

    # Verify volume exists on Pure Storage
    my $vol = eval { $api->volume_get($pure_volname); };
    unless ($vol) {
        die "Cannot create template: volume '$pure_volname' not found on Pure Storage\n";
    }

    # Safety check: verify the volume is not currently in use. Converting a
    # live volume to a template would freeze a base snapshot of an
    # inconsistent, actively-written image. Same fail-closed rule as
    # free_image and rollback.
    my $wwid = _require_wwid_for_guard($api, $pure_volname, 'convert volume to template');
    _assert_device_idle($wwid, $volname, 'convert volume to template');

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

    my $api = _get_api($scfg, $storeid);

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

    my $api = _get_api($scfg, $storeid);

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
