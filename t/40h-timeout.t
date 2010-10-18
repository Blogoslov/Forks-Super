use Forks::Super ':test';
use Test::More tests => 2;
use Carp;
use strict;
use warnings;

# force loading of more modules in parent proc
# so fast fail (see test#17, test#8) isn't slowed
# down so much
Forks::Super::Job::Timeout::warm_up();

if (${^TAINT}) {
  $ENV{PATH} = "";
  ($^X) = $^X =~ /(.*)/;
  ($ENV{HOME}) = $ENV{HOME} =~ /(.*)/;
}

#
# test that jobs respect deadlines for jobs to
# complete when the jobs specify "timeout" or
# "expiration" options
#

SKIP: {

  if (!$Forks::Super::SysInfo::CONFIG{'alarm'}) {
    skip "alarm function unavailable on this system ($^O,$]), "
      . "can't test timeout feature", 2;
  }
  if ($Forks::Super::SysInfo::SLEEP_ALARM_COMPATIBLE <= 0) {
    skip "alarm incompatible with sleep on this system ($^O,$]), "
      . "can't test timeout feature", 2;
  }

##########################################################

my $t0 = Time::HiRes::gettimeofday();
my $pid = fork { cmd => [ $^X, "t/external-command.pl", "-s=15" ], 
		   timeout => 2 };
my $t = Time::HiRes::gettimeofday();
waitpid $pid, 0;
my $t2 = Time::HiRes::gettimeofday();
($t0,$t) = ($t2-$t0,$t2-$t);
ok($t <= 6.95,           ### 29 ### was 3.0 obs 3.10,3.82,4.36,6.63,9.32
   "cmd-style respects timeout ${t}s ${t0}s "
   ."expected ~2s"); 

$t0 = Time::HiRes::gettimeofday();
$pid = fork { exec => [ $^X, "t/external-command.pl", "-s=6" ], timeout => 2 };
$t = Time::HiRes::gettimeofday();
waitpid $pid, 0;
$t2 = Time::HiRes::gettimeofday();
($t0,$t) = ($t2-$t0,$t2-$t);
ok($t0 >= 5.9 && $t > 4.95, 
   "exec-style doesn't respect timeout ${t}s ${t0}s expected ~6s");

######################################################################

} # end SKIP
