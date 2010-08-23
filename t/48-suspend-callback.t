use Forks::Super ':test';
use Test::More tests => 9;
use strict;
use warnings;
no warnings 'once';

my $file = "t/out/48.$$.out";
$Forks::Super::Util::DEFAULT_PAUSE = 0.5;
if ($ENV{DEBUG}) {
  *DEBUG = *STDERR;
} else {
  *DEBUG = *DEVNULL;
}

if ($^O eq 'MSWin32' && !Forks::Super::Config::CONFIG("Win32::API")) {
 SKIP: {
    skip "suspend/resume not supported on MSWin32", 9;
  }
  exit 0;
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
  print DEBUG "callback: \$d=$d ";
  if ($d < 5) {
    print DEBUG ": noop\n";
    return 0;
  }
  if ($d < 10) {
    print DEBUG ": suspend\n";
    return -1;
  }
  if ($d < 15) {
    print DEBUG ": noop\n";
    return 0;
  }
  print DEBUG ": resume\n";
  return +1;
}

sub read_value {
  no warnings 'unopened';
  open my $lock, '>>', "$file.lock";
  flock $lock, 2;

  open my $fh, '<', $file;
  my $F = <$fh>;
  close $fh;
  close $lock;
  print DEBUG "read_value is $F\n";
  return $F;
}

sub write_value {
  no warnings 'unopened';
  my ($value) = @_;
  open my $lock, '>>', "$file.lock";
  flock $lock, 2;

  open my $fh, '>', $file;
  print DEBUG "\$value=$value\n";
  print $fh $value;
  close $fh;
  close $lock;
}

$Forks::Super::Queue::QUEUE_MONITOR_FREQ = 2;


my $t0 = $::T = Forks::Super::Util::Time();
my $pid = fork { 
  suspend => 'child_suspend_callback_function',
  sub => sub {
    for (my $i = 1; $i <= 8; $i++) {
      Time::HiRes::sleep(0.5);
      write_value($i);
      Time::HiRes::sleep(0.5);
    }
  }
};
my $t1 = 0.5 * ($t0 + Forks::Super::Util::Time());
my $job = Forks::Super::Job::get($pid);

# sub should proceed normally for 5 seconds
# then process should be suspended
# process should stay suspended for 10 seconds
# then process should resume and run for 5-10 seconds

Forks::Super::Util::pause($t1 + 2.0 - Forks::Super::Util::Time());
ok($job->{state} eq 'ACTIVE', "job has started");
my $w = read_value();
ok($w > 0 && $w < 5, "job is incrementing value, expect 0 < val:$w < 5");

Forks::Super::Util::pause($t1 + 8.0 - Forks::Super::Util::Time());
ok($job->{state} eq 'SUSPENDED', "job is suspended");
$w = read_value();

# Failure point in 0.35 ...

ok($w > 4, "job is incrementing value, expect val:$w > 4");

Forks::Super::Util::pause($t1 + 11.0 - Forks::Super::Util::Time());
ok($job->{state} eq 'SUSPENDED', "job is still suspended");
my $x = read_value();
ok($x == $w, "job has stopped increment value, expect val:$x == $w");

Forks::Super::Util::pause($t1 + 18.0 - Forks::Super::Util::Time());
ok($job->{state} eq 'ACTIVE' || $job->{state} eq 'COMPLETE',
   "job has resumed state=" . $job->{state});
$x = read_value();
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
      }
    }
  }
}

ok($p == $pid, "job has completed");
unlink $file, "$file.lock";

