#!/usr/bin/perl
# Covers: A56   (see AUDIT_REGISTER.md)
# FlashArray names are case-insensitive. A pod that exists as `pve-pod` is
# accepted as `PVE-Pod` for every create and connect, but the array returns
# names in its own spelling -- and the pod filter and the local re-match of
# returned names compared exact strings. The pod's volume list came back empty:
# no disks in the web interface, and the orphan reaper treated every tracked
# device of the storage as stale.
use strict; use warnings;
use FindBin; use lib "$FindBin::Bin/../lib";
require PVE::Storage::Custom::PureStorage::API;
require PVE::Storage::Custom::PureStoragePlugin;
my $A = 'PVE::Storage::Custom::PureStorage::API';
my ($pass,$fail)=(0,0);
sub check { my ($d,$g,$w)=@_; my $ok="$g" eq "$w"; $ok?$pass++:$fail++;
    printf "  %-4s %-58s got=%-8s want=%s\n",$ok?'ok':'FAIL',$d,$g,$w; }

# The array: pod stored as 'pve-pod'. Name lookups are case-insensitive;
# the filter is modelled as an exact string match, the strict reading.
my @vols = map { { name => "pve-pod::pve-pure_fc-10000-disk$_", serial => "S$_" } } 0..1;
push @vols, { name => 'pve-pod::someone-else', serial => 'X' };
my @snaps = ({ name => 'pve-pod::pve-pure_fc-10000-disk0.pve-snap-s1',
               source => { name => 'pve-pod::pve-pure_fc-10000-disk0' } });
{ no warnings 'redefine'; no strict 'refs';
  *{"${A}::get"} = sub {
      my ($self, $ep, $p) = @_;
      if ($ep eq 'pods') {
          return { items => [ lc($p->{names}) eq 'pve-pod' ? { name => 'pve-pod' } : () ] };
      }
      my ($want) = ($p->{filter} // '') =~ /pod\.name='([^']*)'/;
      my $src = $ep eq 'volumes' ? \@vols : \@snaps;
      return { items => [ grep { !defined $want || $_->{name} =~ /^\Q$want\E::/ } @$src ] };
  };
}
my $api = bless { _api_major => 2, api_version => '2.26' }, $A;

my $list = $api->volume_list('PVE-Pod::pve-pure_fc-*');
check('volume_list with pure-pod spelled differently', scalar(@$list), 2);
$list = $api->volume_list('pve-pod::pve-pure_fc-*');
check('  (same spelling still works)', scalar(@$list), 2);
my $snaps = $api->snapshot_list('PVE-Pod::pve-pure_fc-10000-disk0');
check('snapshot_list of a pod volume, spelled differently', scalar(@$snaps), 1);

my $strip = \&PVE::Storage::Custom::PureStoragePlugin::_strip_pod_prefix;
check('pod prefix stripped regardless of case',
    $strip->({ 'pure-pod' => 'PVE-Pod' }, 'pve-pod::pve-pure_fc-10000-disk0'),
    'pve-pure_fc-10000-disk0');

printf "\n%d passed, %d failed\n", $pass, $fail;
exit($fail ? 1 : 0);
