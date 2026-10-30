#!/usr/bin/perl
# Covers: A54   (see AUDIT_REGISTER.md)
# Two cached clients in one process share one array session: the health
# client (activate_storage/status, retry_count 1) and the data client. Since
# 1.1.36 the owner logs its session out when its local TTL expires; the
# replacement health client then seeds itself from the data client -- with the
# token that was just logged out. Its first call gets 401, and the 401 re-login
# lived inside the retry loop (`$attempt < $retry_count`), which a
# single-attempt client never enters. Every activate_storage() on that process
# then failed until something else refreshed the data client: an intermittent
# "Internal Server Error (500)" on the storage content view and "active: no"
# on the storage summary, served by whichever pvedaemon worker was affected.
use strict; use warnings;
our $NOW;
BEGIN { $NOW = 1_800_000_000; *CORE::GLOBAL::time = sub () { $NOW }; }
use FindBin; use lib "$FindBin::Bin/../lib";
use HTTP::Response;
use LWP::UserAgent;

# --- a minimal FlashArray: sessions are real, everything else is canned ---
my %valid;          # token => 1
my $seq = 0;
my ($logins, $logouts, $unauth) = (0, 0, 0);
{
    no warnings 'redefine';
    *LWP::UserAgent::request = sub {
        my ($ua, $req) = @_;
        my $path = $req->uri->path;
        my $r;
        if ($path eq '/api/api_version') {
            $r = HTTP::Response->new(200); $r->content('{"version":["2.26"]}');
        } elsif ($path =~ m{/login$}) {
            $logins++; my $t = 'tok-' . ++$seq; $valid{$t} = 1;
            $r = HTTP::Response->new(200); $r->header('x-auth-token' => $t);
            $r->content('{}');
        } elsif ($path =~ m{/logout$}) {
            $logouts++; delete $valid{ $req->header('x-auth-token') // '' };
            $r = HTTP::Response->new(200); $r->content('{}');
        } elsif ($valid{ $req->header('x-auth-token') // '' }) {
            $r = HTTP::Response->new(200); $r->content('{"items":[{"name":"fa1"}]}');
        } else {
            $unauth++;
            $r = HTTP::Response->new(401, 'Unauthorized');
            $r->content('{"errors":[{"message":"Invalid or expired session."}]}');
        }
        $r->request($req);
        return $r;
    };
}

require PVE::Storage::Custom::PureStoragePlugin;
my $get_api = \&PVE::Storage::Custom::PureStoragePlugin::_get_api;
my $scfg = { 'pure-portal' => '198.51.100.7', 'pure-api-token' => 'fake' };
my $sid  = 'pure-fc';
{ no warnings 'redefine';
  *PVE::Storage::Custom::PureStoragePlugin::_get_secret = sub { undef }; }

my ($pass,$fail)=(0,0);
sub check { my ($d,$g,$w)=@_; my $ok="$g" eq "$w"; $ok?$pass++:$fail++;
    printf "  %-4s %-60s got=%-4s want=%s\n",$ok?'ok':'FAIL',$d,$g,$w; }
sub works { my ($api) = @_; return eval { $api->array_get(); 1 } ? 1 : 0; }

# A pvedaemon worker serving the storage content view: activate_storage()
# (health client) then list_images() (data client).
my $h = $get_api->($scfg, $sid, status => 1);
check('health client works', works($h), 1);
my $d = $get_api->($scfg, $sid);
check('data client works (shares the session)', works($d), 1);

# Past API_CACHE_TTL, the next request rebuilds the health client.
$NOW += 301;
my $h2 = $get_api->($scfg, $sid, status => 1);
check('rebuilt health client works after its TTL', works($h2), 1);
$NOW += 10;
my $h3 = $get_api->($scfg, $sid, status => 1);
check('and keeps working on the next poll', works($h3), 1);
check('data client still works too', works($d), 1);

# Credentials that are actually wrong must still fail, and promptly: the
# re-login is attempted once, not looped.
my $before = $logins;
%valid = ();
{ no warnings 'redefine';
  my $orig = \&LWP::UserAgent::request;
  local *LWP::UserAgent::request = sub {
      my ($ua, $req) = @_;
      if ($req->uri->path =~ m{/login$}) {
          $logins++;
          my $r = HTTP::Response->new(401, 'Unauthorized'); $r->request($req); return $r;
      }
      return $orig->(@_);
  };
  check('bad credentials still fail', works($h3), 0);
}
check('  with exactly one re-login attempt', $logins - $before, 1);

printf "\n%d passed, %d failed\n", $pass, $fail;
exit($fail ? 1 : 0);
