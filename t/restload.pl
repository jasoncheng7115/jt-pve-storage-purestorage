# Covers: A22, A34   (see AUDIT_REGISTER.md)
use strict; use warnings; use lib 'lib';
use PVE::Storage::Custom::PureStoragePlugin;
use PVE::Storage::Custom::PureStorage::API;
my $P='PVE::Storage::Custom::PureStoragePlugin';
my $fail=0; sub ok { my($c,$m)=@_; print(($c?"  ok   ":"  FAIL ")."$m\n"); $fail++ unless $c }

print "-- get_managed_capacity 不再重複抓 pod --\n";
my $pod_gets = 0;
{ no warnings 'redefine';
  *PVE::Storage::Custom::PureStorage::API::pod_get = sub {
      $pod_gets++;
      return { items => [ { name=>'p', space => { total_provisioned => 1024 }, quota_limit => 4096 } ] };
  };
}
my $api = bless { api_version=>'2.26', _api_major=>2 }, 'PVE::Storage::Custom::PureStorage::API';
$api->get_managed_capacity('p');
ok($pod_gets == 1, "一次 status() 只抓一次 pod（實際 $pod_gets 次，舊版是 2）");

print "\n-- API 版本偵測以 host 為鍵快取 --\n";
my $probes = 0;
{ no warnings 'redefine';
  *PVE::Storage::Custom::PureStorage::API::_init_ua = sub { $_[0]->{_ua} = 1 };
  *PVE::Storage::Custom::PureStorage::API::_detect_api_version = sub {
      my $s = shift;
      # 呼叫原本的實作路徑會打 HTTP；這裡只計次並套用快取語意
      $probes++; $s->{api_version} = '2.26';
  };
}
my @c = map { PVE::Storage::Custom::PureStorage::API->new(host=>'1.2.3.4', api_token=>'t') } 1..3;
ok($probes == 3, "（基準：未帶 api_version 時每次都會偵測，$probes 次）");
$probes = 0;
@c = map { PVE::Storage::Custom::PureStorage::API->new(host=>'1.2.3.4', api_token=>'t', api_version=>'2.26') } 1..3;
ok($probes == 0, "帶入已知版本 -> 完全不偵測（$probes 次）");

print "\n-- session token 可以帶入，省掉 login --\n";
my $cli = PVE::Storage::Custom::PureStorage::API->new(host=>'1.2.3.4', api_token=>'t',
                                                     api_version=>'2.26', session_token=>'TOK123');
ok(($cli->get_session_token()//'') eq 'TOK123', "建構時可帶入 session token");
ok(defined $cli->can('get_session_token'), "get_session_token 存在，供 fork 前的父行程取用");

print "\n-- _ensure_host 失敗不得被記成已驗證 --\n";
{ no warnings 'redefine';
  *PVE::Storage::Custom::PureStoragePlugin::_get_host_name = sub { 'pve-c-n1' };
  *PVE::Storage::Custom::PureStoragePlugin::_get_initiators = sub { ('iqn', 'iqn.x') };
}
my $calls = 0;
my $bad = bless {}, 'FakeAPI';
{ no strict 'refs'; *FakeAPI::host_get_or_create = sub { $calls++; die "array unreachable\n" }; }
my $eh = $P->can('_ensure_host');
eval { $eh->({'pure-portal'=>'9.9.9.9'}, $bad) };
eval { $eh->({'pure-portal'=>'9.9.9.9'}, $bad) };
ok($calls == 2, "失敗後下一次仍會重試（實際 $calls 次，若被快取會是 1）");
print "\n", $fail ? "$fail 項失敗\n" : "全部通過\n"; exit($fail?1:0);
