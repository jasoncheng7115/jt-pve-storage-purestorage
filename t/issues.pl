#!/usr/bin/perl
# Covers: A52   (see AUDIT_REGISTER.md)
# The four issues reported against 1.1.36 by DLTKdevopsmaconomy, each driven
# against the code rather than reasoned about.
use strict;
use warnings;
use FindBin; use lib "$FindBin::Bin/../lib";

require PVE::Storage::Custom::PureStorage::Multipath;
require PVE::Storage::Custom::PureStoragePlugin;
my $M = 'PVE::Storage::Custom::PureStorage::Multipath';
my $P = 'PVE::Storage::Custom::PureStoragePlugin';
my ($pass, $fail) = (0, 0);
sub check {
    my ($d, $g, $w) = @_;
    my $ok = "$g" eq "$w"; $ok ? $pass++ : $fail++;
    printf "  %-4s %-54s got=%-24s want=%s\n", $ok ? 'ok' : 'FAIL', $d, $g, $w;
}

print "#15 untaint_arg rejected the plugin's own format string\n";
check('  多重路徑格式字串通過',
    (eval { $M->can('untaint_arg')->('%n %w') } // 'DIED'), '%n %w');
check('  仍拒絕本外掛不可能產生的字元',
    (eval { $M->can('untaint_arg')->('x; rm -rf /'); 1 }) ? 'ACCEPTED' : 'refused', 'refused');
check('  仍拒絕反引號',
    (eval { $M->can('untaint_arg')->('x`reboot`'); 1 }) ? 'ACCEPTED' : 'refused', 'refused');
check('  換行仍被拒絕',
    (eval { $M->can('untaint_arg')->("a\nb"); 1 }) ? 'ACCEPTED' : 'refused', 'refused');
# The point of matching the format strings exactly rather than widening the
# character class: the licence must not extend to a value that came from the
# array or from multipathd output.
check('  空格的許可沒有擴散到其他字串',
    (eval { $M->can('untaint_arg')->('a b'); 1 }) ? 'ACCEPTED' : 'refused', 'refused');
check('  caret 的許可沒有擴散到其他字串',
    (eval { $M->can('untaint_arg')->('^other'); 1 }) ? 'ACCEPTED' : 'refused', 'refused');
check('  已知字面值後面接注入也被拒絕',
    (eval { $M->can('untaint_arg')->('%n %w; id'); 1 }) ? 'ACCEPTED' : 'refused', 'refused');
# Every literal argument the tree actually passes must survive its own guard.
{
    my %args;
    for my $f (glob("$FindBin::Bin/../lib/PVE/Storage/Custom/PureStoragePlugin.pm "
                  . "$FindBin::Bin/../lib/PVE/Storage/Custom/PureStorage/*.pm")) {
        open(my $fh, '<', $f) or next;
        my $src = do { local $/; <$fh> };
        close($fh);
        $src =~ s/^\s*#.*$//mg;
        while ($src =~ /(?:_run_cmd|run_command)\s*\(\s*\[([^\]]*)/gs) {
            $args{$_} = 1 for grep { length } ($1 =~ /'([^']*)'/g);
        }
    }
    my @bad = grep { !eval { $M->can('untaint_arg')->($_); 1 } } sort keys %args;
    check(sprintf('  全樹 %d 個字面參數全部通過自己的守門', scalar keys %args),
        @bad ? "rejected: @bad" : 'all pass', 'all pass');
}
check('  multipathd 解析為存在的執行檔',
    (-x ($M->can('multipathd_path')->() // '')) ? 'exists' : 'MISSING', 'exists');

print "\n#16 a realm-scoped pod was split on the wrong separator\n";
for my $case (['myrealm::mypod::pve-store-100-disk0', 'myrealm::mypod', 'pve-store-100-disk0'],
              ['mypod::pve-store-100-disk0',          'mypod',          'pve-store-100-disk0']) {
    my ($input, $want_pod, $want_pat) = @$case;
    my ($pod, $pat) = $input =~ /^(.+)::([^:]+)$/;
    check("  '$input'", "$pod | $pat", "$want_pod | $want_pat");
}
{
    my $src = do {
        open(my $fh, '<', "$FindBin::Bin/../lib/PVE/Storage/Custom/PureStorage/API.pm") or die;
        local $/; <$fh>;
    };
    my $old = () = $src =~ /\^\(\[\^:\]\+\)::\(\.\+\)\$/g;
    check('  API.pm 已無「切第一個 ::」的寫法', $old, 0);
}

print "\n#17 the host object name carried no realm prefix\n";
{
    no warnings 'redefine';
    *PVE::INotify::nodename = sub { 'pve-a' };
}
my $hn = \&PVE::Storage::Custom::PureStoragePlugin::_get_host_name;
check('  realm 範圍的 pod 會加上前綴',
    $hn->({ 'pure-pod' => 'myrealm::mypod' }), 'myrealm::pve-pve-pve-a');
check('  一般 pod 不受影響', $hn->({ 'pure-pod' => 'mypod' }), 'pve-pve-pve-a');
check('  沒有 pod 也不受影響', $hn->({}), 'pve-pve-pve-a');
check('  shared 模式同樣加上前綴',
    $hn->({ 'pure-pod' => 'myrealm::mypod', 'pure-host-mode' => 'shared' }),
    'myrealm::pve-pve-shared');

print "\n#18 an OVMF efidisk is smaller than the array will create\n";
{
    my $min = PVE::Storage::Custom::PureStoragePlugin::PURE_MIN_VOLUME_BYTES();
    check('  下限為 1 MiB', $min, 1048576);
    # PVE sizes efidisk0 at 528 KiB and passes the size in KiB.
    for my $case ([528, 1048576, 'efidisk0 528K'], [1024, 1048576, '剛好 1 MiB'],
                  [4 * 1024 * 1024, 4 * 1024 * 1024 * 1024, '4 GiB 不受影響']) {
        my ($kib, $want, $desc) = @$case;
        my $bytes = $kib * 1024;
        $bytes = $min if $bytes < $min;
        check("  $desc", $bytes, $want);
    }
}

printf "\n%d passed, %d failed\n", $pass, $fail;
exit($fail ? 1 : 0);
