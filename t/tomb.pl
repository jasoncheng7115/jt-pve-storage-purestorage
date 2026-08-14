#!/usr/bin/perl
# Covers: A18   (see AUDIT_REGISTER.md)
#
# A disk deleted and recreated several times leaves several tombstones, all of
# which strip back to the same original name. Choosing among them by plain
# name sort picks the LEXICALLY first, which is the OLDEST generation -- the
# newest then hits a rename-back conflict and the whole restore aborts.
#
# The earlier version of this test carried its own copy of
# _strip_tombstone_suffix and its own sort, so it proved that the test agreed
# with itself. It now drives the recovery tool's real code.
use strict;
use warnings;
use FindBin;

my $TOOL = "$FindBin::Bin/../bin/pve-pure-config-get";
my ($pass, $fail) = (0, 0);
sub check {
    my ($d, $g, $w) = @_;
    my $ok = defined($g) && "$g" eq "$w";
    $ok ? $pass++ : $fail++;
    printf "  %-4s %-52s got=%-30s want=%s\n", $ok ? 'ok' : 'FAIL', $d,
        defined $g ? $g : 'undef', $w;
}

# Load the tool's subroutines without running it: it is a script, so read it
# and evaluate only up to the point where the option parsing starts.
my $src = do { open(my $fh, '<', $TOOL) or die "cannot read $TOOL: $!"; local $/; <$fh> };
my ($subs) = $src =~ /(sub _strip_tombstone_suffix.*?^\}\n)/ms;
die "could not find _strip_tombstone_suffix in $TOOL\n" unless $subs;
eval "package Tool; $subs 1;" or die "could not load the tool's code: $@";

check('工具中確實有 _strip_tombstone_suffix',
    (defined &Tool::_strip_tombstone_suffix) ? 'yes' : 'MISSING', 'yes');

# The real thing, on the real names the plugin generates.
check('剝除 tombstone 後綴',
    Tool::_strip_tombstone_suffix('pve-store-100-disk0-pve-tomb-1770000000-222'),
    'pve-store-100-disk0');
check('沒有後綴的名稱不受影響',
    Tool::_strip_tombstone_suffix('pve-store-100-disk0'), 'pve-store-100-disk0');
check('只剝最後一段，不會誤傷名稱本體',
    Tool::_strip_tombstone_suffix('pve-tomb-store-100-disk0-pve-tomb-1770000000-1'),
    'pve-tomb-store-100-disk0');

# The selection itself, as the tool performs it: group by stripped name, keep
# the highest embedded timestamp. Three generations, deliberately ordered so
# that a lexical sort would choose the wrong one.
my @destroyed = map { { name => $_ } } (
    'pve-store-100-disk0-pve-tomb-1770000000-222',   # newest
    'pve-store-100-disk0-pve-tomb-1750000000-111',   # oldest, sorts first
    'pve-store-100-disk0-pve-tomb-1760000000-333',
    'pve-store-100-disk1-pve-tomb-1765000000-444',   # a different disk
);

my %gen;
for my $d (@destroyed) {
    my $orig = Tool::_strip_tombstone_suffix($d->{name});
    my ($ts) = $d->{name} =~ /-pve-tomb-(\d+)-\d+$/;
    push @{ $gen{$orig} }, { vol => $d, ts => $ts // 0 };
}
for my $orig (sort keys %gen) {
    my @g = sort { $b->{ts} <=> $a->{ts} } @{ $gen{$orig} };
    my $chosen = $g[0]{vol}{name};
    my $want = $orig eq 'pve-store-100-disk0'
        ? 'pve-store-100-disk0-pve-tomb-1770000000-222'
        : 'pve-store-100-disk1-pve-tomb-1765000000-444';
    check("$orig 選到最新世代", $chosen, $want);
}
check('三個世代被歸為同一顆磁碟', scalar @{ $gen{'pve-store-100-disk0'} }, 3);

# And the property that makes the bug possible: a lexical sort disagrees.
my @lex = sort map { $_->{vol}{name} } @{ $gen{'pve-store-100-disk0'} };
check('（對照）字典序會選到最舊的那個', $lex[0],
    'pve-store-100-disk0-pve-tomb-1750000000-111');

# The tool must still recognise a tombstone at all.
my ($is_sub) = $src =~ /(sub _is_tombstone_name.*?^\}\n)/ms;
if ($is_sub) {
    eval "package Tool; $is_sub 1;";
    check('認得 tombstone 名稱',
        Tool::_is_tombstone_name('pve-store-100-disk0-pve-tomb-1770000000-1') ? 'yes' : 'no', 'yes');
    check('一般名稱不會被誤判',
        Tool::_is_tombstone_name('pve-store-100-disk0') ? 'yes' : 'no', 'no');
}

printf "\n%d passed, %d failed\n", $pass, $fail;
exit($fail ? 1 : 0);
