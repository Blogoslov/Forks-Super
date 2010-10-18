use Forks::Super ':test';
use Test::More tests => 3;
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

SKIP: {
  if (!$Forks::Super::SysInfo::CONFIG{'alarm'}) {
    skip "alarm function unavailable on this system ($^O,$]), "
      . "can't test timeout feature", 3;
  }
  if ($Forks::Super::SysInfo::SLEEP_ALARM_COMPATIBLE <= 0) {
    skip "alarm/sleep incompatible on this system ($^O,$]), "
      . "can't test timeout feature", 3;
  }

my $pid = fork { sub => sub { sleep 10; exit 0 }, timeout => 3 };
my $t = Time::HiRes::gettimeofday();
my $p = wait;
$t = Time::HiRes::gettimeofday() - $t;
ok($p == $pid, "$$\\wait successful");
ok($? != 0, "job expired with non-zero exit STATUS");
ok($t < 6.05, "Timed out in ${t}s, expected ~3s"); ### 3a ### was 5.1 obs 5.98

} # end SKIP
