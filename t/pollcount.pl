# Covers: A34   (see AUDIT_REGISTER.md)
use strict; use warnings; use lib 'lib';
use PVE::Storage::Custom::PureStoragePlugin;
my $P='PVE::Storage::Custom::PureStoragePlugin';

# 計數用的假 API：記錄每個被呼叫的方法
package CountAPI;
our %calls;
sub new { bless {}, shift }
sub AUTOLOAD {
    our $AUTOLOAD; my $m = $AUTOLOAD; $m =~ s/.*:://; return if $m eq 'DESTROY';
    $calls{$m}++;
    return { items => [ { name=>'p', space=>{total_provisioned=>1}, quota_limit=>4096 } ] } if $m eq 'pod_get';
    return [] if $m =~ /list|ports/;
    return { name => 'pve-c-n1', iqns => ['iqn.x'] } if $m =~ /host_get/;
    return {};
}
package main;

my $scfg = { 'pure-portal'=>'10.0.0.1', 'pure-pod'=>'p', 'pure-protocol'=>'iscsi',
             'pure-api-token'=>'t', 'pure-rescan-interval'=>300 };
{ no warnings 'redefine';
  *PVE::Storage::Custom::PureStoragePlugin::_get_api = sub { CountAPI->new };
  *PVE::Storage::Custom::PureStoragePlugin::_ensure_multipath_config = sub { 1 };
  *PVE::Storage::Custom::PureStoragePlugin::_get_host_name = sub { 'pve-c-n1' };
  *PVE::Storage::Custom::PureStoragePlugin::_get_initiators = sub { ('iqn','iqn.x') };
  *PVE::Storage::Custom::PureStoragePlugin::get_sessions = sub { [] };
  *PVE::Storage::Custom::PureStoragePlugin::rescan_sessions = sub { 1 };
  *PVE::Storage::Custom::PureStoragePlugin::rescan_scsi_hosts = sub { 1 };
  *PVE::Storage::Custom::PureStoragePlugin::multipath_reload_throttled = sub { 0 };
  *PVE::Storage::Custom::PureStoragePlugin::_udev_refresh = sub { 1 };
  *PVE::Storage::Custom::PureStoragePlugin::_record_status_ok = sub { 1 };
  *PVE::Storage::Custom::PureStoragePlugin::_record_status_failure = sub { 1 };
  *PVE::Storage::Custom::PureStoragePlugin::_warn_pod_quota_exhausted = sub { 1 };
}

# activate_storage 對「沒有 iSCSI port」的情況會直接跳過登入迴圈，
# 所以這裡量的是 array_get + iscsi_get_ports + _ensure_host 的次數。
for my $poll (1..3) {
    %CountAPI::calls = () if $poll == 1;
    eval { $P->activate_storage('st1', $scfg, {}) };
    my $cache = {};
    eval { $P->status('st1', $scfg, $cache) };
}
printf "  三次連續輪詢（含 activate_storage + status 前景）的 REST 呼叫：\n";
my $total = 0;
for my $m (sort keys %CountAPI::calls) { printf "    %-22s %d\n", $m, $CountAPI::calls{$m}; $total += $CountAPI::calls{$m}; }
printf "    %-22s %d\n", "合計", $total;
printf "\n  平均每次輪詢: %.1f 次\n", $total/3;
print "  （舊版：array_get 3 + iscsi_get_ports 3 + host_get 3 + pod_get 6 = 15，即每次 5.0）\n";

# The regression this guards is growth: v1.1.21 went through this path once
# and v1.1.26 found four more calls, so a number that creeps back up is the
# thing to catch. The budget is the measured figure with a little headroom;
# raising it should be a deliberate act with a reason, not a silent drift.
my $BUDGET = 10;   # REST calls across three consecutive polls
my $ok = ($total <= $BUDGET);
printf "\n  %-4s 三次輪詢的 REST 呼叫在預算內   got=%d  budget=%d\n",
    $ok ? 'ok' : 'FAIL', $total, $BUDGET;
if (!$ok) {
    print "       A poll is on the pvestatd path, sequential across every\n";
    print "       storage. Anything appearing three times that is not genuinely\n";
    print "       per-poll information is avoidable. [AUDIT A34]\n";
}
# And the shape: nothing may be called once per volume.
my $per_volume = 0;
for my $m (keys %CountAPI::calls) {
    $per_volume++ if $m =~ /volume_get_wwid|volume_get_connections/ && $CountAPI::calls{$m} > 3;
}
printf "  %-4s 沒有以每顆 Volume 為單位的呼叫\n", $per_volume ? 'FAIL' : 'ok';
printf "\n%d passed, %d failed\n", (2 - $per_volume - ($ok?0:1)), ($per_volume + ($ok?0:1));
exit(($ok && !$per_volume) ? 0 : 1);
