# Covers: A16, A17   (see AUDIT_REGISTER.md)
use strict; use warnings; use lib 'lib';
use PVE::Storage::Custom::PureStoragePlugin;
my $P='PVE::Storage::Custom::PureStoragePlugin';
my $sweep = $P->can('_sweep_temp_snap_clones');
my $fail=0;
sub ok { my($c,$m)=@_; print(($c?"  ok   ":"  FAIL ")."$m\n"); $fail++ unless $c }

my $now = time();
my @deleted;
my $VOL = 'pve-store-100-disk0';
# 假 API：回傳一批候選，記錄哪些被刪
package FakeAPI;
sub new { my ($c,%o)=@_; bless {%o}, $c }
sub volume_list { my ($s)=@_; return $s->{vols} }
sub volume_get_connections { my ($s,$n)=@_; return $s->{conns}{$n} // [{name=>'pve-pve-thisnode'}] }
sub serial_to_wwid { return undef }
sub volume_get_wwid { return undef }
sub volume_disconnect_host { return 1 }
sub volume_delete { my ($s,$n,%o)=@_; die "eradicate!\n" unless $o{skip_eradicate}; push @deleted,$n; return 1 }
package main;

{ no warnings 'redefine';
  *PVE::Storage::Custom::PureStoragePlugin::_get_host_name = sub { 'pve-pve-thisnode' };
  *PVE::Storage::Custom::PureStoragePlugin::cleanup_lun_devices = sub { 1 };
}
my $scfg = {};
my $api = FakeAPI->new(
  vols => [
    { name => "$VOL-temp-snap-access-".($now-7200)."-111", serial=>undef },  # 我們的，夠舊
    { name => "$VOL-temp-snap-access-".($now-10)."-222",   serial=>undef },  # 我們的，太新
    { name => "$VOL-temp-snap-access-manual",              serial=>undef },  # 名稱不符
    { name => "$VOL-temp-snap-access-".($now-7200)."-333", serial=>undef },  # 連到別的節點
    { name => "other-vol-temp-snap-access-".($now-7200)."-444", serial=>undef }, # 別顆 Volume
  ],
  conns => { "$VOL-temp-snap-access-".($now-7200)."-333" => [{name=>'pve-pve-OTHERNODE'}] },
);
my $n = $sweep->($scfg, 'store', $api, $VOL);
ok($n == 1, "只釋放 1 顆（實際 $n）");
ok((grep { /-111$/ } @deleted) == 1, "夠舊且屬於本節點的 -> 釋放");
ok((grep { /-222$/ } @deleted) == 0, "10 秒前才建立的 -> 保留（可能有併發操作）");
ok((grep { /manual$/ } @deleted) == 0, "名稱不符我們產生的格式 -> 不碰");
ok((grep { /-333$/ } @deleted) == 0, "連線到其他節點 -> 不碰（歸屬保護）");
ok((grep { /-444$/ } @deleted) == 0, "屬於別顆 Volume -> 不碰");
print "\n", $fail ? "$fail 項失敗\n" : "全部通過（且刪除一律為軟刪除，否則假 API 會拋錯）\n";
exit($fail?1:0);
