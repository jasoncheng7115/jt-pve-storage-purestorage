#!/usr/bin/perl
# Covers: A43   (see AUDIT_REGISTER.md)
# encode_host_name() truncates the node name to 20 characters. Node names that
# are longer and share a 20-character prefix collapse onto one Pure host
# object, and then the array cannot tell the two nodes apart.
use strict; use warnings;
use FindBin; use lib "$FindBin::Bin/../lib";
use PVE::Storage::Custom::PureStorage::Naming qw(encode_host_name);
require PVE::Storage::Custom::PureStoragePlugin;
my $P = 'PVE::Storage::Custom::PureStoragePlugin';
my ($pass,$fail)=(0,0);
sub check { my ($d,$g,$w)=@_; my $ok="$g" eq "$w"; $ok?$pass++:$fail++;
    printf "  %-4s %-52s got=%-12s want=%s\n", $ok?'ok':'FAIL',$d,$g,$w; }

my @NODES = qw(virtualization-node-01 virtualization-node-02 pve-a);
{
    no warnings 'redefine';
    *PVE::Cluster::get_nodelist = sub { return [@NODES] };
    *PVE::INotify::nodename     = sub { return $NODES[0] };
}
sub warn_for {
    my (%scfg) = @_;
    my $out = '';
    local $SIG{__WARN__} = sub { $out .= $_[0] };
    my $hn = encode_host_name($scfg{'pure-cluster-name'} // 'pve',
        ($scfg{'pure-host-mode'} // 'per-node') eq 'shared' ? undef : $NODES[0]);
    unlink glob('/var/run/pve-storage-purestorage/hostname-clash-*');
    PVE::Storage::Custom::PureStoragePlugin::_warn_host_name_collision(\%scfg, $hn);
    return $out;
}
check('兩個長節點名產生同一個 host 名稱',
    encode_host_name('pve','virtualization-node-01') eq
    encode_host_name('pve','virtualization-node-02') ? 'collide':'distinct','collide');
check('per-node 模式下會警告',
    (warn_for() =~ /virtualization-node-02/) ? 'warned':'silent','warned');
check('警告有具體指出後果',
    (warn_for() =~ /reaper|ownership|Disconnecting/) ? 'actionable':'vague','actionable');
check('shared 模式不誤報',
    (warn_for('pure-host-mode'=>'shared') =~ /\S/) ? 'FALSE POSITIVE':'silent','silent');
{
    no warnings 'redefine';
    *PVE::Cluster::get_nodelist = sub { return ['pve-a','pve-b'] };
    *PVE::INotify::nodename     = sub { return 'pve-a' };
    my $out=''; local $SIG{__WARN__}=sub{$out.=$_[0]};
    unlink glob('/var/run/pve-storage-purestorage/hostname-clash-*');
    PVE::Storage::Custom::PureStoragePlugin::_warn_host_name_collision({}, encode_host_name('pve','pve-a'));
    check('短節點名不誤報', ($out =~ /\S/) ? 'FALSE POSITIVE':'silent','silent');
}
# cooldown: a second call inside the hour must stay quiet
my $first = warn_for();
my $second = do { my $o=''; local $SIG{__WARN__}=sub{$o.=$_[0]};
    PVE::Storage::Custom::PureStoragePlugin::_warn_host_name_collision({}, encode_host_name('pve',$NODES[0])); $o };
check('一小時內不重複洗版', ($second =~ /\S/) ? 'repeated':'suppressed','suppressed');
unlink glob('/var/run/pve-storage-purestorage/hostname-clash-*');
printf "\n%d passed, %d failed\n",$pass,$fail;
exit($fail?1:0);
