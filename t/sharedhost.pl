#!/usr/bin/perl
# Covers: A44   (see AUDIT_REGISTER.md)
# The temp-clone reaper decides ownership by asking whether the clone is
# connected to a host other than this node's:
#
#     next if grep { ($_->{name} // '') ne $my_host } @$conns;
#
# That guard exists because a temp snapshot clone is connected only to the node
# that created it, and every OTHER node's reaper would otherwise disconnect and
# destroy a clone the creating node is actively reading -- a qemu-img convert
# out of a snapshot, for instance. The creating node is protected by its local
# is_device_in_use(); no other node has a local device to check.
#
# With pure-host-mode = shared, EVERY node's _get_host_name() returns the same
# name, so $my_host matches a clone created anywhere in the cluster. This asks
# whether the guard still holds in that supported configuration.
use strict;
use warnings;

use FindBin; use lib "$FindBin::Bin/../lib";
require PVE::Storage::Custom::PureStoragePlugin;
my $P = 'PVE::Storage::Custom::PureStoragePlugin';

my ($pass, $fail) = (0, 0);

# The name format is <vol>-temp-snap-access-<timestamp>-<pid>. Getting the two
# numbers the wrong way round makes every clone look decades old, so every age
# gate passes and the test proves nothing. Assert the parse before relying on it.
sub parsed_age {
    my ($name, $vol) = @_;
    my ($ts) = $name =~ /^\Q$vol\E-temp-snap-access-(\d+)-(\d+)$/;
    return defined $ts ? time() - $ts : undef;
}
sub check {
    my ($desc, $got, $want) = @_;
    my $ok = "$got" eq "$want";
    $ok ? $pass++ : $fail++;
    printf "  %-4s %-56s got=%-12s want=%s\n", $ok ? 'ok' : 'FAIL', $desc, $got, $want;
}

my @deleted;
{
    package FakeAPI;
    sub new { bless { clone => $_[1], conn_host => $_[2] }, $_[0] }
    sub volume_list {
        my ($self) = @_;
        return [ { name => $self->{clone}, serial => 'DEADBEEF' } ];
    }
    sub volume_get_connections {
        my ($self) = @_;
        return [ { name => $self->{conn_host} } ];
    }
    sub serial_to_wwid       { return undef }   # no local device on this node
    sub volume_get_wwid      { return undef }
    sub volume_disconnect_host { return 1 }
    sub volume_delete        { push @deleted, $_[1]; return 1 }
}

# A clone created by ANOTHER node, two hours ago, still connected.
my $vol   = 'pve-store-100-disk0';
my $clone = "$vol-temp-snap-access-" . (time() - 7200) . "-4242";

{
    my $probe = "$vol-temp-snap-access-" . (time() - 7200) . "-4242";
    my $age = parsed_age($probe, $vol);
    check('測試用的名稱格式正確（否則後面的年齡門檻是空過的）',
        (defined $age && $age > 7000 && $age < 7400) ? 'parses' : 'MALFORMED', 'parses');
}

my $run = sub {
    my (%scfg) = @_;
    @deleted = ();
    my $api = FakeAPI->new($clone, $P->can('_get_host_name')->(\%scfg));
    $P->can('_sweep_temp_snap_clones')->(\%scfg, 'store', $api, $vol);
    return @deleted ? 'DESTROYED' : 'protected';
};

# In per-node mode the other node's host name differs, so the guard holds.
{
    no warnings 'redefine';
    *PVE::INotify::nodename = sub { 'pve-b' };          # we are node B
}
my $api_per_node = FakeAPI->new($clone, 'pve-pve-pve-a');  # clone belongs to node A
@deleted = ();
$P->can('_sweep_temp_snap_clones')->({}, 'store', $api_per_node, $vol);
check('per-node：別的節點建立的 clone 受保護',
    @deleted ? 'DESTROYED' : 'protected', 'protected');

# Same situation, shared host mode: every node reports one host name, so the
# connection looks like our own.
check('shared：別的節點建立的 clone（2 小時前）現在受保護',
    $run->('pure-host-mode' => 'shared'), 'protected');

# The leak still has to be collected eventually: a clone old enough that no
# live operation could still be using it is released even in shared mode.
$clone = "$vol-temp-snap-access-" . (time() - 90000) . "-4242";   # 25 hours
check('shared：超過一天的殘留仍會被回收（不會永久洩漏）',
    $run->('pure-host-mode' => 'shared'), 'DESTROYED');

# per-node mode keeps its fast path: our own clone is still swept at 60s.
$clone = "$vol-temp-snap-access-" . (time() - 300) . "-4242";
{
    my $api = FakeAPI->new($clone, $P->can('_get_host_name')->({}));
    @deleted = ();
    $P->can('_sweep_temp_snap_clones')->({}, 'store', $api, $vol);
    check('per-node：自己的 clone 仍在 60 秒後就被清掉',
        @deleted ? 'DESTROYED' : 'protected', 'DESTROYED');
}

# The caller (path(), on the snapshot-access fast path) asks for 60s. In
# shared mode the code must raise that floor itself -- that IS the fix, so
# assert it against an explicit override rather than the default.
$clone = "$vol-temp-snap-access-" . (time() - 7200) . "-4242";
{
    my %scfg = ('pure-host-mode' => 'shared');
    my $api = FakeAPI->new($clone, $P->can('_get_host_name')->(\%scfg));
    @deleted = ();
    $P->can('_sweep_temp_snap_clones')->(\%scfg, 'store', $api, $vol, min_age => 60);
    check('shared：呼叫端給 60 秒也會被提高到一天',
        @deleted ? 'DESTROYED' : 'protected', 'protected');
}

printf "\n%d passed, %d failed\n", $pass, $fail;
exit($fail ? 1 : 0);
