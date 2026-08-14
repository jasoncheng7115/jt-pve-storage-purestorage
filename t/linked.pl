# Covers: A27   (see AUDIT_REGISTER.md)
use strict; use warnings; use lib 'lib';
use PVE::Storage::Custom::PureStoragePlugin;
my $f = PVE::Storage::Custom::PureStoragePlugin->can('_linked_clone_base');
my $fail=0; sub ok { my($c,$m)=@_; print(($c?"  ok   ":"  FAIL ")."$m\n"); $fail++ unless $c }
my $scfg = {};
ok(($f->($scfg,{source=>{name=>'pve-store-102-disk0.pve-base'}}) // '') eq 'base-102-disk-0',
   "來源是範本的 .pve-base 快照 -> 回報 base-102-disk-0");
ok(!defined $f->($scfg,{source=>{name=>'pve-store-102-disk0.pve-snap-daily'}}),
   "來源是使用者快照 -> 不加 base 前綴（那是從快照複製，非 linked clone）");
ok(!defined $f->($scfg,{source=>{name=>'pve-store-102-disk0'}}),
   "來源是整顆 Volume -> 不加（full clone）");
ok(!defined $f->($scfg,{}), "陣列未回報 source -> 不動作（安全方向，行為同舊版）");
ok(!defined $f->($scfg,{source=>'garbage'}), "無法解析 -> 不動作");
ok(($f->({'pure-pod'=>'mypod'},{source=>{name=>'mypod::pve-store-102-disk0.pve-base'}}) // '') eq 'base-102-disk-0',
   "pod 前綴會被剝除");
print "\n", $fail ? "$fail 項失敗\n" : "全部通過\n"; exit($fail?1:0);
