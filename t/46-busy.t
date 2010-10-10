use Forks::Super ':test';
use Test::More tests => 10;
use strict;
use warnings;

$Devel::Trace::TRACE=0;

#
# test that jobs don't launch when the system is
# "too busy" (which so far means that there are
# already too many active subprocesses). Jobs that
# are too busy to start can either block or fail.
#

#######################################################

sub sleepy { return sleep 3 }
my $sleepy = \&sleepy;

$Forks::Super::MAX_PROC = 3;
$Forks::Super::ON_BUSY = "block";

my $pid1 = fork { sub => $sleepy };
my $pid2 = fork { sub => $sleepy };
my $t = Time::HiRes::gettimeofday();
my $t0 = $t;
my $pid3 = fork { sub => $sleepy };
$t = Time::HiRes::gettimeofday() - $t;
ok($t <= 1.97, "$$\\three forks fast return ${t}s expected <1s"); ### 1 ###
ok(isValidPid($pid1) && isValidPid($pid2) && isValidPid($pid3),
   "forks successful");

my $t2 = Time::HiRes::gettimeofday();
my $pid4 = fork { sub => $sleepy };
my $t3 = Time::HiRes::gettimeofday();
($t2,$t0) = ($t3-$t2, $t3-$t0);
ok($t2 >= 2 || ($t0 > 3.0), "blocked fork took ${t2}s ${t0}s expected >2s");
ok(isValidPid($pid4), "blocking fork returns valid pid $pid4"); ### 4 ###
waitall;

#######################################################

$Forks::Super::ON_BUSY = "fail";
$pid1 = fork { sub => $sleepy };  # ok 1/3
$pid2 = fork { sub => $sleepy };  # ok 2/3
$t = Time::HiRes::gettimeofday();
$pid3 = fork { sub => $sleepy };  # ok 3/3
$t = Time::HiRes::gettimeofday() - $t;
ok($t <= 1.9, "three forks no delay ${t}s expected <=1s"); ### 5 ###
ok(isValidPid($pid1) && isValidPid($pid2) && isValidPid($pid3),
   "three successful forks");


$t = Time::HiRes::gettimeofday();
$pid4 = fork { sub => $sleepy };     # should fail .. already 3 procs
my $pid5 = fork { sub => $sleepy };  # should fail
my $u = Time::HiRes::gettimeofday() - $t;
ok($u <= 1, "Took ${u}s expected fast fail 0-1s"); ### 7 ###
ok(!isValidPid($pid4) && !isValidPid($pid5), "failed forks");
waitall;
$t = Time::HiRes::gettimeofday() - $t;

ok($t >= 2.15 && $t <= 6,                    ### 9 ### was 4 obs 6.75!
   "Took ${t}s for all jobs to finish; expected 3-4"); 

#######################################################

$Forks::Super::MAX_PROC = 3;
$Forks::Super::ON_BUSY = "fail";

my $pid = fork { sub => 
	sub { # a subroutine that will make the processor busy for a while
	  my $z=0;
	  my $timeout = time + ($^O eq 'MSWin32' ? 10 : 30);
	  while (time < $timeout) {
	    $z += rand()-rand() 
	  }
	} };

$Devel::Trace::TRACE=1;
$Forks::Super::MAX_LOAD = 0.001;
sleep 1;
SKIP: {
  my $load = Forks::Super::Job::get_cpu_load();
  if ($load < 0) {
    skip "get_cpu_load function not available", 1;
  }
  for (my $i=0; $i<5; $i++) {
    $load = Forks::Super::Job::get_cpu_load();
    print STDERR "Cpu load: $load\n";
    last if $load > 0.1;
    sleep 1;
  }
  if ($load == 0.0) {
    skip "test could not generate a cpu load on this machine", 1;
  }
  $pid2 = fork { sub => sub { sleep 4 } };
  ok(isValidPid($pid) && !isValidPid($pid2), 
     "$pid2 fail while system is loaded");
}

# on MSWin32 it is harder to gracefully kill a child process,
# but the CPU load measurement has less inertia so we don't
# have to let the process run as long

if ($^O eq 'MSWin32') {
  waitall;
} elsif (ref $pid eq 'Forks::Super::Job') {
  kill 'INT', $pid->{real_pid};
} else {
  kill 'INT',$pid;
}
exit 0;
