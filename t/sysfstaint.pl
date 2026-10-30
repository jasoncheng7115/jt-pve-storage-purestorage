#!/usr/bin/perl -T
# Covers: A52   (see AUDIT_REGISTER.md)
# pvedaemon is `perl -T`. A sysfs path built from readdir() is tainted, and
# open('>') on it died inside the forked child's eval -- exit 1, no message.
# The SCSI host scan is the only way FC discovers a newly mapped LUN, so a VM
# started from the web interface waited for a device nobody scanned for.
use strict; use warnings;
use FindBin;
BEGIN { my ($d) = $FindBin::Bin =~ /^(.*)$/; unshift @INC, "$d/../lib"; }
use File::Temp qw(tempdir);
use Scalar::Util qw(tainted);
use PVE::Storage::Custom::PureStorage::Multipath qw(sysfs_write_with_timeout);
$ENV{PATH} = '/usr/bin:/bin';
my ($pass,$fail)=(0,0);
sub check { my ($d,$g,$w)=@_; my $ok="$g" eq "$w"; $ok?$pass++:$fail++;
    printf "  %-4s %-58s got=%-4s want=%s\n",$ok?'ok':'FAIL',$d,$g,$w; }

# Every path this suite writes, allowed or refused, lives under one scratch
# directory. The refusal cases must not name a real file: against a helper
# that has lost its check, "refused" means "written".
my ($scratch) = tempdir(CLEANUP => 1) =~ /^(.*)$/;
my $root = "$scratch/sys";
mkdir $root or die $!;
$PVE::Storage::Custom::PureStorage::Multipath::SYSFS_ROOT = $root;
mkdir "$root/host7" or die $!;
my $outside = "$scratch/outside";
{ open my $fh, '>', $outside or die $!; close $fh }
my $scan = "$root/host7/scan";
{ open my $fh, '>', $scan or die $!; close $fh }

opendir(my $dh, $root) or die $!;
my ($h) = grep { /^host\d+$/ } readdir($dh);      # matched, NOT captured
my $p = "$root/$h/scan";
check('test premise: readdir-built path is tainted', tainted($p) ? 1 : 0, 1);

check('write through a tainted path succeeds under -T',
    sysfs_write_with_timeout($p, "- - -\n", 5) ? 1 : 0, 1);
my $c = do { open my $fh, '<', $scan or die $!; local $/; <$fh> // '' };
check('the scan string actually reached the file', $c eq "- - -\n" ? 1 : 0, 1);

{
    local $SIG{__WARN__} = sub {};
    check('a path outside the sysfs root is refused',
        sysfs_write_with_timeout($outside, "x\n", 5) ? 1 : 0, 0);
    check('a parent-directory component is refused',
        sysfs_write_with_timeout("$root/host7/../host7/scan", "x\n", 5) ? 1 : 0, 0);
}

printf "\n%d passed, %d failed\n", $pass, $fail;
exit($fail ? 1 : 0);
