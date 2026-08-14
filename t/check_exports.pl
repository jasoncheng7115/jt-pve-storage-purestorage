# Covers: O2   (see AUDIT_REGISTER.md)
use strict; use warnings;
use lib 'lib';
use PVE::Storage::Custom::PureStorage::Multipath ();
use PVE::Storage::Custom::PureStorage::ISCSI ();
use PVE::Storage::Custom::PureStorage::FC ();
use PVE::Storage::Custom::PureStorage::Naming ();
use PVE::Storage::Custom::PureStorage::API ();
my $src = do { local(@ARGV,$/) = ("lib/PVE/Storage/Custom/PureStoragePlugin.pm"); <> };
my $bad = 0; my $n = 0;
while ($src =~ /use (PVE::Storage::Custom::PureStorage::\w+) qw\(\s*(.*?)\)\s*;/gs) {
    my ($mod, $list) = ($1, $2);
    for my $f (split(/\s+/, $list)) {
        next unless length $f;
        $n++;
        no strict 'refs';
        unless (grep { $_ eq $f } @{"${mod}::EXPORT_OK"}) { print "MISSING from \@EXPORT_OK: ${mod}::$f\n"; $bad++ }
        unless (defined &{"${mod}::$f"})                  { print "NOT DEFINED: ${mod}::$f\n"; $bad++ }
    }
}
# reverse: dead exports with zero callers anywhere
for my $mod (qw(Multipath ISCSI FC Naming)) {
    my $full = "PVE::Storage::Custom::PureStorage::$mod";
    no strict 'refs';
    for my $f (@{"${full}::EXPORT_OK"}) {
        my $hits = 0;
        for my $file (glob("lib/PVE/Storage/Custom/*.pm lib/PVE/Storage/Custom/PureStorage/*.pm"), 'bin/pve-pure-config-get') {
            my $c = do { local(@ARGV,$/) = ($file); <> };
            $hits++ while $c =~ /\b\Q$f\E\s*\(/g;
        }
        print "DEAD EXPORT (no callers): ${full}::$f\n" if $hits == 0;
    }
}
print $bad ? "FAILED ($bad problems)\n" : "OK: all $n imported symbols exist and are exported\n";
