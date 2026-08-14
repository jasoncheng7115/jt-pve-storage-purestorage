# Covers: A32   (see AUDIT_REGISTER.md)
use strict; use warnings; use lib 'lib';
use PVE::Storage::Custom::PureStoragePlugin;
use PVE::Storage::Custom::PureStorage::Naming qw(pve_volname_to_pure pure_to_pve_volname decode_volume_name);
my $P='PVE::Storage::Custom::PureStoragePlugin';
my $fail=0; sub ok { my($c,$m)=@_; print(($c?"  ok   ":"  FAIL ")."$m\n"); $fail++ unless $c }

print "-- PVE 會要求的每一種名稱都要能來回轉換 --\n";
for my $n (qw(vm-100-disk-0 base-100-disk-0 vm-100-cloudinit vm-100-state-snap1 vm-100-fleece-0 vm-100-fleece-3)) {
    my $pure = eval { pve_volname_to_pure('mystore', $n) };
    my $back = defined $pure ? pure_to_pve_volname($pure) : undef;
    my $want = $n; $want =~ s/^base-/vm-/;   # base 解碼回 vm- 是預期行為
    ok(defined $pure && ($back//'') eq $want, sprintf("%-20s -> %-32s -> %s", $n, $pure//'X', $back//'X'));
}

print "\n-- parse_volname 接受 fleece --\n";
my @r = eval { $P->parse_volname('vm-100-fleece-0') };
ok(!$@ && $r[0] eq 'images' && $r[2] == 100, "parse_volname('vm-100-fleece-0') -> images/100");

print "\n-- alloc_image 不再默默改名 --\n";
my $alloc = sub {
    my ($name) = @_;
    my $err;
    { no warnings 'redefine';
      *PVE::Storage::Custom::PureStoragePlugin::_get_api = sub { die "REACHED-API\n" }; }
    eval { $P->alloc_image('mystore', {'pure-portal'=>'x'}, 100, 'raw', $name, 1024) };
    return $@;
};
my $e = $alloc->('vm-100-fleece-0');
ok($e =~ /REACHED-API/, "fleece 名稱 -> 通過名稱檢查（走到 API 才停）");
$e = $alloc->('vm-100-disk-0');
ok($e =~ /REACHED-API/, "一般磁碟 -> 通過");
$e = $alloc->(undef);
ok($e =~ /REACHED-API/, "未指定名稱 -> 通過（由外掛自行命名）");
$e = $alloc->('some-random-name');
ok($e =~ /does not know how to name/, "無法辨識的名稱 -> 明確拒絕，不再默默改名");
print "     訊息: ", (split /\n/, $e)[0], "\n" if $e =~ /does not know/;

print "\n-- fleece 不會干擾磁碟編號 --\n";
my $d = decode_volume_name('pve-mystore-100-fleece0');
ok($d && $d->{type} eq 'fleece' && !defined $d->{diskid}, "fleece 解碼後沒有 diskid（_find_free_diskid 不會把它算進去）");
print "\n", $fail ? "$fail 項失敗\n" : "全部通過\n"; exit($fail?1:0);
