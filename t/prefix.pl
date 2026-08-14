#!/usr/bin/perl
# Covers: A42   (see AUDIT_REGISTER.md)
# storeid_to_pure_prefix() is not injective: it deletes characters Pure will
# not take (a dot vanishes) and then maps '-' to '_'. PVE storage ids may
# contain '-', '_' and '.', so distinct storages can produce one prefix -- and
# that prefix is the ONLY thing scoping ownership of array objects.
use strict;
use warnings;

use FindBin; use lib "$FindBin::Bin/../lib";
use PVE::Storage::Custom::PureStorage::Naming qw(storeid_to_pure_prefix encode_volume_name);
require PVE::Storage::Custom::PureStoragePlugin;

my ($pass, $fail) = (0, 0);
sub check {
    my ($desc, $got, $want) = @_;
    my $ok = "$got" eq "$want";
    $ok ? $pass++ : $fail++;
    printf "  %-4s %-56s got=%-22s want=%s\n", $ok ? 'ok' : 'FAIL', $desc, $got, $want;
}

print "1) 轉換不是單射（這是問題的根源，不是我們要改的東西）\n";
my %by_prefix;
for my $id (qw(pure-prod pure_prod pure.prod pureprod pure-p.rod pure-1 pure_1)) {
    push @{ $by_prefix{ storeid_to_pure_prefix($id) } }, $id;
}
my @collisions = grep { @{ $by_prefix{$_} } > 1 } sort keys %by_prefix;
check('存在多個 storage id 對應到同一前綴', scalar(@collisions) > 0 ? 'yes' : 'no', 'yes');
for my $p (@collisions) {
    printf "       %-12s <- %s\n", $p, join(', ', @{ $by_prefix{$p} });
}
check('且產生的 Volume 名完全相同',
    encode_volume_name('pure-prod', 100, 0) eq encode_volume_name('pure_prod', 100, 0)
        ? 'identical' : 'different', 'identical');

print "\n2) 新增衝突的 storage 會被拒絕\n";
my $CFG = { ids => {} };
{
    no warnings 'redefine';
    *PVE::Storage::config = sub { return $CFG };
    # Keep the credential side-effects out of the way.
    *PVE::Storage::Custom::PureStoragePlugin::_set_secret    = sub { 1 };
    *PVE::Storage::Custom::PureStoragePlugin::_delete_secret = sub { 1 };
}

my $array = '198.51.100.7';
$CFG->{ids}{'pure-prod'} = { type => 'purestorage', 'pure-portal' => $array };

my $try = sub {
    my ($id, %scfg) = @_;
    $scfg{'pure-portal'} //= $array;
    eval { PVE::Storage::Custom::PureStoragePlugin->on_add_hook($id, \%scfg); };
    return $@ ? 'refused' : 'accepted';
};

check("同一陣列上新增 'pure_prod'（與 pure-prod 衝突）", $try->('pure_prod'), 'refused');
check("同一陣列上新增 'pure-p.rod'（同樣衝突）",         $try->('pure-p.rod'), 'refused');
check("同一陣列上新增 'pure-test'（不衝突）",            $try->('pure-test'), 'accepted');
check('不同陣列上的同名 storage 可以接受',
    $try->('pure_prod', 'pure-portal' => '203.0.113.9'), 'accepted');

$CFG->{ids}{'pure-prod'}{'pure-pod'} = 'podA';
check('同陣列但不同 pod 可以接受',
    $try->('pure_prod', 'pure-pod' => 'podB'), 'accepted');
check('同陣列且同 pod 仍然拒絕',
    $try->('pure_prod', 'pure-pod' => 'podA'), 'refused');
delete $CFG->{ids}{'pure-prod'}{'pure-pod'};

check('重新加入自己不會與自己衝突', $try->('pure-prod'), 'accepted');

print "\n3) 既有的衝突組合仍然可以編輯（更新只警告，不阻擋）\n";
$CFG->{ids}{'pure_prod'} = { type => 'purestorage', 'pure-portal' => $array };
my $warned = '';
{
    local $SIG{__WARN__} = sub { $warned .= $_[0] };
    my $ok = eval {
        PVE::Storage::Custom::PureStoragePlugin->on_update_hook_full(
            'pure_prod', { 'pure-portal' => $array }, {}, {}, {});
        1;
    };
    check('更新既有的衝突 storage 不會失敗', $ok ? 'succeeded' : 'DIED', 'succeeded');
}
check('但有警告', ($warned =~ /same Pure volume names/) ? 'warned' : 'silent', 'warned');

print "\n4) 非 purestorage 型別的 storage 不列入比對\n";
%{ $CFG->{ids} } = ('pure-prod' => { type => 'lvm' });
check("同名的 lvm storage 不影響", $try->('pure_prod'), 'accepted');

printf "\n%d passed, %d failed\n", $pass, $fail;
exit($fail ? 1 : 0);
