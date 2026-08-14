# Covers: A6, A24   (see AUDIT_REGISTER.md)
use strict; use warnings; use lib 'lib';
use PVE::Storage::Custom::PureStorage::Multipath qw(sysfs_read_with_timeout);
my $fail = 0;
# 模擬「呼叫端已經設好 alarm」，確認我們的逾時輔助函式不會把它取消
eval {
    local $SIG{ALRM} = sub { die "outer-alarm-fired\n" };
    alarm(3);
    my $c = sysfs_read_with_timeout('/proc/mounts', 5);
    die "read failed\n" unless defined $c;
    my $left = alarm(0);
    print "  呼叫 sysfs_read_with_timeout 後，外層 alarm 剩餘: ${left}s\n";
    $fail++ unless $left > 0;
    alarm(0);
};
print "  ", $fail ? "FAIL 外層 alarm 被取消了\n" : "ok   外層 alarm 保留下來\n";
exit($fail?1:0);
