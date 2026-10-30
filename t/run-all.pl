#!/usr/bin/perl
# Run every behaviour test in t/ and report one line each.
#
# These are not unit tests of functions. Each one reproduces a defect this
# plugin actually shipped, so a failure here means a specific bug is back --
# see AUDIT_REGISTER.md for which. They live in the repository rather than in
# somebody's scratch directory so that they run on every change, are reviewed
# with the code they guard, and can be run by anyone.
#
# Three of them must run under taint mode: pvedaemon and pveproxy are
# #!/usr/bin/perl -T, and a test that does not use the same shebang cannot see
# that class of defect at all. The shebang is the fixture.
use strict;
use warnings;
use FindBin;

my %NEEDS_TAINT = map { $_ => 1 } qw(taint.pl daemonenv.pl sysfstaint.pl);

# Every suite asserts. A suite that cannot produce its condition on this
# machine says SKIP in its own output and exits 0 -- see failopen3.pl, whose
# property is proven by injection in failclosed.pl instead.
my %DEMONSTRATION;

my @files = sort grep { !m{/run-all\.pl$} } glob("$FindBin::Bin/*.pl");
my ($pass, $fail, $skip) = (0, 0, 0);
my @failed;

for my $f (@files) {
    my $name = $f; $name =~ s{.*/}{};
    my @cmd = ('perl');
    push @cmd, '-T' if $NEEDS_TAINT{$name};
    push @cmd, $f;

    my $out = qx{@cmd 2>&1};
    my $rc  = $? >> 8;

    if ($DEMONSTRATION{$name}) {
        printf "  %-16s %s\n", $name, 'ok (demonstration)';
        $skip++;
        next;
    }
    if ($rc == 0) {
        my ($summary) = $out =~ /(\d+ passed, \d+ failed)/;
        printf "  %-16s ok%s\n", $name, $summary ? "  ($summary)" : '';
        $pass++;
    } else {
        printf "  %-16s FAILED (exit %d)\n", $name, $rc;
        for my $l (grep { /FAIL|failed/ } split /\n/, $out) {
            print "        $l\n";
        }
        push @failed, $name;
        $fail++;
    }
}

printf "\n%d suites passed, %d failed, %d demonstrations\n", $pass, $fail, $skip;
print "Failed: @failed\n" if @failed;
exit($fail ? 1 : 0);
