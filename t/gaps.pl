#!/usr/bin/perl
# Covers: A7, A10, A11, A16, A23, A25, A26, A29, A30, A33, A41, A51   (see AUDIT_REGISTER.md)
#
# Register entries that had neither a static check nor a test. Each one shipped
# once; the point of a test is that it cannot ship twice.
use strict;
use warnings;
use FindBin;
use lib "$FindBin::Bin/../lib";

require PVE::Storage::Custom::PureStorage::API;
require PVE::Storage::Custom::PureStoragePlugin;
my $A = 'PVE::Storage::Custom::PureStorage::API';
my $P = 'PVE::Storage::Custom::PureStoragePlugin';

my ($pass, $fail) = (0, 0);
sub check {
    my ($d, $g, $w) = @_;
    my $ok = defined($g) && defined($w) && "$g" eq "$w";
    $ok ? $pass++ : $fail++;
    printf "  %-4s %-56s got=%-20s want=%s\n", $ok ? 'ok' : 'FAIL', $d,
        defined $g ? $g : 'undef', defined $w ? $w : 'undef';
}

# ---- A10: 2.x timestamps are milliseconds, 1.x is ISO 8601 ---------------
# Wrong in either direction is silent: an age check that can never fire, or a
# date ~53000 years out in the web interface.
print "A10 REST 2.x timestamps are milliseconds\n";
{
    my $t2e = $A->can('pure_time_to_epoch');
    check('  函式存在', $t2e ? 'yes' : 'MISSING', 'yes');
    if ($t2e) {
        my $now = 1770000000;
        check('  2.x 毫秒轉為秒', $t2e->($now * 1000), $now);
        check('  1.x ISO 8601 轉為秒', $t2e->('2026-02-02T02:40:00Z'), $now);
        check('  秒級的值不會被再除一次', $t2e->($now), $now);
        # An absent timestamp returns 0 on purpose, and the decision point --
        # not this helper -- is where that is made safe: the temp-clone reaper
        # carries `next unless $created; # unknown age: never assume it is
        # stale`. Assert the contract the code actually has, and assert the
        # guard that makes it fail closed.
        check('  缺少時間戳記回傳假值', ($t2e->(undef) ? 'truthy' : 'falsy'), 'falsy');
        check('  無法解析的值同樣是假值', ($t2e->('not-a-date') ? 'truthy' : 'falsy'), 'falsy');
        # The bug: a one-hour age test computed time() - 1.7e12 and never fired.
        my $age = $now - $t2e->($now * 1000);
        check('  一小時的年齡判斷可以成立', ($age < 3600) ? 'usable' : "absurd ($age)", 'usable');
    }
}

