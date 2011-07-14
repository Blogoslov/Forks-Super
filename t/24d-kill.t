use Forks::Super ':test', MAX_PROC => 5, ON_BUSY => 'queue';
use Test::More tests => 5;
use strict;
use warnings;

# as of v0.30, the kill and kill_all functions are not very well speced out.
# these tests should pass in the current incarnation, though.

if (${^TAINT}) {
    require Cwd;

    $ENV{PATH} = '';
    ($^X) = $^X =~ /(.*)/;

    my $ipc_dir = Forks::Super::Job::Ipc::_choose_dedicated_dirname();
    if (! eval {$ipc_dir = Cwd::abs_path($ipc_dir)}) {
	$ipc_dir = Cwd::getcwd() . "/" . $ipc_dir;
    }
    ($ipc_dir) = $ipc_dir =~ /(.*)/;
    Forks::Super::Job::Ipc::set_ipc_dir($ipc_dir);
}

SKIP: {
  if ($^O eq "MSWin32" && !Forks::Super::Config::CONFIG("Win32::API")) {
      skip "kill is unsafe on MSWin32 without Win32::API", 5;
  }

  # signal fork to cmd jobs

  my @cmd = ($^X, "t/sleeper.pl");
  my $pid1 = fork { cmd => \@cmd };
  my $pid2 = fork { cmd => \@cmd };
  my $pid3 = fork { cmd => \@cmd };
  my $j1 = Forks::Super::Job::get($pid1);

  ok(isValidPid($pid1) && isValidPid($pid2) && isValidPid($pid3),
     "launched $pid1,$pid2,$pid3 fork to cmd");

#  if (${^TAINT}) {
#      # "signal" pid is tainted for fork-to-cmd jobs
#      $j1->signal_pid;
#      ($j1->{signal_pid}) = $j1->{signal_pid} =~ /(.*)/;
#  }

  my $y = Forks::Super::kill('TERM', $j1);
  ok($y >= 1, "kill signal to $pid1 sent successfully $y==1 cmd");
  sleep 1;

  # sometimes the signal is delivered but the process doesn't end?
  # resend to make sure it gets delivered, otherwise later tests will fail
  for (1..3) {
      if (!$pid1->is_complete) {
          Forks::Super::kill('QUIT', $pid1);
	  sleep 1;
      }
  }

  Forks::Super::Debug::use_Carp_Always();

  my $t = Time::HiRes::time();
  my $p = waitpid $pid1, 0, 20;
  $t = Time::HiRes::time() - $t;
  ok($t < 6,                                                  ### 23 ###
     "process $pid1 took ${t}s to reap cmd, expected fast"); 
     # [sometimes it can take a while, though]

  ok($p == $pid1, "kill signal to $p==$pid1 successful cmd");

  my $z = Forks::Super::kill_all('KILL');
  ok($z >= 2, "kill_all signal to $z==$pid2,$pid3 successful cmd");
  sleep 1;

  # waitall;
}  # end SKIP
