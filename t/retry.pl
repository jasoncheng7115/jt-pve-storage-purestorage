# Covers: A35   (see AUDIT_REGISTER.md)
use strict; use warnings; use lib 'lib';
use PVE::Storage::Custom::PureStorage::API;
my $A='PVE::Storage::Custom::PureStorage::API';
my $fail=0; sub ok { my($c,$m)=@_; print(($c?"  ok   ":"  FAIL ")."$m\n"); $fail++ unless $c }

my $api = bless { api_version=>'2.26', _api_major=>2, retry_count=>3 }, $A;
my @attempts;

print "-- no_retry：非冪等操作只送一次 --\n";
{ no warnings 'redefine';
  *PVE::Storage::Custom::PureStorage::API::_request = sub {
      my ($s,$m,$e,$d,%o)=@_;
      push @attempts, { method=>$m, no_retry=>$o{no_retry}?1:0 };
      die "HTTP 500: read timeout\n";
  };
  # volume_get 讓「查證」路徑可控
  *PVE::Storage::Custom::PureStorage::API::volume_get = sub { my ($s,$n)=@_; return $s->{_exists}{$n} };
}

# 情境 1：rename 真的失敗（新舊名稱都還是舊的）
@attempts=(); $api->{_exists} = { 'A' => {name=>'A'} };
eval { $api->volume_rename('A','A-pve-tomb-1-2') };
ok($@ =~ /read timeout/, "真失敗 -> 錯誤照樣往上拋");
ok(@attempts == 1 && $attempts[0]{no_retry}, "只送一次，且帶 no_retry（實際 ".scalar(@attempts)." 次）");

# 情境 2：陣列其實做了，但回應遺失
@attempts=(); $api->{_exists} = { 'A-pve-tomb-1-2' => {name=>'A-pve-tomb-1-2'} };
my $r = eval { $api->volume_rename('A','A-pve-tomb-1-2') };
ok(!$@ && $r, "回應遺失但陣列已改名 -> 查證後視為成功（不再誤判失敗）");

# 情境 3：兩者都在（不可能，但不能猜）
@attempts=(); $api->{_exists} = { 'A'=>{}, 'A-pve-tomb-1-2'=>{} };
eval { $api->volume_rename('A','A-pve-tomb-1-2') };
ok($@ =~ /read timeout/, "狀態不明確 -> 不猜，照樣拋錯");

print "\n-- 對照：冪等操作仍然會重試 --\n";
{ no warnings 'redefine';
  *PVE::Storage::Custom::PureStorage::API::_request = sub {
      my ($s,$m,$e,$d,%o)=@_; push @attempts, { method=>$m, no_retry=>$o{no_retry}?1:0 }; return {};
  };
}
@attempts=(); $api->volume_resize('A', 100);
ok(@attempts==1 && !$attempts[0]{no_retry}, "volume_resize 未設 no_retry（冪等，保留重試韌性）");

print "\n-- _request 真的會因 no_retry 停止重試 --\n";
{
  my $real = \&PVE::Storage::Custom::PureStorage::API::_request;
  # 直接檢查原始碼語意
  my $src = do { local(@ARGV,$/)=('lib/PVE/Storage/Custom/PureStorage/API.pm'); <> };
  ok($src =~ /my \$retry_count = \$opts\{no_retry\} \? 1 : \$self->\{retry_count\};/,
     "retry_count 在 no_retry 時被壓到 1");
}
print "\n", $fail ? "$fail 項失敗\n" : "全部通過\n"; exit($fail?1:0);