# ---- A11: 2.x `names` takes exact names only ----------------------------
print "\nA11 API 2.x names= does not accept wildcards\n";
{
    my @sent;
    my $api = bless {
        host => 'x', port => 443, api_version => '2.26', _api_major => 2,
        _session_token => 't', ssl_verify => 0,
    }, $A;
    no warnings 'redefine';
    local *PVE::Storage::Custom::PureStorage::API::_get_v2_collection = sub {
        my ($self, $path, $params) = @_;
        push @sent, { path => $path, %{ $params // {} } };
        return [];
    };
    local *PVE::Storage::Custom::PureStorage::API::get = sub { return { items => [] } };

    @sent = ();
    $api->volume_list('pve-store-*');
    my $p = $sent[0] // {};
    check('  萬用字元走 filter=', ($p->{filter} // '') =~ /name=/ ? 'filter' : 'names', 'filter');
    check('  萬用字元不會出現在 names=', exists $p->{names} ? 'names set' : 'absent', 'absent');

    @sent = ();
    $api->volume_list('pve-store-100-disk0');
    $p = $sent[0] // {};
    check('  精確名稱走 names=', exists $p->{names} ? 'names' : 'filter', 'names');
}

# ---- A41: base-class methods that would run the wrong machinery ---------
print "\nA41 inherited methods are refused rather than run\n";
for my $m (qw(rename_snapshot volume_snapshot_info)) {
    my $own = defined &{"PVE::Storage::Custom::PureStoragePlugin::$m"};
    check("  $m 由本外掛自行實作", $own ? 'own' : 'INHERITED', 'own');
    my $died = !eval { $P->$m({}, 'store', 'vm-100-disk-0', 'a', 'b'); 1 };
    check("  $m 明確拒絕", $died ? 'refused' : 'RAN', 'refused');
}

# ---- A51: an outage must not repeat the full error on every poll --------
print "\nA51 a recorded outage stops repeating the transport error\n";
{
    my $long = "Failed to create session: 500 Can't connect to 198.51.100.7:443 "
             . "(Connection timed out) (URL: https://198.51.100.7:443/api/2.26/login, "
             . "Method: POST, Has-API-Token: yes) at /usr/share/perl5/PVE/Storage/"
             . "Custom/PureStoragePlugin.pm line 2432.";
    check('  真實的傳輸錯誤確實很長', (length($long) > 200) ? 'long' : 'short', 'long');

    my $src = do {
        open(my $fh, '<', "$FindBin::Bin/../lib/PVE/Storage/Custom/PureStoragePlugin.pm") or die;
        local $/; <$fh>;
    };
    my ($body) = $src =~ /sub activate_storage\b(.*?)\n    # NOTE: orphaned temp-clone/s;
    $body //= '';
    check('  失敗路徑會查詢離線狀態', ($body =~ /_read_health_state/) ? 'yes' : 'no', 'yes');
    check('  離線後改用短訊息', ($body =~ /is unreachable/) ? 'yes' : 'no', 'yes');
    check('  短訊息指向 OUTAGE 記錄', ($body =~ /OUTAGE record/) ? 'yes' : 'no', 'yes');
    check('  首次失敗仍帶陣列原始回答',
        ($body =~ /Cannot connect to Pure Storage array at .*\$err/) ? 'yes' : 'no', 'yes');
}

# ---- A23, A26, A33: a resize must reach this node's device ---------------
print "\nA23/A26/A33 a resize reaches the local device, and activation reconciles\n";
{
    my $src = do {
        open(my $fh, '<', "$FindBin::Bin/../lib/PVE/Storage/Custom/PureStoragePlugin.pm") or die;
        local $/; <$fh>;
    };
    my ($resize) = $src =~ /\nsub volume_resize\b(.*?)\nsub /s;
    $resize //= '';
    # PVE::API2::LXC always passes $running = 0, so anything gated on it never
    # runs for a container -- which is how container resize never worked.
    check('  本機刷新不再被 $running 把關',
        ($resize =~ /if\s*\(\s*\$running\s*\)/) ? 'STILL GATED' : 'ungated', 'ungated');
    check('  resize 之後會刷新本機容量',
        ($resize =~ /_refresh_local_capacity/) ? 'yes' : 'no', 'yes');

    my ($activate) = $src =~ /\nsub activate_volume\b(.*?)\nsub /s;
    $activate //= '';
    check('  activate_volume 會調和容量',
        ($activate =~ /_refresh_local_capacity|getsize64/) ? 'yes' : 'no', 'yes');
    check('  activate_volume 會追蹤 WWID',
        ($activate =~ /_track_wwid/) ? 'yes' : 'no', 'yes');
}

# ---- A16 fail-closed: an unknown age must not authorise a delete --------
print "\nA16 an unknown created timestamp must not authorise a delete\n";
{
    my $src = do {
        open(my $fh, '<', "$FindBin::Bin/../lib/PVE/Storage/Custom/PureStoragePlugin.pm") or die;
        local $/; <$fh>;
    };
    my ($reaper) = $src =~ /\nsub _cleanup_orphaned_temp_clones\b(.*?)\nsub /s;
    $reaper //= '';
    check('  回收器對未知年齡直接跳過',
        ($reaper =~ /next unless \$created/) ? 'yes' : 'no', 'yes');
    check('  且需要兩個獨立的年齡來源都成立',
        ($reaper =~ /\$age_seconds\s*>\s*\$min_age\s*&&\s*\$age_from_name\s*>\s*\$min_age/) ? 'yes' : 'no', 'yes');
}

# ---- A29: the message when a device does not appear ---------------------
print "\nA29 a device that never appeared has to say what to do\n";
{
    my $found = 0;
    my $actionable = 0;
    for my $f (glob("$FindBin::Bin/../lib/PVE/Storage/Custom/PureStoragePlugin.pm"),
               glob("$FindBin::Bin/../lib/PVE/Storage/Custom/PureStorage/*.pm")) {
        open(my $fh, '<', $f) or next;
        # Comments about these messages are not these messages -- the first
        # version of this check counted the two in Multipath.pm that describe
        # the wording, and reported a gap that was not there.
        my @lines = <$fh>;
        close($fh);
        for my $i (0 .. $#lines) {
            next if $lines[$i] =~ /^\s*#/;
            next unless $lines[$i] =~ /did not (?:appear|surface)/;
            # Wide enough to cover a diagnostic block built up over several
            # appends: the largest of these accumulates protocol, host,
            # connection state and a "Try:" line across about twenty lines.
            my $window = join('', @lines[$i .. ($i + 25 > $#lines ? $#lines : $i + 25)]);
            $found++;
            # Architectural Rule 8: an error says WHAT, WHY and HOW. What is
            # asserted here is the HOW -- a command to run, a file to read, or
            # a setting to change.
            #
            # Written without /x deliberately: under /x the space in
            # 'multipath -ll' is ignored, and an earlier version of this line
            # silently stopped matching it. And the timeout options contain a
            # hyphen, which \w does not cover.
            $actionable++ if $window =~
                m{\bCheck:|\bTry:|multipath -ll|multipathd|iscsiadm|systemctl|pure-[\w-]+-timeout|/sys/class/};
        }
    }
    check('  這類訊息存在', $found ? 'yes' : 'no', 'yes');
    check('  每一則都給得出下一步',
        ($found && $actionable == $found) ? 'all' : "$actionable/$found", 'all');
}

# ---- A7: a wait loop that probes last gives the caller one attempt ------
print "\nA7 the wait loop probes before it does expensive work\n";
{
    my $src = do {
        open(my $fh, '<', "$FindBin::Bin/../lib/PVE/Storage/Custom/PureStorage/Multipath.pm") or die;
        local $/; <$fh>;
    };
    my ($wait) = $src =~ /\nsub wait_for_multipath_device\b(.*?)\nsub /s;
    $wait //= '';
    check('  函式存在', length($wait) ? 'yes' : 'no', 'yes');
    # The defect: reconfigure, trigger and settle all ran before the first
    # look, so on a degraded fabric one pass could consume the whole budget.
    my ($probe_at)  = $wait =~ /^(.*?)(?:get_multipath_device|get_device_by_wwid)/s;
    my ($expensive) = $wait =~ /^(.*?)(?:multipath_reload|_udev_refresh|rescan_)/s;
    check('  第一次探測早於第一次昂貴操作',
        (defined $probe_at && defined $expensive && length($probe_at) < length($expensive))
            ? 'probe first' : 'EXPENSIVE FIRST', 'probe first');
    check('  每一步之後都會重新檢查截止時間',
        (($wait =~ /deadline|time\(\)\s*[<>]/) ? 'yes' : 'no'), 'yes');
}

# ---- A25: a container backup must not leak its snapshot-access clone ----
print "\nA25 the snapshot-access clone is released on a path PVE reaches\n";
{
    my $src = do {
        open(my $fh, '<', "$FindBin::Bin/../lib/PVE/Storage/Custom/PureStoragePlugin.pm") or die;
        local $/; <$fh>;
    };
    my ($del) = $src =~ /\nsub volume_snapshot_delete\b(.*?)\nsub /s;
    $del //= '';
    # PVE::VZDump::LXC never calls deactivate_volume, so the release cannot
    # hang off one. It hangs off volume_snapshot_delete, which PVE does call.
    check('  volume_snapshot_delete 會觸發暫存複製清理',
        ($del =~ /_sweep_temp_snap_clones/) ? 'yes' : 'no', 'yes');
    check('  背景回收器仍是後備',
        ($src =~ /_cleanup_orphaned_temp_clones/) ? 'yes' : 'no', 'yes');
}

# ---- A30: the postinst must not report another vendor as a Pure hazard --
print "\nA30 postinst hazard detection is scope-aware\n";
{
    my $src = do {
        open(my $fh, '<', "$FindBin::Bin/../debian/postinst") or die;
        local $/; <$fh>;
    };
    check('  能區分 defaults 與 device 區塊',
        ($src =~ /defaults/ && $src =~ /device:/) ? 'yes' : 'no', 'yes');
    check('  其他廠商的區塊只是提示而非危險',
        ($src =~ /scoped to/) ? 'yes' : 'no', 'yes');
    check('  仍會把 defaults 裡的設定視為危險',
        ($src =~ /in the .defaults. section/) ? 'yes' : 'no', 'yes');
}

printf "\n%d passed, %d failed\n", $pass, $fail;
exit($fail ? 1 : 0);
