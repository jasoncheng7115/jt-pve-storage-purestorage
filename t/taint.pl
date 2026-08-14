# Covers: A49   (see AUDIT_REGISTER.md)
# pvedaemon and pveproxy are #!/usr/bin/perl -T. Under taint mode Perl refuses
# to exec with a value that came from a file, a socket or another command's
# output -- "Insecure dependency in exec while running with -T switch" -- and
# PVE::Tools::run_command does not untaint for us. A device path built from a
# WWID the array returned is exactly such a value, so an operation succeeds
# from `pvesm` on a shell and fails from the web interface.
#
# Run with: perl -T taint.pl
use strict;
use warnings;
use FindBin;
# Under -T the path FindBin derives from $0 is tainted, and `use lib` refuses
# it. A capture untaints; this is the test harness, not the plugin.
my $REPO;
BEGIN { ($REPO) = $FindBin::Bin =~ m{\A(.*)\z}; }
use lib "$REPO/../lib", '/usr/share/perl5';
use Scalar::Util qw(tainted);

$ENV{PATH} = '/usr/sbin:/usr/bin:/sbin:/bin';
delete @ENV{qw(IFS CDPATH ENV BASH_ENV)};

require PVE::Storage::Custom::PureStorage::Multipath;
my $M = 'PVE::Storage::Custom::PureStorage::Multipath';
my ($pass, $fail) = (0, 0);
sub check {
    my ($d, $g, $w) = @_;
    my $ok = "$g" eq "$w"; $ok ? $pass++ : $fail++;
    printf "  %-4s %-52s got=%-14s want=%s\n", $ok ? 'ok' : 'FAIL', $d, $g, $w;
}

# A value with the taint of one read off the network, shaped like a real WWID.
my $wwid = do {
    open(my $fh, '<', '/proc/sys/kernel/ostype') or die $!;
    local $/; my $v = <$fh>; close($fh);
    '3624a9370' . unpack('H*', substr($v, 0, 8));
};
check('模擬的 WWID 確實是 tainted（否則本測試無意義）',
    tainted($wwid) ? 'tainted' : 'NOT TAINTED', 'tainted');

# 1. the untainter itself
my $clean = $M->can('untaint_arg')->("/dev/mapper/$wwid");
check('untaint_arg 回傳的值不再 tainted', tainted($clean) ? 'tainted' : 'clean', 'clean');
check('untaint_arg 不會改動內容', $clean, "/dev/mapper/$wwid");
check('untaint_arg 拒絕本外掛不可能產生的字元',
    (eval { $M->can('untaint_arg')->("/dev/mapper/x; rm -rf /"); 1 }) ? 'ACCEPTED' : 'refused',
    'refused');

# 2. the real command runner, with a tainted argument, under -T
my $out = '';
my $ok = eval {
    # _run_cmd returns ($stdout, $stderr, $exit_code) in list context.
    my ($stdout, $stderr, $rc) = $M->can('_run_cmd')->(
        ['/bin/echo', "/dev/mapper/$wwid"], timeout => 5);
    $out = $stdout // ''; 1;
};
my $err = $@ ? (split /\n/, "$@")[0] : '';
check('_run_cmd 帶 tainted 參數可以執行', $ok ? 'ran' : "died: $err", 'ran');
check('  且參數原封不動送達', ($out =~ /\Q$wwid\E/) ? 'intact' : 'MANGLED', 'intact');

# 3. the path that never existed
my $udev = $M->can('udevadm_path')->();
check('udevadm_path 解析到存在的執行檔', (-x $udev) ? 'exists' : "missing ($udev)", 'exists');
printf "       (解析結果: %s)\n", $udev;

printf "\n%d passed, %d failed\n", $pass, $fail;
exit($fail ? 1 : 0);
