use Forks::Super ':test';
use Test::More tests => 9;
use strict;
use warnings;
no warnings 'once';

my $file = "t/out/49.$$.out";
$Forks::Super::Util::DEFAULT_PAUSE = 0.5;

our ($DEBUG, $DEVNULL);

if ($ENV{DEBUG}) {
  $DEBUG = *STDERR;
} else {
  open($DEVNULL, ">", "$file.debug");
  $DEBUG = $DEVNULL;
}

END {
  if ($$ == $Forks::Super::MAIN_PID) {
    unlink $file, "$file.tmp", "$file.debug";
    unless ($ENV{DEBUG}) {
      close $DEVNULL;
      unlink "$file.debug";
    }
  }
}

#
# a suspend callback function:
# return -1 if an active job should be suspended
# return +1 if a suspended job should be resumed
# return 0 if a job should be left in whatever state it is in
#
sub child_suspend_callback_function {
  my ($job) = @_;
  my $d = (time - $::T) % 20;
  no warnings 'unopened';
  print $DEBUG "callback: \$d=$d ";
  if ($d < 5) {
    print $DEBUG " :  noop\n";
    return 0;
  }
  if ($d < 10) {
    while (-f "$file.block-suspend") {
      print $DEBUG "::: suspend - wait for child to be in good state\n";
      Time::HiRes::sleep 0.25;
    }
    print $DEBUG " :  suspend\n";
    return -1;
  }
  if ($d < 15) {
    print $DEBUG " :  noop\n";
    return 0;
  }
  print $DEBUG " :  resume\n";
  return +1;
}

sub read_value {
  no warnings 'unopened';
  my $fh;
  unless(open $fh, '<', $file) {
    sleep 1;
    open $fh, '<', $file;
  }
  my $F = <$fh>;
  close $fh;
  print $DEBUG "read_value is $F\n";
  return $F;
}

sub write_value {
  my ($value) = @_;

  no warnings 'unopened';

  # don't suspend while we're in the middle of changing the ipc file
  open my $xx, '>>', "$file.block-suspend";
  close $xx;

  open my $fh, '>', "$file.tmp";
  print $DEBUG "write_value $value\n";
  print $fh $value;
  close $fh;
  rename "$file.tmp", $file;
  print $DEBUG "write_value: sync\n";
  unlink "$file.block-suspend";
  return;
}

$Forks::Super::Queue::QUEUE_MONITOR_FREQ = 2;


SKIP: {
  if ($^O eq 'MSWin32' && !Forks::Super::Config::CONFIG_module("Win32::API")) {
    skip "suspend/resume not supported on MSWin32", 9;
  }

  my $t0 = $::T = Time::HiRes::time();
  my $pid = fork { 
    suspend => 'child_suspend_callback_function',
      sub => sub {
	for (my $i = 1; $i <= 8; $i++) {
	  Time::HiRes::sleep(0.5);
	  write_value($i);
	  Time::HiRes::sleep(0.5);
	}
      },
	timeout => 45
      };
  my $t1 = 0.5 * ($t0 + Time::HiRes::time());
  my $job = Forks::Super::Job::get($pid);

  local $SIG{STOP} = $SIG{TSTP} = sub { croak "SIG$_[0] received in PARENT process" };

  # sub should proceed normally for 5 seconds
  # then process should be suspended
  # process should stay suspended for 10 seconds
  # then process should resume and run for 5-10 seconds

  Forks::Super::Util::pause($t1 + 2.0 - Time::HiRes::time());
  ok($job->{state} eq 'ACTIVE', "job has started");
  my $w = read_value();
  ok($w > 0 && $w < 5, "job is incrementing value, expect 0 < val:$w < 5");

  Forks::Super::Util::pause($t1 + 8.0 - Time::HiRes::time());
  ok($job->{state} eq 'SUSPENDED', "job is suspended");
  $w = read_value();
  if (!defined $w) {
    warn "read_value() did not return a value. Retrying ...\n";
    sleep 1;
    $w = read_value();
  }

  ok($w >= 4, "job is incrementing value, expect val:$w >= 4");  ### 4 ###

  Forks::Super::Util::pause($t1 + 11.0 - Time::HiRes::time());
  ok($job->{state} eq 'SUSPENDED', "job is still suspended");
  my $x = read_value();
  ok($x == $w, "job has stopped increment value, expect val:$x == $w");

  Forks::Super::Util::pause($t1 + 18.0 - Time::HiRes::time());
  ok($job->{state} eq 'ACTIVE' || $job->{state} eq 'COMPLETE',
     "job has resumed state=" . $job->{state});
  $x = read_value();
  if (!defined $x) {
    warn "read_value() did not return a value. Retrying ...\n";
    sleep 1;
    $x = read_value();
  }
  ok($x > $w, "job has resumed incrementing value, expect val:$x > $w");

  my $p = wait 4.0;
  if (!isValidPid($p)) {
    $job->resume;
    $p = wait 2.0;
    if (!isValidPid($p)) {
      $job->resume;
      $p = wait 2.0;
      if (!isValidPid($p)) {
	$job->resume;
	$p = wait 2.0;
	if (!isValidPid($p)) {
	  $job->resume;
	  $p = wait 2.0;
	  if (!isValidPid($p)) {
	    print STDERR "Killing unresponsive job $job\n";
	    $job->kill('KILL');
	    $job->resume;
	  }
	}
      }
    }
  }

  ok($p == $pid, "job has completed");
}

