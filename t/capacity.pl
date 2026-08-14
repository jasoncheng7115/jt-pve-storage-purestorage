# Covers: A15, A36   (see AUDIT_REGISTER.md)
use strict; use warnings; use lib 'lib';
use PVE::Storage::Custom::PureStoragePlugin;
my $P='PVE::Storage::Custom::PureStoragePlugin';
my $refresh = $P->can('_refresh_local_capacity');
my $fail=0; my @actions;
sub ok { my($c,$m)=@_; print(($c?"  ok   ":"  FAIL ")."$m\n"); $fail++ unless $c }

my $reported;
{ no warnings 'redefine';
  *PVE::Tools::run_command = sub { my ($cmd,%o)=@_; $o{outfunc}->($reported) if $o{outfunc}; 1 };
  *PVE::Storage::Custom::PureStoragePlugin::get_multipath_slaves = sub { push @actions,'slaves'; ['/dev/sdx'] };
  *PVE::Storage::Custom::PureStoragePlugin::rescan_scsi_device = sub { push @actions,'rescan'; 1 };
  *PVE::Storage::Custom::PureStoragePlugin::multipath_resize_map = sub { push @actions,'resize'; 1 };
  *PVE::Storage::Custom::PureStoragePlugin::_udev_refresh = sub { push @actions,'udev'; 1 };
}
my $G = 1024**3;

@actions=(); $reported = 50*$G;
$refresh->('/dev/mapper/x', 50*$G, 'vm-100-disk-0');
ok(!@actions, "容量相符 -> 完全不動作（不是每次啟用都重掃）");

@actions=(); $reported = 50*$G;
$refresh->('/dev/mapper/x', 100*$G, 'vm-100-disk-0');
ok((grep { $_ eq 'resize' } @actions), "陣列 100G 但本機 50G -> 觸發重掃 + resize map");

@actions=(); $reported = "";
$refresh->('/dev/mapper/x', 100*$G, 'vm-100-disk-0');
ok(!@actions, "blockdev 無法解析 -> 不動作（不猜測）");

@actions=();
$refresh->(undef, 100*$G, 'vm-100-disk-0');
ok(!@actions, "本機無裝置 -> 不動作");

@actions=(); $reported = 50*$G;
$refresh->('/dev/mapper/x', undef, 'vm-100-disk-0');
ok(!@actions, "陣列端大小未知 -> 不動作");
print "\n", $fail ? "$fail 項失敗\n" : "全部通過\n";
exit($fail?1:0);
