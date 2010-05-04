use Forks::Super ':test';
use Test::More tests => 22;
use strict;
use warnings;

#
# test the Forks::Super::waitall command
#



my (%x,@pid);
my $t0 = Forks::Super::Util::Time();
for (my $i=0; $i<5; $i++) {
  my $pid = fork { sub => sub { sleep 5 ; exit $i },
	callback => { ___start => sub { 
			print Forks::Super::Util::Ctime()," start\n" } }  };
  $x{$pid} = $i << 8;
  push @pid, $pid;
}

my $t = Forks::Super::Util::Time();
Forks::Super::waitall;
my $t2 = Forks::Super::Util::Time();
($t0,$t) = ($t2-$t0, $t2-$t);
my $p = wait;
ok($p == -1, "wait after waitall returns -1==$p");
ok($t0 >= 4.85 && $t <= 10,        ### 2 ### was 6 obs 6.39,8.99,9.70
   "took ${t}s ${t0}s expected 5-6");

foreach my $pid (@pid) {
  my $j = Forks::Super::Job::get($pid);
  ok(defined $j, "exercise $pid Forks::Super::Job::get");
  ok($j->{real_pid} == $pid, "real_pid == pid for regular job");
  ok($j->{state} eq "REAPED", "waitall puts jobs in REAPED state");
  ok($j->{status} == $x{$pid}, "exit status was captured");
}
