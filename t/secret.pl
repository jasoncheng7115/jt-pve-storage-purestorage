# Covers: O1   (see AUDIT_REGISTER.md)
use strict; use warnings; use lib 'lib';
use File::Temp qw(tempdir);
use PVE::Storage::Custom::PureStoragePlugin;
my $P='PVE::Storage::Custom::PureStoragePlugin';
my $fail=0; sub ok { my($c,$m)=@_; print(($c?"  ok   ":"  FAIL ")."$m\n"); $fail++ unless $c }

# 把機密目錄導向暫存區，不碰真實 /etc/pve
my $dir = tempdir(CLEANUP=>1);
{ no warnings 'redefine';
  *PVE::Storage::Custom::PureStoragePlugin::_secret_file = sub {
      my ($sid,$kind)=@_; return "$dir/$sid.$kind" };
}
my $set = $P->can('_set_secret'); my $get = $P->can('_get_secret');
my $del = $P->can('_delete_secret'); my $res = $P->can('_resolve_credentials');

print "-- 檔案讀寫與權限 --\n";
$set->('st1','pure-token','TOKEN-A');
ok(($get->('st1','pure-token')//'') eq 'TOKEN-A', "寫入後讀得回來");
my $mode = sprintf "%04o", (stat("$dir/st1.pure-token"))[2] & 07777;
ok($mode eq '0600', "檔案權限 0600（實際 $mode）");
$del->('st1','pure-token');
ok(!defined $get->('st1','pure-token'), "刪除後讀不到");

print "\n-- 憑證解析優先序（遷移安全性的核心）--\n";
my $legacy = { 'pure-api-token' => 'IN-CONFIG', 'pure-password' => 'PW-CONFIG' };
my %c = $res->($legacy, 'st1');
ok($c{api_token} eq 'IN-CONFIG', "舊安裝：無檔案 -> 沿用 storage.cfg 的值");
$set->('st1','pure-token','FROM-FILE');
%c = $res->($legacy, 'st1');
ok($c{api_token} eq 'FROM-FILE', "有檔案 -> 檔案優先");
%c = $res->({}, 'st1');
ok($c{api_token} eq 'FROM-FILE', "設定檔沒有值 -> 仍讀得到檔案");
%c = $res->({}, 'st-none');
ok(!defined $c{api_token}, "都沒有 -> undef（由 _get_api 給出明確錯誤）");
$del->('st1','pure-token');

print "\n-- on_add_hook / on_update_hook 的三態 --\n";
$P->on_add_hook('st2', {}, 'pure-api-token' => 'ADDED');
ok(($get->('st2','pure-token')//'') eq 'ADDED', "add 帶 token -> 寫入");
$P->on_add_hook('st2', {});
ok(!defined $get->('st2','pure-token'), "add 未帶 token -> 清掉同名殘留");

$set->('st3','pure-token','ORIGINAL');
$P->on_update_hook('st3', {}, 'pure-portal' => '1.2.3.4');   # 未觸碰 token
ok(($get->('st3','pure-token')//'') eq 'ORIGINAL', "update 未提及 token -> 不動它（關鍵！）");
$P->on_update_hook('st3', {}, 'pure-api-token' => 'ROTATED');
ok(($get->('st3','pure-token')//'') eq 'ROTATED', "update 帶新值 -> 覆寫");
$P->on_update_hook('st3', {}, 'pure-api-token' => undef);    # --delete
ok(!defined $get->('st3','pure-token'), "update 帶 undef（--delete）-> 刪除");

$set->('st4','pure-token','X'); $set->('st4','pure-pw','Y');
$P->on_delete_hook('st4', {});
ok(!defined $get->('st4','pure-token') && !defined $get->('st4','pure-pw'), "delete hook 清掉兩個機密");

print "\n-- on_update_hook_full：一步完成遷移 --\n";
{
  # 模擬既有安裝：token 在 storage.cfg，沒有機密檔
  my $live = { 'pure-portal' => '1.2.3.4', 'pure-api-token' => 'LEGACY-CLEARTEXT' };
  $P->on_update_hook_full('st5', $live, {}, undef, { 'pure-api-token' => 'NEW-TOKEN' });
  ok(($get->('st5','pure-token')//'') eq 'NEW-TOKEN', "新值寫進機密檔");
  ok(!exists $live->{'pure-api-token'}, "storage.cfg 裡的明文舊值被移除（一步完成遷移）");
  ok($live->{'pure-portal'} eq '1.2.3.4', "其他設定不受影響");
}
{
  # 未觸碰 token 的更新，絕不能動到任何一邊
  $set->('st6','pure-token','KEEP');
  my $live = { 'pure-portal' => '9.9.9.9', 'pure-api-token' => 'STILL-HERE' };
  $P->on_update_hook_full('st6', $live, {}, undef, {});
  ok(($get->('st6','pure-token')//'') eq 'KEEP', "未提及 -> 機密檔不動");
  ok(($live->{'pure-api-token'}//'') eq 'STILL-HERE', "未提及 -> 設定檔值不動");
}
{
  # 明確刪除：兩邊都清掉，且不會留下讀不到憑證的半殘狀態
  $set->('st7','pure-token','X');
  my $live = { 'pure-api-token' => 'Y' };
  $P->on_update_hook_full('st7', $live, {}, ['pure-api-token'], { 'pure-api-token' => undef });
  ok(!defined $get->('st7','pure-token'), "--delete -> 機密檔刪除");
  ok(!exists $live->{'pure-api-token'}, "--delete -> 設定檔值也刪除");
}

print "\n-- plugindata 宣告 --\n";
my $pd = $P->plugindata();
ok($pd->{'sensitive-properties'}{'pure-api-token'} && $pd->{'sensitive-properties'}{'pure-password'},
   "plugindata 宣告了兩個機密欄位");
print "\n", $fail ? "$fail 項失敗\n" : "全部通過\n"; exit($fail?1:0);
