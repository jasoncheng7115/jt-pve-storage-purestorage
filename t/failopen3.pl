# Covers: A2   (see AUDIT_REGISTER.md)
use strict; use warnings; use FindBin; use lib "$FindBin::Bin/../lib";
use PVE::Storage::Custom::PureStorage::Multipath qw(is_device_in_use);
my $blk = shift;
if (!$blk) {
    for my $cand (glob('/dev/loop*'), glob('/dev/dm-*'), glob('/dev/sd?')) {
        next unless -b $cand && open(my $p, '<', $cand);
        $blk = $cand; last;
    }
}
if (!$blk) { print "SKIP: no readable block device on this machine\n"; exit 0 }

# 模擬「執行中的 VM」：一個行程持有該區塊裝置的開啟中檔案描述子。
# 對一顆給 VM 用的 raw Pure LUN 來說，這正是唯一的「使用中」訊號：
# 沒有掛載點，holders 只有 kpartx 分割（程式碼刻意忽略）。
open(my $fh, '<', $blk) or die "cannot open $blk: $!";
print "已開啟 $blk（模擬 qemu 持有該裝置）\n\n";

my $base = is_device_in_use($blk);
printf "  基準線：fuser 正常                -> %d  %s\n", $base,
    $base ? "擋下刪除（正確）" : "放行";

{ no warnings 'redefine';
  *PVE::Storage::Custom::PureStorage::Multipath::_run_cmd =
      sub { die "Command timed out after 5s: /bin/fuser\n" }; }
my $broken = is_device_in_use($blk);
printf "  fuser 逾時（系統負載高／裝置卡住）-> %d  %s\n", $broken,
    $broken ? "擋下刪除" : ">>> 放行：free_image 會斷線並刪除一顆使用中的 Volume <<<";

close($fh);
print "\n結論：", ($base == 1 && $broken == 0)
    ? "安全關卡在自己失效時是「放行」而不是「擋下」。\n"
    : "本機環境無法重現（fuser 行為不同）。\n";
