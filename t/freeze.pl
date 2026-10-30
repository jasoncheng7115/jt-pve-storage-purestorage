#!/usr/bin/perl
# Covers: A40   (see AUDIT_REGISTER.md)
# What quiescing actually happens when a RUNNING container's volume is
# snapshotted on Pure?
#
# Two independent mechanisms could flush the host page cache before the array
# takes its point-in-time copy:
#
#   1. PVE's own fsfreeze hook. AbstractConfig::snapshot_create() freezes the
#      guest, then calls volume_snapshot(), then thaws. For LXC the guest
#      freeze is a cgroup freeze of the PROCESSES; the FILESYSTEM is only
#      frozen for mountpoints whose storage returns 1 from
#      volume_snapshot_needs_fsfreeze(). Cgroup-freezing the processes stops
#      new writes but does not push dirty pages to the array.
#
#   2. The plugin's own sync + blockdev --flushbufs inside volume_snapshot().
#
# This checks which of the two runs for a device that is in use, which is
# exactly what a running container's rootfs looks like.
use strict;
use File::Temp ();
use warnings;

use FindBin; my $LIB = "$FindBin::Bin/../lib";
my ($pass, $fail) = (0, 0);

sub check {
    my ($desc, $got, $want) = @_;
    my $ok = (defined $got && defined $want && "$got" eq "$want");
    $ok ? $pass++ : $fail++;
    printf "  %-4s %-52s got=%-14s want=%s\n", $ok ? 'ok' : 'FAIL', $desc,
        defined $got ? $got : 'undef', $want;
}

# --- 1. the fsfreeze hook -------------------------------------------------
{
    require PVE::Storage::Plugin;
    unshift @INC, $LIB;
    require PVE::Storage::Custom::PureStoragePlugin;
    my $c = 'PVE::Storage::Custom::PureStoragePlugin';

    check('外掛自己實作 volume_snapshot_needs_fsfreeze',
        $c->can('volume_snapshot_needs_fsfreeze')
            && *{PVE::Storage::Custom::PureStoragePlugin::volume_snapshot_needs_fsfreeze}{CODE}
            ? 'yes' : 'no (繼承 base)', 'yes');

    check('執行中容器的檔案系統會被 fsfreeze',
        $c->volume_snapshot_needs_fsfreeze() ? 'yes' : 'no', 'yes');

    # For comparison: the two plugins that face the same problem.
    for my $p (['RBD (Ceph)', '/usr/share/perl5/PVE/Storage/RBDPlugin.pm'],
               ['DellPowerFlex (姊妹專案)',
                '/usr/share/perl5/PVE/Storage/Custom/DellPowerFlexPlugin.pm']) {
        my ($name, $file) = @$p;
        next unless -f $file;
        my $src = do { open(my $fh, '<', $file) or next; local $/; <$fh> };
        my ($v) = $src =~ /sub volume_snapshot_needs_fsfreeze.*?return\s+(\d+)/s;
        printf "       (對照 %-24s 回傳 %s)\n", $name, defined $v ? $v : 'n/a';
    }
}

# --- 2. the plugin's own flush -------------------------------------------
# Drive volume_snapshot() with everything stubbed except the flush decision,
# and record whether sync / blockdev --flushbufs were issued.
{
    my $probe = <<'PERL';
use strict; use warnings;
use FindBin; use lib "$FindBin::Bin/../lib";

my @ran;
require PVE::Storage::Custom::PureStorage::Multipath;
{
    no warnings 'redefine';
    # A device that exists and is IN USE -- a running container's rootfs.
    *PVE::Storage::Custom::PureStorage::Multipath::get_device_by_wwid = sub { '/dev/loop0' };
    *PVE::Storage::Custom::PureStorage::Multipath::is_device_in_use   = sub { $ENV{IN_USE} };
}

require PVE::Storage::Custom::PureStoragePlugin;
{
    no warnings 'redefine';
    *PVE::Storage::Custom::PureStoragePlugin::_get_api = sub {
        return bless {}, 'FakeAPI';
    };
    *PVE::Storage::Custom::PureStoragePlugin::_get_full_volname = sub { $_[1] };
    *PVE::Storage::Custom::PureStoragePlugin::pve_volname_to_pure = sub { 'v' };
    *PVE::Storage::Custom::PureStoragePlugin::encode_snapshot_name = sub { 'pve-snap-s1' };
    *PVE::Storage::Custom::PureStoragePlugin::get_device_by_wwid = sub { '/dev/loop0' };
    *PVE::Storage::Custom::PureStoragePlugin::is_device_in_use   = sub { $ENV{IN_USE} };
}
# PVE::Tools is only loaded once the plugin is required, so the stub has to
# be installed AFTER that or the real module overwrites it.
require PVE::Tools;
{
    no warnings 'redefine';
    *PVE::Tools::run_command = sub { my ($cmd) = @_; push @ran, join(' ', @$cmd); return 0; };
}

{
    package FakeAPI;
    sub volume_get           { return { name => 'v' } }
    sub snapshot_get         { return undef }
    sub volume_get_wwid      { return '3624a9370deadbeef' }
    sub snapshot_create      { return 1 }
    sub volume_list          { return [] }
    our $AUTOLOAD;
    sub AUTOLOAD             { return undef }
    sub DESTROY              {}
}

eval {
    PVE::Storage::Custom::PureStoragePlugin->volume_snapshot(
        { 'pure-portal' => 'x' }, 'store', 'vm-100-disk-0', 's1');
};
print join("\n", grep { /sync|flushbufs/ } @ran), "\n";
PERL
    my (undef, $tmp) = File::Temp::tempfile('.freeze-probe-XXXXXX', SUFFIX => '.pl', TMPDIR => 1);
    open(my $fh, '>', $tmp) or die $!;
    print $fh $probe;
    close($fh);

    for my $case ([1, '使用中（執行中的容器 rootfs）'], [0, '閒置（已停機的 guest）']) {
        my ($in_use, $desc) = @$case;
        my $out = `IN_USE=$in_use perl $tmp 2>&1`;
        my $flushed = ($out =~ /flushbufs/) ? 'sync+flush' : '沒有任何 flush';
        check("volume_snapshot 在裝置$desc", $flushed,
            $in_use ? 'sync+flush' : 'sync+flush');
    }
    unlink($tmp);
}

printf "\n%d passed, %d failed\n", $pass, $fail;
exit($fail ? 1 : 0);
