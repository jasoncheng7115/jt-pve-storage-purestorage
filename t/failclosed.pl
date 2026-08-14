# Covers: A2   (see AUDIT_REGISTER.md)
use strict; use warnings; use FindBin; use lib "$FindBin::Bin/../lib";
use PVE::Storage::Custom::PureStorage::Multipath qw(is_device_in_use device_usage_state);
# A real block device, held open, is the whole point: for a raw LUN handed to
# a running guest there is no mount and no holder, so an open file descriptor
# is the only positive signal is_device_in_use() has. Any block device will do
# to prove the guard's shape; take one that exists here rather than requiring
# the caller to name it, and say so plainly if the machine has none.
my $blk = shift;
if (!$blk) {
    for my $cand (glob('/dev/loop*'), glob('/dev/dm-*'), glob('/dev/sd?')) {
        next unless -b $cand;
        next unless open(my $probe, '<', $cand);
        close($probe);
        $blk = $cand;
        last;
    }
}
if (!$blk) {
    print "SKIP: no readable block device on this machine to hold open\n";
    exit 0;
}
open(my $fh, '<', $blk) or die "cannot open $blk: $!";
print "已開啟 $blk（模擬 qemu 持有裝置）\n\n";
my $fail = 0;
sub t {
    my ($name, $setup, $want) = @_;
    $setup->();
    my ($state, $why) = device_usage_state($blk);
    my $b = is_device_in_use($blk);
    my $ok = ($state eq $want);
    $fail++ unless $ok;
    printf "  %-32s -> %-8s (bool=%d) %s\n     理由: %s\n", $name, $state, $b,
        ($ok ? "OK" : "FAIL 期望 $want"), $why;
}
t("基準線：一切正常", sub {}, 'in-use');
t("fuser 逾時", sub { no warnings 'redefine';
    *PVE::Storage::Custom::PureStorage::Multipath::_run_cmd = sub { die "Command timed out after 5s\n" } }, 'unknown');
t("/proc/mounts 逾時", sub { no warnings 'redefine';
    *PVE::Storage::Custom::PureStorage::Multipath::sysfs_read_with_timeout = sub { undef } }, 'unknown');
t("裝置名稱無法解析", sub { no warnings 'redefine';
    *PVE::Storage::Custom::PureStorage::Multipath::_resolve_block_device_name = sub { undef } }, 'unknown');
close($fh);
print "\n", $fail ? "$fail 項失敗\n" : "全部符合預期：查不出來一律當成使用中\n";
exit($fail?1:0);
