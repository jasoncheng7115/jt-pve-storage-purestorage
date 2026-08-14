#!/usr/bin/perl
# Covers: A50   (see AUDIT_REGISTER.md)
# A REST session is a resource on the array, not a local object. Pure documents
# DELETE /api/1.x/auth/session as "Deletes (invalidates) the REST session", and
# 2.x carries /logout beside /login. Nothing here ever called either, so every
# process that spoke to the array left a session behind: pvestatd rebuilds its
# client when the local TTL expires, a pvedaemon worker runs one task and
# exits, and every pvesm/qm/pct invocation is its own process.
#
# Two traps the sibling project hit, both checked here:
#   * releasing only a session this plugin still considers "valid" -- the one
#     past its TTL is the one that most needs releasing
#   * a forked worker ending its parent's session
# And one the sibling did not have: this plugin seeds a new client with another
# client's token, so a borrower must never log that token out.
use strict;
use warnings;
use FindBin; use lib "$FindBin::Bin/../lib";
use POSIX ();

require PVE::Storage::Custom::PureStorage::API;
my $A = 'PVE::Storage::Custom::PureStorage::API';
my ($pass, $fail) = (0, 0);
sub check {
    my ($d, $g, $w) = @_;
    my $ok = "$g" eq "$w"; $ok ? $pass++ : $fail++;
    printf "  %-4s %-56s got=%-12s want=%s\n", $ok ? 'ok' : 'FAIL', $d, $g, $w;
}

# Record what would go on the wire instead of sending it.
our @released;
my $real_release = \&PVE::Storage::Custom::PureStorage::API::_release_session;
my $stub_release;
{
    no warnings 'redefine';
    $stub_release = sub {
        my ($info) = @_;
        push @released, $info;
        return 1;
    };
    *PVE::Storage::Custom::PureStorage::API::_release_session = $stub_release;
}

sub client {
    my (%o) = @_;
    my $self = bless {
        host => '198.51.100.7', port => 443, api_version => $o{v} // '2.26',
        ssl_verify => 0, _ua => undef,
        _session_token => $o{token},
        _session_owned => $o{owned} // 0,
    }, $A;
    return $self;
}

# 1. A session this client created is released.
@released = ();
my $owner = client(token => 'tok-owned', owned => 1);
$owner->logout();
check('自己建立的工作階段會被釋放', scalar(@released), 1);
check('  釋放時帶對 token', $released[0]{token} // '', 'tok-owned');

# 2. A token borrowed from another client is NOT released -- the owner is
#    still using it.
@released = ();
my $borrower = client(token => 'tok-owned');       # owned => 0
$borrower->logout();
check('借用他人 token 的 client 不會去釋放它', scalar(@released), 0);

# 3. The trap: a session past the plugin's own TTL is still open on the array.
#    logout() must not check any local notion of validity.
@released = ();
my $stale = client(token => 'tok-stale', owned => 1);
$stale->{_session_created} = time() - 86400;
$stale->{_expired} = 1;
$stale->logout();
check('過期（依本機 TTL）的工作階段仍會被釋放', scalar(@released), 1);

# 4. Releasing twice does nothing the second time.
@released = ();
$owner->logout();
check('重複 logout 不會重送', scalar(@released), 0);

# 5. The endpoint differs by API version. Driven through the real
#    _release_session with a user agent that records instead of sending --
#    comparing a string this test built against another string this test built
#    would assert nothing.
{
    package RecordingUA;
    our @sent;
    sub new { bless {}, shift }
    sub request { my ($self, $req) = @_; push @sent, $req;
                  return HTTP::Response->new(200) }
}
require HTTP::Response;
{
    no warnings 'redefine';
    # restore the real implementation for this block
    *PVE::Storage::Custom::PureStorage::API::_release_session = $real_release;
}
for my $case (['2.26', 'POST', '/api/2.26/logout'],
              ['1.17', 'DELETE', '/api/1.17/auth/session']) {
    my ($v, $method, $path) = @$case;
    @RecordingUA::sent = ();
    PVE::Storage::Custom::PureStorage::API::_release_session(
        { host => '198.51.100.7', port => 443, version => $v,
          token => 'tok', ssl => 0 }, RecordingUA->new);
    my $req = $RecordingUA::sent[0];
    check("API $v 用對的 method 與端點",
        $req ? $req->method . ' ' . $req->uri->path : 'NO REQUEST',
        "$method $path");
    check("  且帶上 x-auth-token", $req && $req->header('x-auth-token') || '', 'tok');
}
{
    no warnings 'redefine';
    *PVE::Storage::Custom::PureStorage::API::_release_session = $stub_release;
}

# 6. A forked child must not end its parent's session.
@released = ();
my $keeper = client(token => 'tok-parent', owned => 1);
$keeper->{host} = '198.51.100.7';
PVE::Storage::Custom::PureStorage::API::_register_session($keeper);
my $pid = fork();
if (defined $pid && $pid == 0) {
    # The child inherits the registry; its END block must skip entries whose
    # pid is not its own.
    POSIX::_exit(0);
}
waitpid($pid, 0) if $pid;
check('子行程結束時沒有釋放父行程的工作階段', scalar(@released), 0);

printf "\n%d passed, %d failed\n", $pass, $fail;
exit($fail ? 1 : 0);
