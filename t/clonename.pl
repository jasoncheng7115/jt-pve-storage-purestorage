#!/usr/bin/perl
# Covers: A45   (see AUDIT_REGISTER.md)
# Pure rejects a volume name over 63 characters outright -- it does not
# truncate. Its own words: "Volume name must be between 1 and 63 characters
# (alphanumeric, '_' and '-') in length and begin and end with a letter or
# number." The snapshot-access clone name is a volume name plus a suffix, and
# nothing used to check the total.
use strict; use warnings;
use FindBin; use lib "$FindBin::Bin/../lib";
use PVE::Storage::Custom::PureStorage::Naming qw(encode_volume_name);
require PVE::Storage::Custom::PureStoragePlugin;
my $P = 'PVE::Storage::Custom::PureStoragePlugin';
my ($pass,$fail)=(0,0);
sub check { my ($d,$g,$w)=@_; my $ok="$g" eq "$w"; $ok?$pass++:$fail++;
    printf "  %-4s %-56s got=%-10s want=%s\n",$ok?'ok':'FAIL',$d,$g,$w; }

print "1) 名稱長度：新字尾讓實際會用到的 storeid 全部進入上限內\n";
for my $sid (qw(pure1 purestorage pure-prod-array1 pure-storage-cluster01)) {
    my $v = encode_volume_name($sid, 999999, 9);
    my $new = length($v) + length("-tsa-1770000000-1234567");
    my $old = length($v) + length("-temp-snap-access-1770000000-1234567");
    check("storeid '$sid' (舊 $old)", $new <= 63 ? 'fits' : "$new over", 'fits');
}
check('24 字元的 storeid 仍超標（會被明確拒絕，不是默默失敗）',
    length(encode_volume_name('a'x24, 999999, 9)) + 23 > 63 ? 'over' : 'fits', 'over');

print "\n2) 兩個回收器都要認得舊名稱，否則升級後既有的 clone 永遠洩漏\n";
# The package lives at file scope on purpose. Declared inside the loop, its
# named subs compile once and keep closing over the FIRST iteration's `my`
# array, so the second case silently records nothing and looks like a miss.
{
    package FakeAPI;
    our @deleted;
    our $name;
    sub new { bless {}, $_[0] }
    sub volume_list {
        my ($self, $pat) = @_;
        my $re = quotemeta($pat); $re =~ s/\\\*/.*/g;   # emulate the array glob
        return [ grep { $_->{name} =~ /^$re$/ } ({ name => $name, serial => 'X' }) ];
    }
    sub volume_get_connections { [ { name => 'pve-pve-pve-a' } ] }
    sub serial_to_wwid         { undef }
    sub volume_get_wwid        { undef }
    sub volume_disconnect_host { 1 }
    sub volume_delete          { push @deleted, $_[1]; 1 }
}
my $vol = 'pve-store-100-disk0';
{
    no warnings 'redefine';
    *PVE::INotify::nodename = sub { 'pve-a' };
}
for my $marker ('tsa', 'temp-snap-access') {
    $FakeAPI::name = "$vol-$marker-" . (time() - 7200) . "-4242";
    @FakeAPI::deleted = ();
    $P->can('_sweep_temp_snap_clones')->({}, 'store', FakeAPI->new, $vol);
    check("sweep 認得 '-$marker-' 形式並回收",
        @FakeAPI::deleted ? 'reaped' : 'MISSED', 'reaped');
}

print "\n3) 不是 clone 的 Volume 不能被誤判\n";
{
    my @deleted;
    {
        package FakeAPI2;
        sub new { bless {}, $_[0] }
        sub volume_list { return [ { name => 'pve-store-100-disk0-pve-tomb-1770000000-99', serial=>'X' } ] }
        sub volume_get_connections { [] }
        sub serial_to_wwid { undef }
        sub volume_get_wwid { undef }
        sub volume_disconnect_host { 1 }
        sub volume_delete { push @deleted, $_[1]; 1 }
    }
    @deleted = ();
    $P->can('_sweep_temp_snap_clones')->({}, 'store', FakeAPI2->new(), $vol);
    check('tombstone 名稱不會被當成 clone 刪掉', @deleted ? 'DELETED' : 'ignored', 'ignored');
}
printf "\n%d passed, %d failed\n",$pass,$fail;
exit($fail?1:0);
