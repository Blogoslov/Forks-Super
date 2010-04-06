use Forks::Super ':test';
use Test::More tests => 2;
use Carp;
use strict;
use warnings;

# force loading of more modules in parent proc
# so fast fail (see test#17, test#8) isn't slowed
# down so much
Forks::Super::Job::Timeout::warm_up();

#
# test that jobs respect deadlines for jobs to
# complete when the jobs specify "timeout" or
# "expiration" options
#

if (!Forks::Super::CONFIG("alarm")) {
 SKIP: {
    skip "alarm function unavailable on this system ($^O,$]), "
      . "can't test timeout feature", 2;
  }
  exit 0;
}

##########################################################

my $t0 = Forks::Super::Util::Time();
my $pid = fork { cmd => [ $^X, "t/external-command.pl", "-s=9" ], 
		   timeout => 2 };
my $t = Forks::Super::Util::Time();
waitpid $pid, 0;
my $t2 = Forks::Super::Util::Time();
($t0,$t) = ($t2-$t0,$t2-$t);
ok($t <= 4.95,           ### 29 ### was 3.0 obs 3.10,3.82,4.36
   "cmd-style respects timeout ${t}s ${t0}s "
   ."expected ~2s"); 

$t0 = Forks::Super::Util::Time();
$pid = fork { exec => [ $^X, "t/external-command.pl", "-s=6" ], timeout => 2 };
$t = Forks::Super::Util::Time();
waitpid $pid, 0;
$t2 = Forks::Super::Util::Time();
($t0,$t) = ($t2-$t0,$t2-$t);
ok($t0 >= 5.9 && $t > 4.95, 
   "exec-style doesn't respect timeout ${t}s ${t0}s expected ~6s");

######################################################################
