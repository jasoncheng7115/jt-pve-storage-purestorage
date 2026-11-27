# Covers: O4   (see AUDIT_REGISTER.md)
# Proxmox VE 9.3 Node > SAN: `target` is what makes PVE refuse to wipe our
# iSCSI LUNs, and the 9.3 dialog metadata that comes with it.
use strict; use warnings; no warnings 'once'; use lib 'lib';
use PVE::Storage::Custom::PureStoragePlugin;
my $P='PVE::Storage::Custom::PureStoragePlugin';
my $fail=0; sub ok { my($c,$m)=@_; die "ok() needs a message\n" unless defined $m; print(($c?"  ok   ":"  FAIL ")."$m\n"); $fail++ unless $c }

my $IQN = 'iqn.2010-06.com.purestorage:flasharray.0123456789abcdef';

print "-- schema --\n";
my $props = $P->properties();
my $opts  = $P->options();
my $pd    = $P->plugindata();
ok(exists $opts->{target} && $opts->{target}{optional} && !$opts->{target}{fixed},
   "options() 接受 target，且可用 pvesm set 修改");
ok(!exists $props->{target}, "properties() 沒有重新宣告 target（ISCSIPlugin 已宣告）");
my @untitled = grep { !defined $props->{$_}{title} } sort keys %$props;
ok(!@untitled, "每個 pure-* 屬性都有 title" . (@untitled ? "：缺 @untitled" : ''));
my @stray = grep { !exists $opts->{$_} } sort keys %{ $pd->{'advanced-properties'} // {} };
ok(!@stray, "advanced-properties 只列 options() 有的鍵" . (@stray ? "：多了 @stray" : ''));
ok(!$pd->{'advanced-properties'}{'pure-ssl-verify'} && !$pd->{'advanced-properties'}{target},
   "pure-ssl-verify 與 target 不收進進階區");
my $dn = $pd->{meta}{'display-name'};
ok(defined $dn && !ref $dn && length $dn, "meta display-name 是非空字串");

print "\n-- 與已安裝的 PVE 一起載入 --\n";
my $have_pve = eval { require PVE::Storage; 1 };
if (!$have_pve) {
    print "  SKIP PVE::Storage 無法載入\n";
} else {
    my @w; local $SIG{__WARN__} = sub { push @w, @_ unless $_[0] =~ /older storage API/ };
    my $raw = "purestorage: pure1\n\tpure-portal 192.0.2.10\n\ttarget $IQN\n\tcontent images\n";
    my $cfg = PVE::Storage::Plugin->parse_config('storage.cfg', $raw);
    ok(($cfg->{ids}{pure1}{target} // '') eq $IQN, "parse_config 保留 target");
    ok(!grep({ /target/ } @w), "解析時沒有 unexpected property 警告");
    my $out = PVE::Storage::Plugin->write_config('storage.cfg', $cfg);
    ok($out =~ /^\ttarget \Q$IQN\E$/m ? 1 : 0, "write_config 寫回 target");
}

print "\n-- Node > SAN 的 Wipe / Create VG 檢查 --\n";
if (!$have_pve || !eval { require PVE::Storage::SAN; 1 }) {
    print "  SKIP 這個 PVE 沒有 PVE::Storage::SAN（9.3 之前）\n";
} else {
    no warnings 'redefine';
    # 只把會碰 LVM 與 sysfs 的部分換掉；比對邏輯是 PVE 自己的程式碼
    local *PVE::Storage::LVMPlugin::lun_volume_groups = sub { [] };
    local *PVE::ISCSI::Topology::device_map = sub { {} };
    local *PVE::Storage::SAN::lun_paths      = sub { [] };
    local *PVE::Storage::SAN::lun_partitions = sub { [] };
    my $lun = { devpath => '/dev/dm-99', wwid => '3624a93700123456789abcdef01234567',
                'iscsi-target' => $IQN };
    my $mk = sub { { ids => { pure1 => { type => 'purestorage', content => { images => 1 }, @_ } } } };

    eval { PVE::Storage::SAN::assert_lun_unreferenced($mk->(target => $IQN), $lun) };
    ok(($@ // '') =~ /storage 'pure1' serves images/ ? 1 : 0, "設定 target -> PVE 拒絕抹除");
    eval { PVE::Storage::SAN::assert_lun_unreferenced($mk->(), $lun) };
    ok(!$@, "對照組：沒有 target -> PVE 允許抹除（這就是要防的情況）");
    eval { PVE::Storage::SAN::assert_lun_unreferenced($mk->(target => uc $IQN), $lun) };
    ok(!$@, "大小寫不同 -> 比對不到（所以 hook 要檢查完全相同）");
    my $fc = { %$lun }; delete $fc->{'iscsi-target'};
    eval { PVE::Storage::SAN::assert_lun_unreferenced($mk->(target => $IQN), $fc) };
    ok(!$@, "FC LUN 沒有 iSCSI session -> target 保護不到（文件須寫明）");
}

print "\n-- hook 檢查 target --\n";
{
    no warnings 'redefine';
    my ($calls, $ports, $die) = (0, [], undef);
    local *PVE::Storage::Custom::PureStoragePlugin::_get_api = sub {
        $calls++; die $die if $die;
        return bless { p => $ports }, 'FakeAPI';
    };
    local *FakeAPI::iscsi_get_ports = sub { $_[0]{p} };
    my $check = $P->can('_check_san_target');
    my $warns = sub { my @w; local $SIG{__WARN__} = sub { push @w, @_ }; $_[0]->(); join '', @w };

    $ports = [{ iqn => $IQN, name => 'CT0.ETH4' }, { iqn => $IQN, name => 'CT1.ETH4' }];
    ok($warns->(sub { $check->('pure1', { target => $IQN }) }) eq '', "IQN 相符 -> 不警告");
    ok($warns->(sub { $check->('pure1', { target => 'iqn.wrong' }) }) =~ /\Q$IQN\E.*NOT protected/s ? 1 : 0,
       "IQN 不符 -> 警告並列出陣列的 IQN");
    $calls = 0;
    ok($warns->(sub { $check->('pure1', { target => $IQN, 'pure-protocol' => 'fc' }) }) =~ /no effect/ ? 1 : 0,
       "FC -> 警告沒有作用");
    ok($calls == 0, "FC -> 不呼叫 REST");
    $die = "connection refused\n";
    ok($warns->(sub { $check->('pure1', { target => $IQN }) }) =~ /could not read.*connection refused/s ? 1 : 0,
       "陣列不回應 -> 只警告，不中斷設定");
    $die = undef;

    $calls = 0;
    $P->on_update_hook_full('pure1', { target => $IQN }, { 'pure-device-timeout' => 90 }, undef, {});
    ok($calls == 0, "無關的 pvesm set -> 不呼叫 REST");
    $P->on_update_hook_full('pure1', {}, { target => $IQN }, undef, {});
    ok($calls == 1, "pvesm set --target -> 檢查一次");
}

print "\n", $fail ? "$fail 項失敗\n" : "全部通過\n"; exit($fail?1:0);
