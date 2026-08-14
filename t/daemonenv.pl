# Covers: A48, A49   (see AUDIT_REGISTER.md)
# Drive the plugin in the environment pvedaemon actually has, rather than the
# one a shell provides:
#
#   * taint mode, because pvedaemon and pveproxy are #!/usr/bin/perl -T
#   * no PATH at all, because /proc/<pid>/environ for those daemons has none
#
# The sibling project's checklist opens by saying five of its defects lived in
# code that worked perfectly from `qm` and failed from the interface an
# operator actually uses. This is that environment, without an array.
#
# Run with: perl -T daemonenv.pl
use strict;
use warnings;
use FindBin;
# Under -T the path FindBin derives from $0 is tainted, and `use lib` refuses
# it. A capture untaints; this is the test harness, not the plugin.
my $REPO;
BEGIN { ($REPO) = $FindBin::Bin =~ m{\A(.*)\z}; }
use lib "$REPO/../lib", '/usr/share/perl5';
use Scalar::Util qw(tainted);

# Exactly what a PVE daemon hands its children: no PATH, and none of the shell
# variables taint mode refuses to inherit.
delete @ENV{qw(PATH IFS CDPATH ENV BASH_ENV)};

my ($pass, $fail) = (0, 0);
sub check {
    my ($d, $g, $w) = @_;
    my $ok = "$g" eq "$w"; $ok ? $pass++ : $fail++;
    printf "  %-4s %-54s got=%-22s want=%s\n", $ok ? 'ok' : 'FAIL', $d, $g, $w;
}

check('環境確實沒有 PATH（否則本測試無意義）',
    exists $ENV{PATH} ? "PATH=$ENV{PATH}" : 'none', 'none');
check('確實在 taint mode 下', ${^TAINT} ? 'on' : 'OFF', 'on');

require PVE::Storage::Custom::PureStoragePlugin;
require PVE::Storage::Custom::PureStorage::Multipath;
my $P = 'PVE::Storage::Custom::PureStoragePlugin';
my $M = 'PVE::Storage::Custom::PureStorage::Multipath';

check('外掛可在此環境下載入', $P->can('api') ? 'loaded' : 'FAILED', 'loaded');

# 1. Command resolution. With no PATH, exec falls back to /bin:/usr/bin, and
#    every tool this plugin needs except fuser/sync/udevadm lives in /usr/sbin.
my $udev = eval { $M->can('udevadm_path')->() };
check('udevadm 在無 PATH 環境下仍解析得到', $udev && -x $udev ? 'resolved' : "FAILED: $@", 'resolved');

# 2. A command carrying a value that came off the array, run for real.
my $wwid = do {
    open(my $fh, '<', '/proc/sys/kernel/ostype') or die $!;
    local $/; my $v = <$fh>; close($fh);
    '3624a9370' . unpack('H*', substr($v, 0, 8));
};
check('模擬的陣列回傳值確實 tainted', tainted($wwid) ? 'tainted' : 'NOT TAINTED', 'tainted');

my $out = '';
my $ran = eval {
    my ($stdout) = $M->can('_run_cmd')->(['/bin/echo', "/dev/mapper/$wwid"], timeout => 5);
    $out = $stdout // ''; 1;
};
check('帶陣列值的指令可以執行', $ran ? 'ran' : 'died: ' . (split /\n/, "$@")[0], 'ran');
check('  參數原封不動送達', ($out =~ /\Q$wwid\E/) ? 'intact' : 'MANGLED', 'intact');

# 3. The multipath helpers a delete or a resize would reach, called for real.
for my $fn (qw(list_pure_multipath_devices)) {
    my $r = eval { $M->can($fn)->(); 1 };
    check("$fn 在此環境下可執行", $r ? 'ran' : 'died: ' . (split /\n/, "$@")[0], 'ran');
}

# 4. The plugin methods PVE calls that need no array.
check('api() 回報版本', ($P->api() =~ /^\d+$/) ? 'ok' : 'FAILED', 'ok');
my $ident = eval { $P->get_identity({ 'pure-portal' => 'x' }, 'st') };
check('get_identity 可執行', (defined $ident) ? 'ok' : "died: $@", 'ok');
my $parsed = eval { [ $P->parse_volname('vm-100-disk-0') ] };
check('parse_volname 可執行', ($parsed && @$parsed) ? 'ok' : "died: $@", 'ok');

# 5. The one that must refuse rather than run.
my $refused = eval { $M->can('untaint_arg')->('/dev/mapper/x`reboot`'); 1 } ? 'ACCEPTED' : 'refused';
check('可疑參數在此環境下仍被拒絕', $refused, 'refused');

printf "\n%d passed, %d failed\n", $pass, $fail;
exit($fail ? 1 : 0);
