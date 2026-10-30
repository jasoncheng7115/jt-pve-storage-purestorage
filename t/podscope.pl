#!/usr/bin/perl
# Covers: A55   (see AUDIT_REGISTER.md)
# A pod without a quota_limit used to be reported as the whole array -- total
# capacity and every other host's data -- so a storage scoped to a pod could
# not show what the pod itself used. pure-pod-capacity = pod reports the
# pod's own usage against the array's free space; 'array' (the default) keeps
# the old figures, and a pod WITH a quota is unaffected by either setting.
use strict; use warnings;
use FindBin; use lib "$FindBin::Bin/../lib";
require PVE::Storage::Custom::PureStorage::API;
my $A = 'PVE::Storage::Custom::PureStorage::API';
my ($pass,$fail)=(0,0);
sub check { my ($d,$g,$w)=@_; my $ok="$g" eq "$w"; $ok?$pass++:$fail++;
    printf "  %-4s %-58s got=%-8s want=%s\n",$ok?'ok':'FAIL',$d,$g,$w; }

my $T = 1024**4;
my $quota = 0;
{ no warnings "redefine"; no strict "refs";
  *{"${A}::pod_get"} = sub { { items => [ { name => 'PVE-Pod',
        space => { total_provisioned => 2*$T, virtual => 1*$T, total_physical => 0.5*$T } } ] } };
  *{"${A}::pod_get_quota_limit"} = sub { $quota };
  *{"${A}::array_space"} = sub { { items => [ { capacity => 25*$T,
        space => { total_used => 13*$T } } ] } };
}
my $api = bless { _api_major => 2, api_version => '2.26' }, $A;
sub cap { my %o = @_; my $c = $api->get_managed_capacity('PVE-Pod', %o);
          return map { $c->{$_} / $T } qw(total used available); }

my @c = cap();
check('default: no quota -> whole array total', $c[0], 25);
check('default: no quota -> whole array used',  $c[1], 13);

@c = cap(no_quota_scope => 'array');
check("'array' is the same as the default", "$c[0]/$c[1]", '25/13');

@c = cap(no_quota_scope => 'pod');
check("'pod': used is the pod's provisioned size", $c[1], 2);
check("'pod': available is the array's free space", $c[2], 12);
check("'pod': total = used + available", $c[0], 14);

@c = cap(no_quota_scope => 'pod', usage_metric => 'virtual');
check("'pod' honours pure-pod-usage-metric", $c[1], 1);

$quota = 5*$T;
@c = cap(no_quota_scope => 'pod');
check('pod WITH quota: total is the quota, either mode', $c[0], 5);
@c = cap(no_quota_scope => 'array');
check('  (and the same in array mode)', $c[0], 5);

printf "\n%d passed, %d failed\n", $pass, $fail;
exit($fail ? 1 : 0);
