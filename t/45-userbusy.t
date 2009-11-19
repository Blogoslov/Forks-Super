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
ok(_isValidPid($pid));
$pid2 = fork { sub => $sleepy };
ok(!_isValidPid($pid2));
$pid3 = fork { sub => $sleepy , can_launch => 'main::do_launch' };
ok(_isValidPid($pid3));
$t = time;
$pid4 = fork { sub => $sleepy , can_launch => $launch_after_nap };
$t = time - $t;
ok(_isValidPid($pid4));
ok($t >= 10);

$Forks::Super::MAX_PROC = 50;
$pid5 = fork { sub => $sleepy };
ok(_isValidPid($pid5));
$pid6 = fork { sub => $sleepy , can_launch => \&dont_launch };
ok(!_isValidPid($pid6));

@to_kill = grep { _isValidPid($_) } ($pid, $pid2, $pid3, $pid4, $pid5, $pid6);
print "to kill: @to_kill\n";
kill 'TERM', @to_kill if @to_kill > 0 && $^O ne "MSWin32";
waitall;

$Forks::Super::MAX_PROC = 3;
$pid7 = fork { cmd => [ "perl","t/external-command.pl", "-e=Hello" ],
		 can_launch => \&dont_launch_external };
$pid8 = fork { sub => sub { sleep 2 } };
ok(!_isValidPid($pid7));
ok(_isValidPid($pid8));
waitall;

__END__
-------------------------------------------------------

Feature:	user code to determine when system is busy

What to test:	always on always succeeds
		always off always fails
		random
		filter on commands

-------------------------------------------------------
