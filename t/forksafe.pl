#!/usr/bin/perl
# Covers: A50   (see AUDIT_REGISTER.md)
# The background reaper runs in a grandchild of pvestatd. A forked child
# inherits the parent's %api_cache, and every entry in it holds an
# LWP::UserAgent with a live keep-alive socket. If the child ever issued a
# request through an inherited object, two processes would be writing to and
# reading from the same TCP connection: responses interleave and a reply can
# be handed to the wrong request. That is silent and arbitrarily bad -- a
# volume list answered with someone else's body.
#
# The guard is that cache entries record the pid that built them and are only
# reused by that pid. This proves the guard holds, and that the one thing the
# child DOES touch on an inherited object (get_session_token, to reuse the
# login) performs no I/O.
use strict;
use warnings;
use POSIX ':sys_wait_h';

use FindBin; use lib "$FindBin::Bin/../lib";
require PVE::Storage::Custom::PureStorage::API;
require PVE::Storage::Custom::PureStoragePlugin;

my ($pass, $fail) = (0, 0);
sub check {
    my ($desc, $got, $want) = @_;
    my $ok = "$got" eq "$want";
    $ok ? $pass++ : $fail++;
    printf "  %-4s %-54s got=%-10s want=%s\n", $ok ? 'ok' : 'FAIL', $desc, $got, $want;
}

# get_session_token must be a plain accessor. If it ever grew a lazy login,
# the child would drive it down the inherited socket.
{
    my $src = do {
        open(my $fh, '<', "$FindBin::Bin/../lib/PVE/Storage/"
            . 'Custom/PureStorage/API.pm') or die $!;
        local $/; <$fh>;
    };
    my ($body) = $src =~ /sub get_session_token\s*\{(.*?)^\}/ms;
    check('get_session_token 不做任何 I/O',
        ($body =~ /_request|_login|LWP|->get\b|->post\b/) ? 'does I/O' : 'accessor only',
        'accessor only');
}

# Build a client in the parent, fork, and ask for one in the child.
{
    no warnings 'redefine';
    # Never talk to a real array: stub out construction-time work.
    *PVE::Storage::Custom::PureStorage::API::_detect_api_version = sub { $_[0]->{api_version} = '2.26' };
    *PVE::Storage::Custom::PureStorage::API::_login = sub { $_[0]->{_session_token} = 'tok'; 1 };
    *PVE::Storage::Custom::PureStoragePlugin::_resolve_credentials = sub {
        return (api_token => 'x', username => undef, password => undef);
    };
}

my $scfg = { 'pure-portal' => '198.51.100.7', 'pure-ssl-verify' => 0 };
my $parent_api = PVE::Storage::Custom::PureStoragePlugin::_get_api($scfg, 'st1');
$parent_api->{_session_token} = 'tok';   # as a real poll would leave it
my $parent_addr = 0 + $parent_api;
my $parent_ua   = 0 + ($parent_api->{ua} // $parent_api->{_ua} // 0);

check('父行程拿到 client', ($parent_addr ? 'yes' : 'no'), 'yes');
check('父行程重複呼叫會命中快取',
    ((0 + PVE::Storage::Custom::PureStoragePlugin::_get_api($scfg, 'st1')) == $parent_addr)
        ? 'same' : 'different', 'same');

pipe(my $rd, my $wr) or die "pipe: $!";
my $pid = fork();
die "fork: $!" unless defined $pid;
if ($pid == 0) {
    close($rd);
    my $child_api = PVE::Storage::Custom::PureStoragePlugin::_get_api($scfg, 'st1');
    printf $wr "%d %d %s\n", 0 + $child_api,
        0 + ($child_api->{ua} // $child_api->{_ua} // 0),
        $child_api->get_session_token() // '-';
    close($wr);
    POSIX::_exit(0);
}
close($wr);
my $line = <$rd>;
close($rd);
waitpid($pid, 0);

my ($child_addr, $child_ua, $child_tok) = split ' ', ($line // '0 0 -');

check('子行程沒有沿用父行程的 client 物件',
    ($child_addr && $child_addr != $parent_addr) ? 'fresh' : 'REUSED', 'fresh');
check('測試確實找到了 UserAgent 物件（否則下一項是空過的）',
    ($parent_ua && $child_ua) ? 'found' : 'FIELD NAME WRONG', 'found');
check('子行程沒有沿用父行程的 UserAgent（即 socket）',
    ($child_ua == $parent_ua) ? 'SHARED' : 'separate', 'separate');
printf "       (父 UA=%s 子 UA=%s)\n", $parent_ua, $child_ua;
check('子行程仍沿用了 session token（省下一次 login）', $child_tok, 'tok');

printf "\n%d passed, %d failed\n", $pass, $fail;
exit($fail ? 1 : 0);
