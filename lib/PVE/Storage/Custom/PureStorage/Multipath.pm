# Pure Storage Multipath Management Utilities
# Copyright (c) 2026 Jason Cheng (Jason Tools)
# Licensed under the MIT License

package PVE::Storage::Custom::PureStorage::Multipath;

use strict;
use warnings;

use Carp qw(croak);
use IPC::Open3;
use Symbol qw(gensym);
use IO::Select;
use File::Basename qw(basename dirname);
use POSIX ();

use Exporter qw(import);

our @EXPORT_OK = qw(
    rescan_scsi_hosts
    multipath_reload
    multipath_reload_throttled
    describe_wwid_state
    multipath_flush
    multipath_resize_map
    get_multipath_device
    get_device_by_wwid
    wait_for_multipath_device
    remove_scsi_device
    rescan_scsi_device
    get_multipath_slaves
    cleanup_lun_devices
    is_device_in_use
    device_usage_state
    sysfs_write_with_timeout
    sysfs_read_with_timeout
    list_pure_multipath_devices
    get_device_usage_details
);

# Constants
use constant {
    MULTIPATHD         => '/sbin/multipathd',
    MULTIPATH          => '/sbin/multipath',
    SG_INQ          => '/usr/bin/sg_inq',
    SCSI_HOST_PATH     => '/sys/class/scsi_host',
    SCSI_DEVICE_PATH   => '/sys/class/scsi_device',
    BLOCK_DEVICE_PATH  => '/sys/class/block',
    DEVICE_WAIT_TIMEOUT   => 60,
    DEVICE_WAIT_INTERVAL  => 1,
    # Minimum seconds between two host-wide `multipathd reconfigure` calls
    # issued by this process. See multipath_reload_throttled().
    RECONFIGURE_MIN_INTERVAL => 30,
};

# Process-wide timestamp of the last `multipathd reconfigure` we issued.
our $LAST_RECONFIGURE = 0;

# Untaint a device name (e.g., sda, dm-0)
sub _untaint_device_name {
    my ($name) = @_;
    return undef unless defined $name;
    # Allow device names like: sda, sda1, dm-0, nvme0n1, 3600a0980...
    if ($name =~ /^([a-zA-Z0-9_\-]+)$/) {
        return $1;
    }
    return undef;
}

# Untaint a device path (e.g., /dev/sda, /dev/mapper/mpath0)
sub _untaint_device_path {
    my ($path) = @_;
    return undef unless defined $path;
    # Allow paths like: /dev/sda, /dev/mapper/3600a0980..., /dev/disk/by-id/...
    if ($path =~ m|^(/dev/[a-zA-Z0-9_\-/\.]+)$|) {
        return $1;
    }
    return undef;
}

# Resolve a device path to the kernel name used in /sys/block/.
# Handles all three forms:
#   /dev/sdX            -> sdX
#   /dev/dm-N           -> dm-N
#   /dev/mapper/<name>  -> dm-N (resolves symlink)
#
# Why this matters: /dev/mapper/<wwid> is a symlink to /dev/dm-N. If you
# `basename()` the mapper path you get the wwid string, then
# /sys/block/<wwid>/{holders,slaves} does NOT exist — those are under
# /sys/block/dm-N/. Without this resolver:
#   - is_device_in_use() would never see LVM/dm-crypt holders → silent
#     data loss when free_image() proceeds to delete an in-use volume.
#   - get_multipath_slaves() would never enumerate the underlying SCSI
#     paths → free_image() would leak SCSI device residue.
sub _resolve_block_device_name {
    my ($device) = @_;
    return undef unless defined $device;

    # If it's a symlink (typical for /dev/mapper/*), resolve to target.
    if (-l $device) {
        my $target = readlink($device);
        if (defined $target) {
            # readlink may return a relative path like "../dm-9".
            if ($target !~ m|^/|) {
                my $dir = dirname($device);
                $target = "$dir/$target";
            }
            # Normalize "/foo/../" sequences.
            while ($target =~ s|/[^/]+/\.\./|/|g) {}
            $device = $target;
        }
    }

    return _untaint_device_name(basename($device));
}

# Untaint a path component
sub _untaint_path {
    my ($path) = @_;
    return undef unless defined $path;
    # Allow safe path characters
    if ($path =~ m|^([a-zA-Z0-9_\-/\.]+)$|) {
        return $1;
    }
    return undef;
}

# Write to a sysfs file in a forked child with timeout.
# Direct writes to /sys/... can enter uninterruptible sleep (D state) if the
# underlying kernel layer is unresponsive (e.g. dead SCSI host or stale device).
# kill -9 cannot recover such a process — only reboot will. Forking lets the
# parent kill the child if it hangs and continue with the next operation.
sub sysfs_write_with_timeout {
    my ($path, $data, $timeout) = @_;
    $timeout //= 10;

    my $pid = fork();
    if (!defined $pid) {
        warn "fork failed for sysfs write to $path: $!\n";
        return 0;
    }

    if ($pid == 0) {
        # Child: do the sysfs write, then exit immediately
        eval {
            open(my $fh, '>', $path) or die "open: $!";
            print $fh $data;
            close($fh);
        };
        POSIX::_exit($@ ? 1 : 0);
    }

    # Parent: wait for child with timeout
    my $deadline = time() + $timeout;
    while (time() < $deadline) {
        my $res = waitpid($pid, POSIX::WNOHANG());
        if ($res > 0) {
            return ($? >> 8) == 0 ? 1 : 0;
        }
        return 1 if $res < 0;
        select(undef, undef, undef, 0.1);
    }

    # Timeout: kill the child
    warn "sysfs write to $path timed out after ${timeout}s, killing child pid $pid\n";
    kill('KILL', $pid);
    my $reaped = waitpid($pid, POSIX::WNOHANG());
    if ($reaped == 0) {
        warn "child pid $pid in uninterruptible sleep, cannot reap\n";
    }
    return 0;
}

