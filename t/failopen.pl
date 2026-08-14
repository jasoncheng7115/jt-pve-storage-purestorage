# Covers: A2   (see AUDIT_REGISTER.md)
use strict; use warnings; use lib 'lib';
use PVE::Storage::Custom::PureStorage::Multipath qw(is_device_in_use);
my $blk = (grep { -b $_ } qw(/dev/dm-6 /dev/sda /dev/sdb))[0] or die "no block dev\n";

print "情境模擬：is_device_in_use() 內部每個查詢都失敗時的回答\n";
print "（這個函式是 free_image / rollback / create_base 唯一的資料保護關卡）\n\n";

# 1. /proc/mounts 讀取逾時 + fuser 逾時 + holders 目錄讀不到
{
    no warnings 'redefine';
    *PVE::Storage::Custom::PureStorage::Multipath::sysfs_read_with_timeout = sub { undef };
    *PVE::Storage::Custom::PureStorage::Multipath::_run_cmd = sub { die "timeout\n" };
}
my $r = is_device_in_use($blk);
printf "  /proc/mounts 逾時 + fuser 逾時  -> is_device_in_use = %d  (%s)\n",
    $r, $r ? "擋下" : ">>> 放行，允許刪除 <<<";

# 2. 只有 fuser 逾時（掛載檢查正常但沒掛載）
{
    no warnings 'redefine';
    *PVE::Storage::Custom::PureStorage::Multipath::sysfs_read_with_timeout = sub { "" };
    *PVE::Storage::Custom::PureStorage::Multipath::_run_cmd = sub { die "Command timed out\n" };
}
$r = is_device_in_use($blk);
printf "  僅 fuser 逾時                   -> is_device_in_use = %d  (%s)\n",
    $r, $r ? "擋下" : ">>> 放行，允許刪除 <<<";

# 3. 裝置路徑無法解析（symlink 壞掉）
{
    no warnings 'redefine';
    *PVE::Storage::Custom::PureStorage::Multipath::_resolve_block_device_name = sub { undef };
}
$r = is_device_in_use($blk);
printf "  裝置名稱無法解析                -> is_device_in_use = %d  (%s)\n",
    $r, $r ? "擋下" : ">>> 放行，允許刪除 <<<";
