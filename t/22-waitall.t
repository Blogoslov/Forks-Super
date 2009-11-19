use Forks::Super ':test';
use Test::More tests => 22;
use strict;
use warnings;

#
# test the Forks::Super::waitall command
#



my (%x,@pid);
for (my $i=0; $i<5; $i++) {
  my $pid = fork { 'sub' => sub { sleep 5 ; exit $i } };
  $x{$pid} = $i << 8;
  push @pid, $pid;
}

my $t = time;
Forks::Super::waitall;
$t = time - $t;
my $p = wait;
ok($p == -1, "wait after waitall returns -1==$p");
ok($t >= 5 && $t <= 6, "took ${t}s expected 5-6");

foreach my $pid (@pid) {
  my $j = Forks::Super::Job::_get($pid);
  ok(defined $j);
  ok($j->{real_pid} == $pid);
  ok($j->{state} eq "REAPED");
  ok($j->{status} == $x{$pid});
}

__END__
-------------------------------------------------------

Feature:	waitall function

What to test:	waitall when nothing to wait for should take no time
		waitall when lots to wait for should take the right amt of time

-------------------------------------------------------
