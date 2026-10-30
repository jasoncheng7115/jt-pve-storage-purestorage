#!/usr/bin/perl
# Covers: A53   (see AUDIT_REGISTER.md)
# The kernel names FC remote ports "rport-<host>:<channel>-<number>"
# (scsi_transport_fc: "rport-%d:%d-%d"). get_fc_targets() matched
# rport-N-N-N, which never exists, so every FC node warned that no target
# port was visible even with zoning and paths healthy.
use strict; use warnings;
use FindBin; use lib "$FindBin::Bin/../lib";
use File::Temp qw(tempdir);
use PVE::Storage::Custom::PureStorage::FC qw(get_fc_targets);
my ($pass,$fail)=(0,0);
sub check { my ($d,$g,$w)=@_; my $ok="$g" eq "$w"; $ok?$pass++:$fail++;
    printf "  %-4s %-56s got=%-6s want=%s\n",$ok?'ok':'FAIL',$d,$g,$w; }

my $root = tempdir(CLEANUP => 1);
sub rport { my ($name,%a)=@_; mkdir "$root/$name" or die $!;
    for my $k (keys %a) { open my $fh,'>',"$root/$name/$k" or die $!; print $fh "$a{$k}\n"; close $fh } }

rport('rport-3:0-1', port_name=>'0x524a937000000001', node_name=>'0x524a937000000000',
      port_state=>'Online', roles=>'FCP Target');
rport('rport-4:0-0', port_name=>'0x524a937000000011', node_name=>'0x524a937000000000',
      port_state=>'Online', roles=>'FCP Target');
rport('rport-4:0-2', port_name=>'0x2000000000000001', node_name=>'0x2000000000000000',
      port_state=>'Online', roles=>'Fabric');

my $t = get_fc_targets($root);
check('kernel-format rport entries are enumerated', scalar(@$t), 3);
my @online = grep { $_->{is_target} && $_->{port_state} =~ /online/i } @$t;
check('online FCP targets found (no false warning)', scalar(@online), 2);
my ($r) = grep { $_->{rport} eq 'rport-3:0-1' } @$t;
check('WWPN read and formatted', $r->{wwpn} // '', '52:4a:93:70:00:00:00:01');

printf "\n%d passed, %d failed\n", $pass, $fail;
exit($fail ? 1 : 0);