# Read a sysfs/proc file in a forked child with alarm-based timeout.
# Reads to /sys/.../wwid, /sys/.../vpd_pg83, /proc/mounts, etc. can also enter
# D state on dead devices. The child reads, the parent waits with alarm.
sub sysfs_read_with_timeout {
    my ($path, $timeout) = @_;
    $timeout //= 5;

    pipe(my $read_fh, my $write_fh) or do {
        warn "pipe failed for sysfs read of $path: $!\n";
        return undef;
    };

    my $pid = fork();
    if (!defined $pid) {
        warn "fork failed for sysfs read of $path: $!\n";
        close($read_fh);
        close($write_fh);
        return undef;
    }

    if ($pid == 0) {
        # Child: read the file, send content through pipe
        close($read_fh);
        eval {
            open(my $fh, '<', $path) or die "open: $!";
            local $/;
            my $data = <$fh>;
            close($fh);
            print $write_fh ($data // '');
        };
        close($write_fh);
        POSIX::_exit($@ ? 1 : 0);
    }

    # Parent: read from pipe with alarm-based timeout
    close($write_fh);
    my $content = '';

    my $prev_alarm = alarm(0);   # suspend and remember any caller alarm
    eval {
        local $SIG{ALRM} = sub { die "timeout\n" };
        alarm($timeout);

        while (1) {
            my $buf;
            my $bytes = sysread($read_fh, $buf, 65536);
            last if !defined($bytes) || $bytes == 0;
            $content .= $buf;
        }

        alarm(0);
    };
    my $timed_out = $@;
    alarm($prev_alarm);
    close($read_fh);

    if ($timed_out) {
        warn "sysfs read of $path timed out after ${timeout}s, killing child pid $pid\n";
        kill('KILL', $pid);
        waitpid($pid, POSIX::WNOHANG());
        return undef;
    }

    # Bounded reap. We only get here after EOF on the pipe, so the child has
    # already closed its end and is on its way out — but nothing in this
    # module may block without a ceiling, and the alarm has been cleared by
    # this point so there would be nothing left to break us out.
    my $deadline = time() + 2;
    while (time() < $deadline) {
        last if waitpid($pid, POSIX::WNOHANG()) != 0;
        select(undef, undef, undef, 0.05);
    }
    return length($content) ? $content : undef;
}

# NOTE on alarm(): this module arms alarm() in several places and clears it
# with alarm(0). A bare alarm(0) also cancels any alarm the CALLER had armed,
# silently disarming their watchdog. PVE's own PVE::Tools::run_with_timeout
# avoids that with `my $prev = alarm 0; ... alarm $prev`, and the three
# funnels below (_run_cmd, sysfs_read_with_timeout) now do the same, so the
# hot paths are safe. Proxmox VE does not currently invoke storage plugins
# from inside an alarm — lock_file_full() arms one only around acquiring the
# lock, not around the callback — so the remaining sites are latent rather
# than live. Any NEW alarm use should save and restore.

# Reap a child that blew through its alarm budget, WITHOUT ever blocking.
#
# The obvious `kill('TERM', $pid); waitpid($pid, 0);` is a trap in exactly the
# scenario this whole module exists to survive: a child wedged in
# uninterruptible sleep (D state) inside the kernel block layer. Such a child
# cannot be killed by TERM *or* KILL, so the blocking waitpid never returns —
# and by that point our alarm has already fired and been cleared, so nothing
# is left to break us out. The timeout handler itself becomes the hang.
#
# Escalate TERM -> KILL and only ever reap with WNOHANG, on a short bounded
# poll. A child we cannot reap is left for init; it holds a kernel resource
# either way, and blocking here would only add our process to the casualty
# list. Same pattern as sysfs_write_with_timeout().
sub _reap_timed_out_child {
    my ($pid, $cmd) = @_;
    return unless $pid;

    for my $sig ('TERM', 'KILL') {
        kill($sig, $pid);
        my $deadline = time() + 2;
        while (time() < $deadline) {
            my $res = waitpid($pid, POSIX::WNOHANG());
            return if $res != 0;   # reaped, or already gone
            select(undef, undef, undef, 0.1);
        }
    }

    warn "child pid $pid for '@{$cmd // []}' did not die after TERM+KILL "
        . "(likely uninterruptible sleep in the kernel); leaving it to init\n";
}

# Run a command and return output
sub _run_cmd {
    my ($cmd, %opts) = @_;

    my $timeout = $opts{timeout} // 30;

    my ($stdout, $stderr) = ('', '');
    my $err = gensym;
    my $pid;

    my $prev_alarm = alarm(0);   # suspend and remember any caller alarm
    eval {
        local $SIG{ALRM} = sub { die "timeout\n" };
        alarm($timeout);

        $pid = open3(my $in, my $out, $err, @$cmd);
        close($in);

        # Use IO::Select to read stdout and stderr simultaneously
        # to avoid deadlock when stderr buffer fills up
        my $sel = IO::Select->new($out, $err);
        while (my @ready = $sel->can_read()) {
            for my $fh (@ready) {
                my $buf;
                my $bytes = sysread($fh, $buf, 8192);
                if (!defined($bytes) || $bytes == 0) {
                    $sel->remove($fh);
                    next;
                }
                if ($fh == $out) {
                    $stdout .= $buf;
                } else {
                    $stderr .= $buf;
                }
            }
        }

        # Covered by the alarm armed above: SIGALRM interrupts waitpid and
        # the handler dies, landing us in the timeout branch below, which
        # reaps without blocking. Do not "fix" this into WNOHANG polling.
        waitpid($pid, 0);
        alarm(0);
    };

    if ($@) {
        alarm($prev_alarm);
        if ($@ eq "timeout\n") {
            _reap_timed_out_child($pid, $cmd);
            croak "Command timed out after ${timeout}s: @$cmd";
        }
        croak "Command failed: $@";
    }
    alarm($prev_alarm);

    my $exit_code = $? >> 8;

    if ($exit_code != 0 && !$opts{ignore_errors}) {
        unless ($opts{allow_nonzero}) {
            croak "Command failed (exit $exit_code): @$cmd\nstderr: $stderr";
        }
    }

    return wantarray ? ($stdout, $stderr, $exit_code) : $stdout;
}

# Rescan all iSCSI SCSI hosts for new devices.
#
# CRITICAL: this function only iterates iSCSI hosts via
# /sys/class/iscsi_host/, NOT every entry in /sys/class/scsi_host/.
#
# Background: writing "- - -" to a non-iSCSI host's
# /sys/class/scsi_host/hostN/scan file triggers a driver-side full
# target rescan, which can hang for hundreds of seconds inside HBA
# drivers. Confirmed in production for HPE ProLiant servers with the
# smartpqi driver (P408i-a controller): writes entered D-state for
# 600+ seconds inside sas_user_scan(). D-state children CANNOT be
# reaped by SIGKILL, and they hold kernel scan locks until the driver
# finishes, causing cascading lock timeouts across PVE — every
# subsequent worker that touches the same scsi_host serializes behind
# the stuck child. Same risk applies to megaraid_sas (Dell PERC,
# Lenovo ThinkSystem RAID), mpt3sas (LSI HBAs), hpsa, ahci with bad
# SATA, and any future HBA driver.
#
# `sysfs_write_with_timeout()` does NOT save us here — its 10s parent
# timeout protects the parent process from blocking, but the D-state
# CHILD remains stuck and the kernel scan lock is still held.
#
# The categorically-correct fix is to NOT issue the operation on
# non-iSCSI hosts in the first place. /sys/class/iscsi_host/ is
# kernel-maintained: every iSCSI driver registers its hosts there via
# iscsi_host_alloc() (iscsi_tcp, iser, bnx2i, qla4xxx, qedi, be2iscsi,
# cxgb3i, cxgb4i, and any future iSCSI driver), and non-iSCSI drivers
# never do. So iterating that class is both exhaustive (catches every
# iSCSI host) and safe (cannot accidentally include a non-iSCSI host).
#
# For FC, rescan_fc_hosts() in FC.pm has its own targeted scan loop
# that only touches FC hosts.
sub rescan_scsi_hosts {
    my (%opts) = @_;

    my $iscsi_class = '/sys/class/iscsi_host';
    if (! -d $iscsi_class) {
        # iSCSI transport subsystem not loaded — nothing to rescan.
        # FC and other protocols handle their own rescans elsewhere.
        return 1;
    }

    opendir(my $dh, $iscsi_class) or return 1;
    my @hosts = grep { /^host\d+$/ } readdir($dh);
    closedir($dh);

    # No iSCSI hosts registered (storage not activated yet, or all
    # sessions disconnected). Nothing to rescan.
    return 1 unless @hosts;

    for my $host (@hosts) {
        # Untaint host name (validated by grep above).
        ($host) = $host =~ /^(host\d+)$/;
        next unless $host;

        my $scan_file = SCSI_HOST_PATH . "/$host/scan";
        if (-w $scan_file) {
            sysfs_write_with_timeout($scan_file, "- - -\n", 10);
        }
    }

    # Give the kernel time to discover devices.
    sleep($opts{delay} // 2);

    return 1;
}

# Reload multipath configuration.
#
# `multipathd reconfigure` is a HOST-WIDE sledgehammer: multipathd re-reads
# every config file and rebuilds every map on the node, not just ours. It is
# the right call after we edit /etc/multipath/conf.d/pure-storage.conf. It is
# the wrong call to put in a polling loop — while a reconfigure is in flight,
# `multipathd show maps` can report an incomplete map list, so a caller that
# reconfigures and then immediately looks for a map is racing itself. Two such
# loops running concurrently (a backup waiting for a device, and pvestatd's
# 10-second activate_storage poll) keep device-mapper permanently in flux.
sub multipath_reload {
    my (%opts) = @_;

    $LAST_RECONFIGURE = time();
    _run_cmd([MULTIPATHD, 'reconfigure'], allow_nonzero => 1, timeout => $opts{timeout} // 30);
    return 1;
}

# Rate-limited reconfigure for discovery/polling paths. Returns 1 if a
# reconfigure was actually issued, 0 if it was suppressed by the cooldown.
# Process-wide (not per-call) on purpose: pvedaemon and pvestatd are long-lived
# and each hosts several callers that would otherwise reconfigure independently.
sub multipath_reload_throttled {
    my (%opts) = @_;

    my $interval = $opts{min_interval} // RECONFIGURE_MIN_INTERVAL;
    return 0 if (time() - $LAST_RECONFIGURE) < $interval;

    eval { multipath_reload(%opts); };
    warn "multipath reconfigure failed: $@" if $@;
    return 1;
}

# Tell multipathd to re-read the size of an existing device-mapper map.
# Required after `volume_resize` or `volume_snapshot_rollback`: the
# underlying SCSI paths have new attributes but the multipath layer above
# still reports the old size until you explicitly resize the map. Without
# this, QEMU's block_resize will fail with "Cannot grow device files" even
# though the array and the SCSI paths have all updated correctly.
sub multipath_resize_map {
    my ($device, %opts) = @_;
    croak "device is required" unless $device;

    my $name = basename($device);
    my $safe_name = _untaint_device_name($name);
    return 0 unless $safe_name;

    eval {
        _run_cmd([MULTIPATHD, 'resize', 'map', $safe_name],
            allow_nonzero => 1, ignore_errors => 1, timeout => $opts{timeout} // 15);
    };
    return $@ ? 0 : 1;
}

# Flush a specific multipath device, with dmsetup fallback if multipath -f
# hangs or fails. NEVER call this without a $device argument: `multipath -F`
# (capital F) flushes ALL unused multipath maps system-wide and can wipe
# customer storage that the plugin does not own.
sub multipath_flush {
    my ($device, %opts) = @_;
    my $timeout = $opts{timeout} // 10;

    croak "multipath_flush requires a device argument; refusing to call 'multipath -F' which would flush ALL maps system-wide"
        unless $device;

    # Try `multipath -f` with timeout
    my (undef, undef, $exit) = eval {
        _run_cmd([MULTIPATH, '-f', $device],
            allow_nonzero => 1, ignore_errors => 1, timeout => $timeout);
    };
    my $err = $@;

    # If multipath -f hung or failed, fall back to dmsetup remove --force
    # which does not wait for queued I/O.
    if ($err || (defined $exit && $exit != 0)) {
        warn "multipath -f $device failed/timed out, trying dmsetup remove --force\n";
        my $name = basename($device);
        my $safe_name = _untaint_device_name($name);
        if ($safe_name) {
            eval {
                _run_cmd(['/sbin/dmsetup', 'remove', '--force', '--retry', $safe_name],
                    allow_nonzero => 1, ignore_errors => 1, timeout => 10);
            };
            warn "dmsetup remove also failed for $safe_name: $@" if $@;
        }
    }

    return 1;
}

# Get multipath device name by WWID
sub get_multipath_device {
    my ($wwid, %opts) = @_;

    croak "wwid is required" unless $wwid;

    my ($stdout) = _run_cmd(
        [MULTIPATHD, 'show', 'maps', 'raw', 'format', '%n %w'],
        allow_nonzero => 1,
        ignore_errors => 1,
    );

    return undef unless defined $stdout;

    for my $line (split /\n/, $stdout) {
        $line =~ s/^\s+|\s+$//g;
        my ($name, $map_wwid) = split /\s+/, $line, 2;
        next unless $name && $map_wwid;

        if (lc($map_wwid) eq lc($wwid)) {
            # Untaint the device path for taint mode compatibility
            my $safe_name = _untaint_device_name($name);
            return undef unless $safe_name;
            return _untaint_device_path("/dev/mapper/$safe_name");
        }
    }

    return undef;
}

# Get device path by WWID
sub get_device_by_wwid {
    my ($wwid, %opts) = @_;

    croak "wwid is required" unless $wwid;

    # First check multipath
    my $mpath = get_multipath_device($wwid);
    return $mpath if $mpath && -b $mpath;

    # Check /dev/disk/by-id (use exact suffix match to avoid substring collisions)
    # Wrap in alarm: the -b stat resolves the symlink to /dev/sd* or /dev/dm-*,
    # which can hang when all multipath paths are down with queue_if_no_path
    # still active (the same kernel block-layer wait that blocks vgs/lvs).
    my $wwid_lc = lc($wwid);
    my $found;
    eval {
        local $SIG{ALRM} = sub { die "timeout\n" };
        alarm(5);
        my @devices = grep { lc(($_=~ m/-([a-f0-9]+)$/i)[0] // '') eq $wwid_lc }
            glob("/dev/disk/by-id/wwn-*"), glob("/dev/disk/by-id/scsi-*");
        if (@devices && -b $devices[0]) {
            $found = $devices[0];
        }
        alarm(0);
    };
    alarm(0);
    if ($@ && $@ eq "timeout\n") {
        warn "get_device_by_wwid: /dev/disk/by-id lookup for $wwid timed out after 5s\n";
        return undef;
    }

    return $found ? _untaint_device_path($found) : undef;
}

# Wait for a multipath device to appear.
#
# Options:
#   timeout      - max wall-clock wait in seconds (default 60)
#   interval     - cheap-poll interval in seconds (default 1)
#   iscsi_rescan - coderef to call for iSCSI rescan (optional)
#   fc_rescan    - coderef to call for FC rescan (optional)
#
# Structure matters here, and the previous structure was the bug behind
# "device did not appear within 60s" reports on hosts where `multipath -ll`
# looked perfectly healthy a minute later (issue #13):
#
#   1. The old loop probed for the device only at the END of a body that ran
#      an iSCSI rescan (up to 10s per LOGGED_IN session), a SCSI host scan
#      (up to 10s per host + 1s settle), a full `multipathd reconfigure` (up
#      to 30s), `udevadm trigger` and `udevadm settle` (up to 10s each). On a
#      fabric with a couple of slow paths one pass can consume the entire 60s
#      budget, so the caller got exactly ONE look at the device — taken at the
#      worst possible moment, right after a host-wide reconfigure churned the
#      map table. A LUN that surfaced two seconds later was reported missing.
#   2. It never probed BEFORE rescanning, so the overwhelmingly common case
#      (the device is already there) paid the full expensive path anyway.
#   3. It called `multipathd reconfigure` on every pass, which rebuilds every
#      map on the host and can transiently hide the very map being waited for.
#
# The replacement is an escalation ladder with a cheap probe after every step
# and between steps: check first, then rescan the transport, then scan SCSI
# hosts, then nudge udev, and only reach for a host-wide reconfigure from the
# second round onward and at most once per RECONFIGURE_MIN_INTERVAL. Every
# step is deadline-aware, so the wall-clock budget is honoured instead of
# being consumed by one indivisible pass.
sub wait_for_multipath_device {
    my ($wwid, %opts) = @_;

    croak "wwid is required" unless $wwid;

    my $timeout      = $opts{timeout}  // DEVICE_WAIT_TIMEOUT;
    my $interval     = $opts{interval} // DEVICE_WAIT_INTERVAL;
    my $iscsi_rescan = $opts{iscsi_rescan};
    my $fc_rescan    = $opts{fc_rescan};
    my $deadline     = time() + $timeout;

    my $probe = sub {
        my $device = get_device_by_wwid($wwid);
        return ($device && -b $device) ? $device : undef;
    };

    # Cheapest thing first: it may already be here.
    my $device = $probe->();
    return $device if $device;

    my $round = 0;
    while (time() < $deadline) {
        $round++;

        # Step 1: transport rescan — ask the initiator to look for new LUNs.
        if ($iscsi_rescan && ref($iscsi_rescan) eq 'CODE') {
            eval { $iscsi_rescan->(); };
        }
        if ($fc_rescan && ref($fc_rescan) eq 'CODE') {
            eval { $fc_rescan->(); };
        }
        $device = $probe->();
        return $device if $device;
        last if time() >= $deadline;

        # Step 2: SCSI host scan — makes the kernel enumerate new LUNs.
        eval { rescan_scsi_hosts(delay => 1); };
        $device = $probe->();
        return $device if $device;
        last if time() >= $deadline;

        # Step 3: udev — creates the /dev/mapper and /dev/disk/by-id nodes.
        # Cheap relative to a reconfigure and usually all that is missing.
        eval { _run_cmd(['/sbin/udevadm', 'trigger', '--subsystem-match=block'],
            timeout => 10, allow_nonzero => 1, ignore_errors => 1); };
        eval { _run_cmd(['/sbin/udevadm', 'settle', '--timeout=5'],
            timeout => 10, allow_nonzero => 1, ignore_errors => 1); };
        $device = $probe->();
        return $device if $device;
        last if time() >= $deadline;

        # Step 4: host-wide reconfigure, last resort only. Skipped on the
        # first round (udev almost always suffices for a freshly mapped LUN)
        # and rate-limited process-wide so concurrent callers cannot turn it
        # into a reconfigure storm.
        if ($round >= 2) {
            multipath_reload_throttled();
            $device = $probe->();
            return $device if $device;
        }

        # Step 5: cheap polling until the next escalation round. `multipathd
        # show maps` is inexpensive, so poll it rather than sitting idle —
        # this is what turns "one look per minute" into "a look per second".
        my $next_round = time() + 5;
        while (time() < $next_round && time() < $deadline) {
            sleep($interval);
            $device = $probe->();
            return $device if $device;
        }
    }

    return undef;
}

# Human-readable snapshot of everything the host knows about a WWID, for
# inclusion in "device did not appear" errors. An operator (or an issue
# report) should be able to tell from this alone whether multipathd never saw
# the LUN, saw it under a different WWID, or built the map but udev never
# created the node — without asking for a second reproduction.
#
# Every lookup is best-effort and bounded; this runs on an already-failing
# path and must never add a new way to hang.
sub describe_wwid_state {
    my ($wwid) = @_;
    return '' unless $wwid;

    my $wwid_lc = lc($wwid);
    my @out;

    # What multipathd currently has, and whether our WWID is among it.
    my ($stdout, $stderr, $exit) = eval {
        _run_cmd([MULTIPATHD, 'show', 'maps', 'raw', 'format', '%n %w'],
            allow_nonzero => 1, ignore_errors => 1, timeout => 10);
    };
    if ($@) {
        push @out, "  multipathd: NOT RESPONDING ($@)";
        push @out, "    (this alone explains the failure: device lookup goes"
            . " through 'multipathd show maps'. Check 'systemctl status multipathd'.)";
    } else {
        my @maps;
        for my $line (split /\n/, ($stdout // '')) {
            $line =~ s/^\s+|\s+$//g;
            my ($name, $map_wwid) = split /\s+/, $line, 2;
            next unless $name && $map_wwid;
            push @maps, { name => $name, wwid => lc($map_wwid) };
        }
        my ($match) = grep { $_->{wwid} eq $wwid_lc } @maps;
        push @out, "  multipathd maps: " . scalar(@maps) . " total, "
            . scalar(grep { $_->{wwid} =~ /^3624a9370/ } @maps) . " Pure";
        if ($match) {
            my $node = "/dev/mapper/$match->{name}";
            push @out, "  map for this WWID: $match->{name} -> $node"
                . ((-b $node) ? " (block device present)"
                              : " (NODE MISSING — udev did not create it)");
        } else {
            push @out, "  map for this WWID: NONE — multipathd has not built a"
                . " map for $wwid";
            my @pure = grep { $_->{wwid} =~ /^3624a9370/ } @maps;
            if (@pure) {
                push @out, "  other Pure WWIDs multipathd does see:";
                push @out, "    $_->{wwid} ($_->{name})" for @pure[0 .. ($#pure > 4 ? 4 : $#pure)];
                push @out, "    ... and " . (scalar(@pure) - 5) . " more" if @pure > 5;
            }
        }
    }

    # udev symlinks for the underlying SCSI paths. Present here but absent
    # from multipathd means the paths arrived and multipath did not claim
    # them (commonly `find_multipaths` waiting for a second path).
    my @links;
    eval {
        local $SIG{ALRM} = sub { die "timeout\n" };
        alarm(5);
        @links = grep { lc($_) =~ /\Q$wwid_lc\E$/ }
            glob("/dev/disk/by-id/scsi-*"), glob("/dev/disk/by-id/dm-uuid-mpath-*");
        alarm(0);
    };
    alarm(0);
    push @out, "  /dev/disk/by-id links for this WWID: "
        . (@links ? join(', ', map { my $b = $_; $b =~ s|.*/||; $b } @links) : "none");

    return join("\n", @out);
}

# Remove a SCSI device from the system
# Read a SCSI disk's WWID straight from sysfs, normalised to the multipath
# form (3 + 32 hex). Returns undef if the attribute is absent or unreadable.
sub _scsi_device_wwid {
    my ($dev_name) = @_;
    my $raw = sysfs_read_with_timeout("/sys/block/$dev_name/device/wwid", 3);
    return undef unless defined $raw;
    chomp $raw;
    $raw =~ s/^\s+|\s+$//g;
    return undef unless $raw =~ s/^naa\.//i;
    return undef unless $raw =~ /^[0-9a-fA-F]{32}$/;
    return '3' . lc($raw);
}

sub remove_scsi_device {
    my ($device, %opts) = @_;

    croak "device is required" unless $device;

    my $dev_name = _untaint_device_name(basename($device));
    croak "Invalid device name" unless $dev_name;

    # Verify we are deleting the path we think we are.
    #
    # free_image() captures the multipath slave list BEFORE disconnecting the
    # volume on the array and deletes those slaves afterwards. The kernel
    # reuses /dev/sdX names as soon as they are freed, so in that window a
    # concurrent rescan (pvestatd activating another storage, another plugin)
    # can hand the same name to an unrelated LUN — and this function would
    # then delete a live path belonging to it. With multipath that is a path
    # loss rather than data loss, unless it happens to be the last path.
    #
    # If the caller tells us which WWID it expects, compare against the
    # kernel's own answer. An unreadable attribute is not treated as a
    # mismatch: older kernels and some transports do not expose it, and the
    # caller derived this name from the multipath map, so refusing there
    # would block legitimate cleanup for no gain. A name that has genuinely
    # been reused always has a readable, different WWID.
    if (my $expect = $opts{expect_wwid}) {
        my $actual = _scsi_device_wwid($dev_name);
        if (defined $actual && lc($actual) ne lc($expect)) {
            warn "remove_scsi_device: refusing to delete /dev/$dev_name — it "
               . "now reports WWID $actual but we expected $expect. The "
               . "kernel has reused this device name for a different LUN; "
               . "deleting it would remove a path belonging to other "
               . "storage.\n";
            return 0;
        }
    }

    # Untaint device path for system calls
    my $safe_device = _untaint_path($device);

    # Find the SCSI device path
    my $delete_file = BLOCK_DEVICE_PATH . "/$dev_name/device/delete";

    if (-w $delete_file) {
        # Sync and flush first (with timeout to prevent hang on unresponsive device).
        # Bare system('sync') / system('blockdev') can enter D state forever if
        # the device behind it is dead.
        eval { _run_cmd(['/bin/sync'], timeout => 10, allow_nonzero => 1, ignore_errors => 1); };
        if ($safe_device && -b $safe_device) {
            eval { _run_cmd(['/sbin/blockdev', '--flushbufs', $safe_device],
                timeout => 10, allow_nonzero => 1, ignore_errors => 1); };
        }

        sysfs_write_with_timeout($delete_file, "1\n", 10)
            or croak "Failed to write to $delete_file (timed out or error)";

        return 1;
    }

    croak "Cannot find delete file for device $device";
}

# Rescan a specific SCSI device. Use the symlink-resolving helper rather
# than basename() so a caller passing /dev/mapper/<wwid> doesn't silently
# fail (sysfs path /sys/class/block/<wwid>/device/rescan does not exist).
# Current callers always pass /dev/sdX from get_multipath_slaves, but the
# function is exported and a future caller could pass a multipath path.
sub rescan_scsi_device {
    my ($device, %opts) = @_;

    croak "device is required" unless $device;

    my $dev_name = _resolve_block_device_name($device);
    croak "Invalid device name" unless $dev_name;

    my $rescan_file = BLOCK_DEVICE_PATH . "/$dev_name/device/rescan";

    if (-w $rescan_file) {
        sysfs_write_with_timeout($rescan_file, "1\n", 10)
            or croak "Failed to write to $rescan_file (timed out or error)";
        return 1;
    }

    croak "Cannot find rescan file for device $device";
}

# Get all slave devices for a multipath device.
#
# IMPORTANT: must resolve /dev/mapper/<wwid> symlinks to dm-N before
# accessing /sys/block/. basename('/dev/mapper/3624a9370...') returns the
# wwid, but the slaves directory lives under /sys/block/dm-N/, not
# /sys/block/<wwid>/. Without symlink resolution this function silently
# returned an empty list for every multipath device, which in turn caused
# free_image to leak the underlying SCSI devices.
sub get_multipath_slaves {
    my ($mpath_device, %opts) = @_;

    croak "mpath_device is required" unless $mpath_device;

    my $dev_name = _resolve_block_device_name($mpath_device);
    return [] unless $dev_name;

    my $slaves_dir = BLOCK_DEVICE_PATH . "/$dev_name/slaves";

    return [] unless -d $slaves_dir;

    opendir(my $dh, $slaves_dir) or return [];
    my @slaves;
    for my $slave (readdir($dh)) {
        next if $slave =~ /^\./;
        my $safe_slave = _untaint_device_name($slave);
        push @slaves, "/dev/$safe_slave" if $safe_slave;
    }
    closedir($dh);

    return \@slaves;
}

# Clean up multipath and SCSI devices for a LUN
# IMPORTANT: This must be called BEFORE deleting the LUN on the storage system
sub cleanup_lun_devices {
    my ($wwid, %opts) = @_;

    croak "wwid is required" unless $wwid;

    # Get multipath device
    my $mpath = get_multipath_device($wwid);

    if ($mpath && -b $mpath) {
        # Safety: refuse to cleanup devices that are still in use
        if (is_device_in_use($mpath)) {
            croak "Cannot cleanup LUN devices: $mpath is still in use (mounted, held open, or has holders)";
        }

        # Get slave devices first (before we remove the multipath, the
        # /sys/block/.../slaves directory disappears once the map is gone).
        my $slaves = get_multipath_slaves($mpath);
        my $mpath_name = basename($mpath);
        my $safe_name = _untaint_device_name($mpath_name);
        my $safe_mpath = _untaint_device_path($mpath);

        # CRITICAL: Before any flush/sync operation, disable queue_if_no_path
        # on this specific device. Otherwise sync/blockdev/multipath -f will
        # hang forever if all paths are failed and the device has
        # queue_if_no_path enabled. Then use dmsetup message to fail any
        # already-queued I/O immediately.
        if ($safe_name) {
            eval {
                _run_cmd([MULTIPATHD, 'disablequeueing', 'map', $safe_name],
                    allow_nonzero => 1, ignore_errors => 1, timeout => 5);
            };
            eval {
                _run_cmd(['/sbin/dmsetup', 'message', $safe_name, '0', 'fail_if_no_path'],
                    allow_nonzero => 1, ignore_errors => 1, timeout => 5);
            };
        }

        # Step 1: Sync all pending writes (now safe — queueing is disabled).
        eval { _run_cmd(['/bin/sync'], timeout => 10, allow_nonzero => 1, ignore_errors => 1); };

        # Step 2: Flush device buffers.
        if ($safe_mpath) {
            eval { _run_cmd(['/sbin/blockdev', '--flushbufs', $safe_mpath],
                timeout => 10, allow_nonzero => 1, ignore_errors => 1); };
        }

        # Step 2.5: Remove kpartx partition devices BEFORE attempting to
        # remove the multipath device. If the kernel created partition dm
        # devices via kpartx (happens automatically on any LUN with a
        # GPT/MBR partition table — i.e. every VM with an OS installed),
        # those partition devices are holders of the multipath map and
        # will cause `multipathd remove map` and `multipath -f` to fail.
        if ($safe_mpath) {
            eval { _run_cmd(['/sbin/kpartx', '-d', $safe_mpath],
                allow_nonzero => 1, ignore_errors => 1, timeout => 10); };
        }

        # Step 3: Remove the multipath device via multipathd.
        if ($safe_name) {
            eval {
                _run_cmd([MULTIPATHD, 'remove', 'map', $safe_name],
                    allow_nonzero => 1, ignore_errors => 1, timeout => 10);
            };
        }

        # Step 4: Try multipath -f as fallback (with dmsetup --force fallback
        # built into multipath_flush).
        eval { multipath_flush($mpath, timeout => 10); };

        # Step 5: Brief pause to let device-mapper settle.
        sleep(1);

        # Step 6: Remove the underlying SCSI slave devices, verifying each
        # one still belongs to this WWID (the map has just been torn down, so
        # the kernel is free to reuse those names).
        for my $slave (@$slaves) {
            eval { remove_scsi_device($slave, expect_wwid => $wwid); };
        }

        # Step 7: Brief pause for cleanup to complete.
        sleep(1);
    }

    return 1;
}

# List all multipath devices belonging to Pure Storage (WWID prefix 3624a9370).
# Returns array of { name, wwid, paths_failed } where paths_failed is true if
# none of the underlying paths are 'active ready'. Used by orphan cleanup.
sub list_pure_multipath_devices {
    my (%opts) = @_;

    my ($stdout) = eval {
        _run_cmd([MULTIPATHD, 'show', 'maps', 'raw', 'format', '%n %w'],
            allow_nonzero => 1, ignore_errors => 1, timeout => 10);
    };
    return [] unless defined $stdout;

    my @devices;
    for my $line (split /\n/, $stdout) {
        $line =~ s/^\s+|\s+$//g;
        my ($name, $wwid) = split /\s+/, $line, 2;
        next unless $name && $wwid;
        # Pure Storage WWID prefix: 3624a9370
        next unless lc($wwid) =~ /^3624a9370/;
        push @devices, { name => $name, wwid => lc($wwid) };
    }

    return \@devices;
}

# Return a human-readable description of WHY a device is in use: mount
# points, holder device names + dm-names, and detected LVM VGs. Called
# by free_image when is_device_in_use blocks deletion. The description
# answers WHAT (which holders), WHY (host LVM auto-activation), and HOW
# to recover (vgchange -an + global_filter). Returns undef if the device
# is not in use (or details can't be determined).
sub get_device_usage_details {
    my ($device) = @_;
    return undef unless $device && -b $device;

    my $dev_name = _resolve_block_device_name($device);
    return undef unless $dev_name;

    my @details;

    # Check mounts
    my $mounts = sysfs_read_with_timeout('/proc/mounts', 5);
    if (defined $mounts) {
        for my $line (split /\n/, $mounts) {
            if ($line =~ /^\Q$device\E\s+(\S+)/ || $line =~ /^\/dev\/\Q$dev_name\E\s+(\S+)/) {
                push @details, "Mounted at: $1";
            }
        }
    }

    # Check holders (LVM PV, dm-crypt, dm-raid, bcache, ...)
    my $holders_dir = "/sys/block/$dev_name/holders";
    if (-d $holders_dir) {
        opendir(my $dh, $holders_dir);
        my @holders = grep { !/^\./ } readdir($dh);
        closedir($dh);

        if (@holders) {
            push @details, "[HOLDERS] Device has " . scalar(@holders) . " holder(s) in /sys/block/$dev_name/holders/:";

            my %vgs;
            for my $h (@holders) {
                my $dm_name_file = "/sys/block/$h/dm/name";
                my $dm_name = '';
                if (-r $dm_name_file) {
                    $dm_name = sysfs_read_with_timeout($dm_name_file, 3) // '';
                    chomp $dm_name;
                }
                my $label = $dm_name ? "/dev/$h (dm-name: $dm_name)" : "/dev/$h";
                push @details, "    $label";

                # Parse LVM dm-name convention: <vgname>-<lvname>
                # LVM escapes hyphens in VG names as double-hyphens.
                # Skip kpartx partition dm-names (<wwid>-part1, <wwid>p1, etc.)
                # which would be misparsed as VG "<wwid>" LV "part1".
                my $is_part = ($dm_name =~ /part\d+$/
                            || $dm_name =~ /^[0-9a-f]{20,}p?\d+$/
                            || $dm_name =~ /^sd[a-z]+\d+$/);
                if ($dm_name && !$is_part && $dm_name =~ /^(.+)-([^-]+)$/) {
                    my $vg_raw = $1;
                    $vg_raw =~ s/--/-/g;  # unescape double hyphens
                    $vgs{$vg_raw} = 1;
                }
            }

            if (%vgs) {
                my $vg_list = join(', ', sort keys %vgs);
                push @details, "";
                push @details, "  Detected LVM VG(s): $vg_list";
                push @details, "  These are likely host-level LVM auto-activation of VGs found inside the VM disk.";
                push @details, "  This happens on PVE nodes upgraded from 7/8 to 9 that are missing";
                push @details, "  the `global_filter` setting in /etc/lvm/lvm.conf.";
                push @details, "";
                push @details, "  To resolve:";
                for my $vg (sort keys %vgs) {
                    push @details, "    vgchange -an $vg";
                }
                push @details, "  Then retry the delete operation.";
                push @details, "";
                push @details, "  To prevent recurrence after reboot, add to /etc/lvm/lvm.conf:";
                push @details, '    global_filter = [ "r|/dev/mapper/360.*|", "r|/dev/dm-.*|", "a|.*|" ]';
            }
        }
    }

    # Check fuser
    my $safe_device = _untaint_device_path($device);
    if ($safe_device) {
        my ($stdout, undef, $exit) = eval {
            _run_cmd(['/bin/fuser', $safe_device],
                timeout => 5, allow_nonzero => 1, ignore_errors => 1);
        };
        if (!$@ && defined $exit && $exit == 0 && $stdout) {
            chomp $stdout;
            push @details, "Open by process(es): $stdout";
        }
    }

    return @details ? join("\n", @details) : undef;
}

# Determine whether a device is in use, and say WHY, or say that the answer
# could not be determined.
#
# Returns ($state, $reason):
#   'in-use'  - something is demonstrably using it (mount, real holder, swap,
#               open file descriptor)
#   'idle'    - every check completed and none of them found a user
#   'unknown' - at least one check could NOT be completed (sysfs read timed
#               out, fuser was killed by its watchdog, a path would not
#               resolve). NOT the same as 'idle'.
#
# The distinction matters because this is the last line of defence before
# free_image() disconnects and destroys a volume, before
# volume_snapshot_rollback() overwrites one, and before create_base()
# converts one. The previous implementation collapsed 'unknown' into "not in
# use": every internal failure fell through to `return 0`.
#
# That is backwards. For a raw Pure LUN handed to a VM there is no mount and
# no real holder — the kpartx partitions are deliberately ignored — so
# `fuser` is the ONLY positive signal that a running VM has the device open.
# A `fuser` call killed by its own 5s watchdog therefore turned "a VM is
# using this disk" into "nothing is using this disk", precisely when the node
# was unhealthy enough for that watchdog to fire. Callers must be able to
# tell "safe to destroy" apart from "I could not find out".
#
# CRITICAL (unchanged): must resolve /dev/mapper/<wwid> symlinks to dm-N
# before touching /sys/block/. basename('/dev/mapper/3624a9370...') returns
# the wwid, and /sys/block/<wwid>/holders does not exist, so the function
# once reported every multipath device as unused — free_image() would then
# destroy a Pure volume carrying an LVM VG or dm-crypt container. DATA LOSS.
sub device_usage_state {
    my ($device, %opts) = @_;

    return ('idle', 'no device path supplied') unless $device;

    # No local block device means there is nothing on THIS node that could be
    # using it. This is a genuine 'idle', not an undetermined answer.
    return ('idle', "no local block device at $device") unless -b $device;

    my $dev_name = _resolve_block_device_name($device);
    return ('unknown', "cannot resolve '$device' to a kernel block device name")
        unless $dev_name;

    # Check 1: mounted? Match both the path we were given (may be
    # /dev/mapper/<wwid>) and the resolved kernel name (dm-N) — different
    # mount(8) versions record different forms.
    my $mounts = sysfs_read_with_timeout('/proc/mounts', 5);
    return ('unknown', "/proc/mounts could not be read within 5s")
        unless defined $mounts;
    for my $line (split /\n/, $mounts) {
        if ($line =~ /^\Q$device\E\s/ || $line =~ /^\/dev\/\Q$dev_name\E\s/) {
            my (undef, $mp) = split /\s+/, $line;
            return ('in-use', "mounted at " . ($mp // 'unknown mount point'));
        }
    }

    # Check 2: holders (LVM PV, dm-crypt, dm-raid, bcache, ...).
    #
    # Bare kpartx partition holders MUST be ignored. The kernel scans every
    # block device for a partition table; any LUN carrying GPT/MBR — i.e.
    # every VM disk with an OS on it — gets partition dm devices created
    # automatically, and those appear as holders. Treating them as "in use"
    # blocks deletion of the normal case, not an edge case (see v1.1.7).
    #
    # A partition is safe to ignore only when it has no sub-holders, is not
    # mounted and is not swap. Anything else, or anything we cannot read,
    # stops us.
    my $sysblock = "/sys/block/$dev_name";
    return ('unknown', "$sysblock does not exist, cannot enumerate holders")
        unless -d $sysblock;

    my $holders_dir = "$sysblock/holders";
    if (-d $holders_dir) {
        opendir(my $dh, $holders_dir)
            or return ('unknown', "cannot read $holders_dir: $!");
        my @holders = grep { !/^\./ } readdir($dh);
        closedir($dh);

        if (@holders) {
            my $swaps = sysfs_read_with_timeout('/proc/swaps', 5);
            return ('unknown', "/proc/swaps could not be read within 5s")
                unless defined $swaps;

            for my $h (@holders) {
                my $dm_name = '';
                my $dm_name_file = "/sys/block/$h/dm/name";
                if (-e $dm_name_file) {
                    $dm_name = sysfs_read_with_timeout($dm_name_file, 3);
                    return ('unknown', "cannot read dm name of holder /dev/$h")
                        unless defined $dm_name;
                    chomp $dm_name;
                }

                # kpartx partition name forms: <wwid>-part1, <wwid>p1,
                # <wwid>1, mpath0-part1, sdf1.
                my $is_partition = (
                    $dm_name =~ /part\d+$/
                    || $dm_name =~ /^[0-9a-f]{20,}p?\d+$/
                    || $dm_name =~ /^sd[a-z]+\d+$/
                    || (-e "/sys/block/$h/partition")
                );

                if (!$is_partition) {
                    my $label = $dm_name ? "/dev/$h (dm-name: $dm_name)" : "/dev/$h";
                    return ('in-use', "held by $label (LVM, dm-crypt or similar)");
                }

                # It IS a partition. Does anything sit on top of it?
                my $sub_holders_dir = "/sys/block/$h/holders";
                if (-d $sub_holders_dir) {
                    opendir(my $sdh, $sub_holders_dir)
                        or return ('unknown', "cannot read $sub_holders_dir: $!");
                    my @sub = grep { !/^\./ } readdir($sdh);
                    closedir($sdh);
                    if (@sub) {
                        return ('in-use',
                            "partition /dev/$h has its own holder(s): " . join(', ', @sub));
                    }
                }

                my $part_dev    = "/dev/$h";
                my $part_mapper = $dm_name ? "/dev/mapper/$dm_name" : '';
                if ($mounts =~ /^\Q$part_dev\E\s/m
                    || ($part_mapper && $mounts =~ /^\Q$part_mapper\E\s/m)) {
                    return ('in-use', "partition $part_dev is mounted");
                }
                if ($swaps =~ /^\Q$part_dev\E\s/m
                    || ($part_mapper && $swaps =~ /^\Q$part_mapper\E\s/m)) {
                    return ('in-use', "partition $part_dev is active swap");
                }
            }
            # All holders are bare kpartx partitions: not mounted, not swap,
            # nothing stacked on them. Safe to ignore.
        }
    }

    # Check 3: open by any process. For a raw LUN attached to a running VM
    # this is the only signal that will fire, so a failure here must NOT be
    # read as "idle". `fuser` comes from psmisc, which this package Depends
    # on, so a failure means it timed out or was killed — not that it is
    # missing.
    my $safe_device = _untaint_device_path($device);
    return ('unknown', "device path '$device' failed untainting")
        unless $safe_device;

    my ($stdout, $exit);
    my $ran = eval {
        (my $out, undef, my $rc) = _run_cmd(['/bin/fuser', $safe_device],
            timeout => 5, allow_nonzero => 1, ignore_errors => 1);
        ($stdout, $exit) = ($out, $rc);
        1;
    };
    if (!$ran) {
        my $err = $@ || 'unknown error';
        $err =~ s/\s+$//;
        return ('unknown', "the 'fuser' open-file-descriptor check did not "
            . "complete ($err); a running VM holding this device open would "
            . "look idle");
    }
    if (defined $exit && $exit == 0) {
        my $pids = $stdout // '';
        $pids =~ s/\s+/ /g;
        $pids =~ s/^\s+|\s+$//g;
        return ('in-use', "open by process(es): " . ($pids || 'yes'));
    }

    return ('idle', 'not mounted, no real holders, not swap, not open by any process');
}

# Boolean wrapper. FAILS CLOSED: an undetermined answer counts as in use.
# Callers that need to tell the two apart (and produce a better error) should
# call device_usage_state() directly.
sub is_device_in_use {
    my ($device, %opts) = @_;

    my ($state) = device_usage_state($device, %opts);
    return $state eq 'idle' ? 0 : 1;
}

1;

__END__

=head1 NAME

PVE::Storage::Custom::PureStorage::Multipath - Multipath and SCSI management utilities

=head1 SYNOPSIS

    use PVE::Storage::Custom::PureStorage::Multipath qw(
        rescan_scsi_hosts
        get_multipath_device
        wait_for_multipath_device
    );

    # Rescan for new devices
    rescan_scsi_hosts();

    # Get multipath device by WWID
    my $device = get_multipath_device('3624a9370abc123def456...');

    # Wait for device to appear
    my $device = wait_for_multipath_device($wwid, timeout => 60);

=head1 DESCRIPTION

This module provides multipath and SCSI device management utilities for
the Pure Storage storage plugin.

=cut
