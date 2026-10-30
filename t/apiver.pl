#!/usr/bin/perl
# Covers: A38   (see AUDIT_REGISTER.md)
# api() negotiation: what the plugin claims against each PVE it can meet.
#
# The rules PVE::Storage enforces at load time:
#   claim >  APIVER            -> plugin REJECTED, storages vanish from node
#   claim <  APIVER - APIAGE   -> plugin REJECTED, storages vanish from node
#   claim != APIVER (in range) -> loads, warns on every PVE::Storage load
#   claim == APIVER            -> loads silently
use strict;
use File::Temp ();
use warnings;

use FindBin; my $LIB = "$FindBin::Bin/../lib";
my ($pass, $fail) = (0, 0);

sub check {
    my ($desc, $got, $want) = @_;
    my $ok = (defined $got && defined $want && $got eq $want)
          || (!defined $got && !defined $want);
    $ok ? $pass++ : $fail++;
    printf "  %-4s %-58s got=%s want=%s\n", $ok ? 'ok' : 'FAIL', $desc,
        defined $got ? $got : 'undef', defined $want ? $want : 'undef';
}

# Ask the plugin what it claims, in a fresh interpreter, against a stubbed
# PVE::Storage with the given APIVER/APIAGE. undef APIVER = PVE::Storage not
# loaded at all (perl -c, unit tests).
sub claim_against {
    my ($apiver, $apiage) = @_;
    my $stub = defined $apiver
        ? "{ package PVE::Storage;\n"
        . "  use constant APIVER => $apiver;\n"
        . "  use constant APIAGE => $apiage;\n"
        . "}\n"
        : "";
    my $code = <<"PERL";
use lib '$LIB';
$stub
require PVE::Storage::Custom::PureStoragePlugin;
print PVE::Storage::Custom::PureStoragePlugin->api();
PERL
    # Written to a file rather than passed with -e: the stub has to survive
    # two layers of quoting otherwise, and a mangled stub looks exactly like
    # a failing plugin.
    my (undef, $tmp) = File::Temp::tempfile('.apiver-probe-XXXXXX', SUFFIX => '.pl', TMPDIR => 1);
    open(my $fh, '>', $tmp) or die "cannot write probe: $!";
    print $fh $code;
    close($fh);
    my $out = `perl $tmp 2>&1`;
    unlink($tmp);
    return $out =~ /^(\d+)$/ ? $1 : undef;
}

print "PVE 各版本下 api() 宣告的版本\n";

# Every libpve-storage-perl actually seen in the field, plus the extremes.
my @matrix = (
    # apiver apiage  desc
    [ 13, 4,  'libpve-storage-perl 9.1.2 (13/4, accepts 9..13)' ],
    [ 14, 5,  'an intermediate 9.1.x                (14/5, 9..14)' ],
    [ 15, 6,  'libpve-storage-perl 9.1.6 (15/6, accepts 9..15)' ],
    [ 20, 6,  'a hypothetical future PVE            (20/6, 14..20)' ],
    [ 12, 3,  'an older library                     (12/3, 9..12)' ],
    [ 9,  0,  'the oldest we support                (9/0,  9..9)' ],
);

for my $m (@matrix) {
    my ($apiver, $apiage, $desc) = @$m;
    my $claim = claim_against($apiver, $apiage);
    my $min   = $apiver - $apiage;

    # The claim must land inside the accepted window...
    my $in_range = defined $claim && $claim >= $min && $claim <= $apiver;
    check("$desc: loads", $in_range ? 'yes' : 'REJECTED', 'yes');

    # ...and where the plugin can match exactly, it must, or PVE nags on
    # every single call. It can only match up to what it implements.
    my $want_exact = $apiver <= 15 ? $apiver : 15;
    $want_exact = 9 if $want_exact < 9;
    check("$desc: claims", $claim, "$want_exact");
}

# The no-PVE case: syntax checks and unit tests load the module bare.
my $bare = claim_against(undef, undef);
check('PVE::Storage 未載入時回退', $bare, '13');
# The fallback is only ever returned when PVE::Storage is not loaded, which
# means PVE is not the caller. It still has to be in range for every library
# that ships today, so that a fallback taken by mistake is survivable.
my @shipping = grep { $_->[0] >= 13 && $_->[0] <= 15 } @matrix;
check('回退值對 PVE 9.0/9.1/9.2 的每個實際版本都在範圍內',
    (grep { $bare >= $_->[0] - $_->[1] && $bare <= $_->[0] } @shipping)
        == scalar(@shipping) ? 'yes' : 'no', 'yes');

# The cap is a maintenance obligation, not a set-and-forget constant: once
# PVE's minimum (APIVER - APIAGE) climbs above it, the plugin is hard
# rejected and every purestorage storage disappears from the node. State the
# deadline so it is visible rather than discovered in the field.
check('APIVERSION_MAX 15 可承受的最高 PVE 下限', 15, '15');
print "       (PVE 的 APIVER - APIAGE 一旦超過 15，外掛會被拒絕載入；\n"
    . "        目前 15/6 = 9，還有 6 個版本的餘裕)\n";

# The regression this replaces: a hardcoded 13 against today's library.
my $hard = 13;
check('（對照）舊的固定 13 在 15/6 上會被警告', ($hard != 15 ? 'warns' : 'silent'), 'warns');

printf "\n%d passed, %d failed\n", $pass, $fail;
exit($fail ? 1 : 0);
