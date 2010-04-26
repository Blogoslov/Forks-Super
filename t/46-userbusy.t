use Forks::Super ':test';
use Test::More tests => 9;

#
# user can supply their own subroutine to decide
# whether the system is too busy to fork a new
# process.
#

sub do_launch { 1; }
sub dont_launch { 0; }
$launch_after_nap = sub { sleep 10; 1 };
$sleepy = sub { sleep 30 };

sub dont_launch_external {
  # block jobs that invoke external commands
  # but use the default handler for other jobs
  my $job = shift;
  bless $job, "Forks::Super::Job";
  return 0 if defined $job->{cmd};
  return $job->_can_launch;
}

$Forks::Super::MAX_PROC = 1;
$Forks::Super::ON_BUSY = "fail";

$pid = fork { sub => $sleepy };
ok(isValidPid($pid), "successful fork");
$pid2 = fork { sub => $sleepy };
ok(!isValidPid($pid2), "failed fork");
$pid3 = fork { sub => $sleepy , can_launch => 'main::do_launch' };
ok(isValidPid($pid3), "successful user fork");
$t = Forks::Super::Util::Time();
$pid4 = fork { sub => $sleepy , can_launch => $launch_after_nap };
$t = Forks::Super::Util::Time() - $t;
ok(isValidPid($pid4), "successful delayed fork");
ok($t >= 10, "fork was delayed ${t}s expected >10s");

$Forks::Super::MAX_PROC = 50;
$pid5 = fork { sub => $sleepy };
ok(isValidPid($pid5), "successful fork");
$pid6 = fork { sub => $sleepy , can_launch => \&dont_launch };
ok(!isValidPid($pid6), "force failed fork");

@to_kill = grep { isValidPid($_) } ($pid, $pid2, $pid3, $pid4, $pid5, $pid6);
print "to kill: @to_kill\n";
kill 'TERM', @to_kill if @to_kill > 0 && $^O ne 'MSWin32';
waitall;

$Forks::Super::MAX_PROC = 3;
$pid7 = fork { cmd => [ $^X,"t/external-command.pl", "-e=Hello" ],
		 can_launch => \&dont_launch_external };
$pid8 = fork { sub => sub { sleep 2 } };
ok(!isValidPid($pid7), "failed fork with logic");
ok(isValidPid($pid8), "successful fork with logic");
waitall;

__END__
-------------------------------------------------------

Feature:	user code to determine when system is busy

What to test:	always on always succeeds
		always off always fails
		random
		filter on commands

-------------------------------------------------------
