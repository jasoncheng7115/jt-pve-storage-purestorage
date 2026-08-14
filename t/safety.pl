# Covers: A3, A4   (see AUDIT_REGISTER.md)
use strict; use warnings; use lib 'lib';
use PVE::Storage::Custom::PureStoragePlugin;
use PVE::Storage::Custom::PureStorage::Multipath qw(device_usage_state is_device_in_use);
my $P = 'PVE::Storage::Custom::PureStoragePlugin';
my $M = 'PVE::Storage::Custom::PureStorage::Multipath';
my $fail = 0;
sub ok { my ($c,$m)=@_; print(($c?"  ok   ":"  FAIL ")."$m\n"); $fail++ unless $c }
sub dies_like { my ($code,$re,$m)=@_; eval { $code->() }; my $e=$@//''; ok($e =~ $re, "$m"); print "         got: ".substr(($e||'(no exception)'),0,110)."\n" unless $e =~ $re }

my $blk = (grep { -b $_ } qw(/dev/dm-0 /dev/sda))[0] or die "no block dev\n";

print "== _require_wwid_for_guard：查詢失敗必須拒絕，不得靜默略過 ==\n";
{
  my $api = bless {}, 'FakeAPI';
  { no strict 'refs'; *FakeAPI::volume_get_wwid = sub { die "HTTP 503: Service Unavailable\n" }; }
  dies_like(sub { $P->can('_require_wwid_for_guard')->($api,'pod::v1','delete volume') },
            qr/Refusing to delete volume.*WWID could not be read/s, "REST 失敗 -> 拒絕刪除");
  { no strict 'refs'; no warnings 'redefine'; *FakeAPI::volume_get_wwid = sub { undef }; }
  dies_like(sub { $P->can('_require_wwid_for_guard')->($api,'pod::v1','roll back volume') },
            qr/Refusing to roll back volume.*returned no serial/s, "無 serial -> 拒絕 rollback");
  { no strict 'refs'; no warnings 'redefine'; *FakeAPI::volume_get_wwid = sub { '3624a9370abc' }; }
  my $w = $P->can('_require_wwid_for_guard')->($api,'pod::v1','delete volume');
  ok($w eq '3624a9370abc', "正常情況回傳 WWID");
}

print "\n== _assert_device_idle：unknown 必須擋下 ==\n";
my $assert = $P->can('_assert_device_idle');
{
  no warnings 'redefine';
  *PVE::Storage::Custom::PureStoragePlugin::get_device_by_wwid = sub { $blk };
  no strict "refs"; *{"PVE::Storage::Custom::PureStorage::Multipath::_run_cmd"} = sub { die "Command timed out after 5s\n" };
}
dies_like(sub { $assert->('3624a9370abc','vm-100-disk-0','delete volume') },
          qr/cannot determine whether.*in use/s, "in-use 查不出來 -> 拒絕刪除");
{
  no warnings 'redefine';
  *PVE::Storage::Custom::PureStoragePlugin::get_device_by_wwid = sub { die "multipathd not responding\n" };
}
dies_like(sub { $assert->('3624a9370abc','vm-100-disk-0','delete volume') },
          qr/could not look up the local device/s, "裝置查詢本身失敗 -> 拒絕刪除");
{
  no warnings 'redefine';
  *PVE::Storage::Custom::PureStoragePlugin::get_device_by_wwid = sub { undef };
}
eval { $assert->('3624a9370abc','vm-100-disk-0','delete volume') };
ok(!$@, "本機沒有裝置 -> 放行（不可過度封鎖）");

print "\n== temp clone 嚴格比對：只能刪自己產生的名稱 ==\n";
my $san = 'mystore';
my $re = qr/^pve-\Q$san\E-.+-temp-snap-access-(\d+)-(\d+)$/;
my @cases = (
  ["pve-mystore-100-disk0-temp-snap-access-1750000000-1234" => 1, "我們自己產生的"],
  ["pve-mystore-100-disk0-temp-snap-access-manual"          => 0, "手動命名、無 ts-pid"],
  ["pve-mystore-temp-snap-access-backup"                    => 0, "沒有 vmid 段"],
  ["pve-otherstore-100-disk0-temp-snap-access-1750000000-1" => 0, "別的 storage"],
  ["customer-temp-snap-access-1750000000-1"                 => 0, "客戶自己的 Volume"],
);
for my $c (@cases) {
  my ($n,$want,$desc) = @$c;
  my $got = ($n =~ $re) ? 1 : 0;
  ok($got == $want, sprintf("%-6s %s", $want?"刪":"不刪", $desc));
}
print "\n", $fail ? "$fail 項失敗\n" : "全部通過\n";
exit($fail?1:0);
