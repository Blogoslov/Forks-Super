use Forks::Super ':test';
use Test::More tests => 9;
use strict;
use warnings;

if ($^O eq 'MSWin32' && !Forks::Super::Config::CONFIG("Win32::API")) {
 SKIP: {
    skip "suspend/resume not supported on MSWin32", 9;
  }
  exit 0;
}

my $file = "t/out/48.$$.out";

#
# a suspend callback function:
# return -1 if an active job should be suspended
# return +1 if a suspended job should be resumed
# return 0 if a job should be left in whatever state it is in
#
sub child_suspend_callback_function {
  my ($job) = @_;
  my $d = (time - $^T) % 20;
  if ($d < 5) {
    return 0;
  }
  if ($d < 10) {
    return -1;
  }
  if ($d < 15) {
    return 0;
  }
  return +1;
}

sub read_value {
  open my $fh, '<', $file;
  my $F = <$fh>;
  close $fh;
  return $F;
}

sub write_value {
  my ($value) = @_;
  open my $fh, '>', $file;
  print $fh $value;
  close $fh;
}

unlink $file;
$Forks::Super::Queue::QUEUE_MONITOR_FREQ = 2;

my $pid = fork { 
  suspend => 'child_suspend_callback_function',
  sub => sub {
    for (my $i = 1; $i <= 10; $i++) {
      write_value($i);
      sleep 1;
    }
  } 
};
my $job = Forks::Super::Job::get($pid);

# sub should proceed normally for 5 seconds
# then process should be suspended
# process should stay suspended for 10 seconds
# then process should resume and run for 5-10 seconds

Forks::Super::Util::pause(2.0);
ok($job->{state} eq 'ACTIVE', "job has started");
my $w = read_value();
ok($w > 0 && $w < 5, "job is incrementing global variable");

Forks::Super::Util::pause(6.0);
ok($job->{state} eq 'SUSPENDED', "job is suspended");
$w = read_value();
ok($w > 4, "job is incrementing global variable");

Forks::Super::Util::pause(3.0);
ok($job->{state} eq 'SUSPENDED', "job is still suspended");
my $x = read_value();
ok($x == $w, "job has stopped increment global variable");

Forks::Super::Util::pause(7.0);
ok($job->{state} eq 'ACTIVE', "job has resumed");
$x = read_value();
ok($x > $w, "job has resumed incrementing global variable");

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
      }
    }
  }
}

ok($p == $pid, "job has completed");
unlink $file;
