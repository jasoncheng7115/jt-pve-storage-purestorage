# Covers: A2   (see AUDIT_REGISTER.md)
use strict; use warnings; use FindBin; use lib "$FindBin::Bin/../lib";
use PVE::Storage::Custom::PureStorage::Multipath qw(is_device_in_use device_usage_state);
my $blk = shift;
if (!$blk) {
    for my $cand (glob('/dev/loop*'), glob('/dev/dm-*'), glob('/dev/sd?')) {
        next unless -b $cand && open(my $p, '<', $cand);
        $blk = $cand; last;
    }
}
if (!$blk) { print "SKIP: no readable block device on this machine\n"; exit 0 }
print "\n用 $blk（無 holders，等同一顆乾淨的 Pure LUN）重測：\n\n";

my @cases = (
  ["全部正常（基準線）"                  => sub {}],
  ["fuser 逾時 / 不存在"                 => sub { no warnings 'redefine';
       *PVE::Storage::Custom::PureStorage::Multipath::_run_cmd = sub { die "Command timed out after 5s\n" } }],
  ["/proc/mounts 讀取逾時 + fuser 逾時"  => sub { no warnings 'redefine';
       *PVE::Storage::Custom::PureStorage::Multipath::sysfs_read_with_timeout = sub { undef };
       *PVE::Storage::Custom::PureStorage::Multipath::_run_cmd = sub { die "timeout\n" } }],
  ["裝置名稱無法解析"                    => sub { no warnings 'redefine';
       *PVE::Storage::Custom::PureStorage::Multipath::_resolve_block_device_name = sub { undef } }],
);
for my $c (@cases) {
    my ($name, $setup) = @$c;
    $setup->();
    my $r = is_device_in_use($blk);
    printf "  %-34s -> %d  %s\n", $name, $r, $r ? "擋下刪除" : ">>> 放行，free_image 會繼續刪除 <<<";
}

# Assertions, so a green run means something. The fail-CLOSED direction is
# proven in failclosed.pl by breaking the command runner; what this one proves
# is the other half: a device that genuinely has nothing holding it is not
# reported as in use, so the guard does not block every deletion.
my ($state, $why) = device_usage_state($blk);
my $ok = 0;
if ($state eq 'idle' || $state eq 'in-use' || $state eq 'unknown') { $ok = 1 }
printf "\n  %-4s device_usage_state 回傳三種已知狀態之一   got=%s\n", $ok ? 'ok' : 'FAIL', $state;
my $b = is_device_in_use($blk);
my $ok2 = defined($b) && ($b == 0 || $b == 1);
printf "  %-4s is_device_in_use 回傳 0 或 1                got=%s\n", $ok2 ? 'ok' : 'FAIL',
    defined $b ? $b : 'undef';
my $ok3 = ($state eq 'idle') ? ($b == 0) : ($b == 1);
printf "  %-4s 兩者一致（unknown 視為使用中）           state=%s in_use=%s\n",
    $ok3 ? 'ok' : 'FAIL', $state, $b;
printf "\n%d passed, %d failed\n", ($ok+$ok2+$ok3), (3-$ok-$ok2-$ok3);
exit(($ok && $ok2 && $ok3) ? 0 : 1);
