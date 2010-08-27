use Forks::Super ':test';
use Test::More tests => 4;
use strict;
use warnings;

if (!Forks::Super::Config::CONFIG("DateTime::Format::Natural")) {
 SKIP: {
    skip "natural language test requires DateTime::Format::Natural module", 4;
  }
  exit 0;
}

my $t = Forks::Super::Util::Time();
my $pid = fork { delay => "in 5 seconds", sub => sub { sleep 3 } };
my $pp = waitpid $pid, 0;
my $job = Forks::Super::Job::get($pid);
my $elapsed = $job->{start} - $t;

ok(!isValidPid($pid) && $pp == $pid || $pp == $job->{real_pid}, "created task with natural language delay");
ok($elapsed >= 4 && $elapsed <= 6, "natural language delay was respected");

my $future = "in 6 seconds";
$t = Forks::Super::Util::Time();
$pid = fork { start_after => $future,
		child_fh => "out",
		sub => sub { 
		  my $e = $Forks::Super::Job::self->{start_after};
		  print STDOUT "$e\n";
		  sleep 4;
		} };
$pp = waitpid $pid, 0;
$job = Forks::Super::Job::get($pid);
$elapsed = $job->{start} - $t;
ok(!isValidPid($pid) && $pid == $pp || $pp == $job->{real_pid}, "created another task with natural language start_after");
ok($elapsed >= 5 && $elapsed <= 7, "natural language start_after was respected");

waitall;
