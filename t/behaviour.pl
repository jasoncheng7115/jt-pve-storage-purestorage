# Covers: A8, A14   (see AUDIT_REGISTER.md)
use strict; use warnings;
use lib 'lib';
use PVE::Storage::Custom::PureStoragePlugin;
use PVE::Storage::Custom::PureStorage::API;
use PVE::Storage::Custom::PureStorage::Multipath qw(wait_for_multipath_device multipath_reload_throttled);
my $fail = 0;
sub ok { my ($c,$m)=@_; print(($c?"  ok   ":"  FAIL ")."$m\n"); $fail++ unless $c }

print "-- pure_time_to_epoch --\n";
my $t = \&PVE::Storage::Custom::PureStorage::API::pure_time_to_epoch;
ok($t->(1747000000000) == 1747000000, "REST 2.x ms -> s");
ok($t->("2026-01-15T10:30:00Z") == 1768473000, "REST 1.x ISO 8601 -> s");
ok($t->(undef) == 0 && $t->('') == 0 && $t->('garbage') == 0, "unparseable -> 0");
ok($t->(1747000000) == 1747000000, "plain seconds pass through");
ok((time() - $t->(1747000000000)) > 3600, "1hr age check now works on 2.x (was impossible)");

print "-- pod capacity (issue #10) --\n";
my ($Q,$P) = (3*1024**3, 32*1024**3);
{ no warnings 'redefine';
  *PVE::Storage::Custom::PureStorage::API::pod_get = sub {
      { items => [ { name=>'p', arrays=>[{name=>'a1'}],
        space => { total_provisioned=>$P, virtual=>512*1024**2, total_physical=>4*1024**2 } } ] } };
  *PVE::Storage::Custom::PureStorage::API::pod_get_quota_limit = sub { $Q };
}
my $api = bless { api_version=>'2.26', _api_major=>2 }, 'PVE::Storage::Custom::PureStorage::API';
for my $m (qw(provisioned virtual physical)) {
    my $c = $api->get_managed_capacity('p', usage_metric=>$m);
    ok($c->{used} <= $c->{total}, "$m: used never exceeds total");
    ok($c->{used} + $c->{available} == $c->{total}, "$m: used+avail == total");
}
my $cp = $api->get_managed_capacity('p', usage_metric=>'provisioned');
ok($cp->{raw_used} == $P, "raw (unclamped) figure preserved for diagnostics");
ok($cp->{array_count} == 1, "stretched-pod array count surfaced");
my $cb = $api->get_managed_capacity('p', usage_metric=>'bogus');
ok($cb->{metric} eq 'provisioned', "invalid metric falls back to default");

print "-- activate_storage rescan gate --\n";
my $g = \&PVE::Storage::Custom::PureStoragePlugin::_should_rescan_after_activate;
my $mk = \&PVE::Storage::Custom::PureStoragePlugin::_mark_activate_rescan;
ok($g->('s1',{},0), "first ever call rescans");
$mk->('s1');
ok(!$g->('s1',{},0), "second call within interval is suppressed");
ok($g->('s1',{},1), "new-portal-login forces a rescan through the gate");
ok($g->('s1',{'pure-rescan-interval'=>0},0), "interval 0 restores legacy behaviour");
ok($g->('s2',{},0), "gate is per-storeid");

print "-- multipathd reconfigure throttle --\n";
$PVE::Storage::Custom::PureStorage::Multipath::LAST_RECONFIGURE = time();
ok(!multipath_reload_throttled(), "suppressed inside cooldown");
$PVE::Storage::Custom::PureStorage::Multipath::LAST_RECONFIGURE = time()-3600;
{ no warnings 'redefine'; *PVE::Storage::Custom::PureStorage::Multipath::multipath_reload = sub { $PVE::Storage::Custom::PureStorage::Multipath::LAST_RECONFIGURE = time(); 1 }; }
ok(multipath_reload_throttled(), "issued after cooldown");
ok(!multipath_reload_throttled(), "cooldown re-armed by the issued call");

print "-- device discovery wait loop (issue #13) --\n";
my $blk = (grep { -b $_ } qw(/dev/dm-6 /dev/sda /dev/sdb))[0];
if ($blk) {
    my $rescans = 0;
    { no warnings 'redefine';
      *PVE::Storage::Custom::PureStorage::Multipath::get_device_by_wwid = sub { $blk };
      *PVE::Storage::Custom::PureStorage::Multipath::rescan_scsi_hosts = sub { 1 };
      *PVE::Storage::Custom::PureStorage::Multipath::_run_cmd = sub { ('','',0) }; }
    my $t0 = time();
    my $d = wait_for_multipath_device('3624a9370dead', timeout=>30, iscsi_rescan=>sub{$rescans++});
    ok($d && (time()-$t0) <= 1 && $rescans == 0, "already-present device returns instantly, zero rescans");

    my $appear = time()+4;
    { no warnings 'redefine';
      *PVE::Storage::Custom::PureStorage::Multipath::get_device_by_wwid = sub { time() >= $appear ? $blk : undef }; }
    $t0 = time();
    $d = wait_for_multipath_device('3624a9370dead', timeout=>30);
    ok($d && (time()-$t0) <= 8, "device appearing at +4s is caught (was missed before)");

    { no warnings 'redefine'; *PVE::Storage::Custom::PureStorage::Multipath::get_device_by_wwid = sub { undef }; }
    $t0 = time();
    $d = wait_for_multipath_device('3624a9370dead', timeout=>8);
    my $el = time()-$t0;
    ok(!defined($d) && $el >= 8 && $el <= 13, "never-appears honours deadline (${el}s for an 8s budget)");
} else { print "  skip (no block device on this host)\n" }

print $fail ? "\nRESULT: $fail FAILURE(S)\n" : "\nRESULT: all behaviour checks passed\n";
exit($fail ? 1 : 0);
