# Covers: A37   (see AUDIT_REGISTER.md)
use strict; use warnings; use lib 'lib';
use File::Temp qw(tempdir);
use PVE::Storage::Custom::PureStoragePlugin;
my $P='PVE::Storage::Custom::PureStoragePlugin';
my $fail=0; sub ok { my($c,$m)=@_; print(($c?"  ok   ":"  FAIL ")."$m\n"); $fail++ unless $c }

my $dir = tempdir(CLEANUP=>1);
{ no warnings 'redefine';
  *PVE::Storage::Custom::PureStoragePlugin::_secret_file =
      sub { my ($s,$k)=@_; "$dir/$s.$k" }; }
my $res = $P->can('_resolve_credentials');

print "== 情境 A：純粹 dpkg -i 升級，完全沒動 storage 設定 ==\n";
# 升級前的樣子：token 在 storage.cfg，沒有機密檔
my $legacy = { 'pure-portal'=>'10.0.0.1', 'pure-api-token'=>'LEGACY-TOKEN' };
ok(! -e "$dir/st1.pure-token", "升級後機密檔不存在（套件升級不會觸發任何 hook）");
my %c = $res->($legacy, 'st1');
ok(($c{api_token}//'') eq 'LEGACY-TOKEN', "憑證仍從 storage.cfg 讀到 -> 連得上");

print "\n== 情境 B：升級後做了「不相關」的設定變更 ==\n";
# 例如 pvesm set st1 --pure-device-timeout 90
# PVE 抽出的 $sensitive 完全不含 token
my $live = { 'pure-portal'=>'10.0.0.1', 'pure-api-token'=>'LEGACY-TOKEN' };
$P->on_update_hook_full('st1', $live, { 'pure-device-timeout'=>90 }, undef, {});
ok(($live->{'pure-api-token'}//'') eq 'LEGACY-TOKEN', "storage.cfg 的 token 沒被動到");
ok(! -e "$dir/st1.pure-token", "也沒有誤寫機密檔");
%c = $res->($live, 'st1');
ok(($c{api_token}//'') eq 'LEGACY-TOKEN', "仍然連得上");

print "\n== 情境 C：帳號密碼模式（不是 token）==\n";
my $userpass = { 'pure-portal'=>'10.0.0.1', 'pure-username'=>'pureuser', 'pure-password'=>'LEGACY-PW' };
%c = $res->($userpass, 'st2');
ok(($c{username}//'') eq 'pureuser' && ($c{password}//'') eq 'LEGACY-PW', "帳密同樣從 storage.cfg 回退讀取");

print "\n== 情境 D：執行遷移指令之後 ==\n";
my $mig = { 'pure-portal'=>'10.0.0.1', 'pure-api-token'=>'LEGACY-TOKEN' };
$P->on_update_hook_full('st1', $mig, {}, undef, { 'pure-api-token'=>'LEGACY-TOKEN' });
ok(-e "$dir/st1.pure-token", "機密檔已建立");
ok(!exists $mig->{'pure-api-token'}, "storage.cfg 的明文行已移除");
%c = $res->($mig, 'st1');
ok(($c{api_token}//'') eq 'LEGACY-TOKEN', "遷移後仍連得上");

print "\n== 情境 E：混合版本叢集（舊版節點讀不到機密檔）==\n";
# 模擬 1.1.24 的 _get_api：只看 $scfg，沒有檔案 fallback
my $old_behaviour = sub { my ($scfg)=@_; return $scfg->{'pure-api-token'} };
ok(!defined $old_behaviour->($mig), ">>> 遷移後，舊版節點從 storage.cfg 讀到 undef <<<");
ok(defined $old_behaviour->($legacy), "遷移前，舊版節點讀得到（所以順序很重要）");

print "\n", $fail ? "$fail 項失敗\n" : "全部符合預期\n"; exit($fail?1:0);
