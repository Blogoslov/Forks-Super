use Forks::Super ':test';
use Test::More tests => 28;
use strict;
use warnings;

my @cmd = ($^X, "t/external-command.pl",
	   "-e=Hello", "-s=2", "-y=1", "-e=whirled");

my ($fh_in, $fh_out, $pid, $job) = Forks::Super::open2(@cmd);

ok(defined($fh_in) && defined($fh_out), "open2: child fh available");
ok(isValidPid($pid), "open2: valid pid $pid");
sleep 1;
ok(defined($job), "open2: received job object");
ok($job->{state} eq 'ACTIVE', "open2: job is active " . $job->{state});

my $msg = sprintf "%05x", rand() * 99999;
my $z = print $fh_in "$msg\n";
Forks::Super::close_fh($pid,'stdin');
ok($z > 0, "open2: print to input handle ok = $z");
sleep 3;
my @out = <$fh_out>;
Forks::Super::close_fh($pid, 'stdout');
ok(@out == 2, "open2: got right number of output lines");
ok($out[0] eq "Hello $msg\n", "got right output");
Forks::Super::pause();
ok($job->{state} eq 'COMPLETE', "job complete");
ok($pid == waitpid($pid,0), "job reaped");

######################################################

my $fh_err;
$cmd[4] = "-y=3";
($fh_in, $fh_out, $fh_err, $pid, $job) = Forks::Super::open3(@cmd);
ok(defined($fh_in) && defined($fh_out) && defined($fh_err), "open3: child fh available");
ok(isValidPid($pid), "open3: valid pid $pid");
sleep 1;
ok(defined($job), "open3: received job object");
ok($job->{state} eq 'ACTIVE', "open3: job is active " . $job->{state});

$msg = sprintf "%05x", rand() * 99999;
$z = print $fh_in "$msg\n";
Forks::Super::close_fh($pid,'stdin');
ok($z > 0, "open3: print to input handle ok = $z");
sleep 3;
@out = <$fh_out>;
Forks::Super::close_fh($pid, 'stdout');
my @err = <$fh_err>;
Forks::Super::close_fh($pid, 'stderr');
ok(@out == 4, "open3: got right number of output lines");
ok($out[0] eq "Hello $msg\n", "got right output (1)");
ok($out[1] eq "$msg\n", "got right output (2)");
ok(@err == 1, "open3: got right error lines");
ok($err[0] eq "received message $msg\n", "open3: got right error");
Forks::Super::pause();
ok($job->{state} eq 'COMPLETE', "job complete");
ok($pid == waitpid($pid,0), "job reaped");

#############################################################################

$cmd[3] = "-s=5";
($fh_in, $fh_out, $fh_err, $pid, $job) = Forks::Super::open3(@cmd, {timeout => 3});
ok(defined($fh_in) && defined($fh_out) && defined($fh_err), "open3: child fh available");
ok(defined($job), "open3: received job object");
ok($job->{state} eq 'ACTIVE', "open3: respects additional options");
sleep 1;
$msg = sprintf "%05x", rand() * 99999;
$z = print $fh_in "$msg\n";
Forks::Super::close_fh($pid,'stdin');
ok($z > 0, "open3: print to input handle ok = $z");
sleep 3;
@out = <$fh_out>;
Forks::Super::close_fh($pid, 'stdout');
@err = <$fh_err>;
Forks::Super::close_fh($pid, 'stderr');

ok(@out == 1 && $out[0] =~ /^Hello/, "open3: time out  \@out='@out'" . scalar @out);
ok(@err == 0 || $err[0] =~ /timeout/, "open3: job timed out");
waitpid $pid,0;
ok($job->{status} != 0, "open3: job timed out status $job->{status}!=0");

unlink 'null';
