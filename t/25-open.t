use Forks::Super ':test';
use Test::More tests => 28;
use strict;
use warnings;

if (${^TAINT}) {
  $ENV{PATH} = "";
  ($^X) = $^X =~ /(.*)/;

    my $ipc_dir = Forks::Super::Job::Ipc::_choose_dedicated_dirname();
    if (! eval {$ipc_dir = Cwd::abs_path($ipc_dir)}) {
	$ipc_dir = Cwd::getcwd() . "/" . $ipc_dir;
    }
    ($ipc_dir) = $ipc_dir =~ /(.*)/;
    Forks::Super::Job::Ipc::set_ipc_dir($ipc_dir);
}

my @cmd = ($^X, "t/external-command.pl",
	   "-e=Hello", "-s=4", "-y=1", "-e=whirled");

my ($fh_in, $fh_out, $pid, $job) = Forks::Super::open2(@cmd);

ok(defined($fh_in) && defined($fh_out), "open2: child fh available");
ok(isValidPid($pid), "open2: valid pid $pid");
sleep 1;
ok(defined($job), "open2: received job object");
ok($job->{state} eq 'ACTIVE', "open2: job is active " . $job->{state});

my $msg = sprintf "%05x", rand() * 99999;
my $z = print {$fh_in} "$msg\n";
Forks::Super::close_fh($pid,'stdin');
ok($z > 0, "open2: print to input handle ok = $z");
sleep 6;

my @out = Forks::Super::read_stdout($pid);
Forks::Super::close_fh($pid, 'stdout');
ok(@out == 2,                                                      ### 6 ###
   "open2: got right number of output lines 2 == " . scalar @out)
  or diag("Output was:\n@out\nExpected 2 lines");
ok($out[0] eq "Hello $msg\n", "got right output")                  ### 7 ###
  or diag("Got \"$out[0]\", expected \"Hello $msg\\n\"");
Forks::Super::pause();
ok($job->{state} eq 'COMPLETE', "job complete");
ok($pid == waitpid($pid,0), "job reaped");

######################################################

my $fh_err;
$cmd[4] = "-y=3";
($fh_in, $fh_out, $fh_err, $pid, $job) = Forks::Super::open3(@cmd);
ok(defined($fh_in) && defined($fh_out) && defined($fh_err),
   "open3: child fh available");
ok(isValidPid($pid), "open3: valid pid $pid");
sleep 1;
ok(defined($job), "open3: received job object");
ok($job->{state} eq 'ACTIVE', "open3: job is active " . $job->{state});

$msg = sprintf "%05x", rand() * 99999;
$z = print $fh_in "$msg\n";
Forks::Super::close_fh($pid,'stdin');
ok($z > 0, "open3: print to input handle ok = $z");
sleep 5;


@out = Forks::Super::read_stdout($pid);
Forks::Super::close_fh($pid, 'stdout');

my @err = Forks::Super::read_stderr($pid);

if (!Forks::Super::Config::CONFIG('filehandles')) {
    @err = grep { !/set_signal_pid/ } @err;
}

Forks::Super::close_fh($pid, 'stderr');
ok(@out == 4, "open3: got right number of output lines")            ### 15 ###
  or diag("open3 output was:\n@out\nExpected 4 lines");
ok(@out>0 && $out[0] eq "Hello $msg\n", "got right output (1)")     ### 16 ###
  or diag("First output was \"$out[0]\", expected \"Hello $msg\\n\"");
ok(@out>1 && $out[1] eq "$msg\n", "got right output (2)")           ### 17 ###
  or diag("2nd output was \"$out[1]\", expected \"$msg\\n\"");
ok(@err == 1, "open3: got right error lines");                      ### 18 ###
ok(@err>0 && $err[0] eq "received message $msg\n",                  ### 19 ###
   "open3: got right error")
  or diag("Error was \"$err[0]\",\n",
	  "Expected \"received message $msg\\n\"");
Forks::Super::pause();
ok($job->{state} eq 'COMPLETE', 
   "job state " . $job->{state} . " == 'COMPLETE'");
ok($pid == waitpid($pid,0), "job reaped");

#############################################################################

SKIP: {

  if (!$Forks::Super::SysInfo::CONFIG{'alarm'}) {
    skip "no alarm(), can't test additional option", 7;
  }
  if ($Forks::Super::SysInfo::SLEEP_ALARM_COMPATIBLE <= 0) {
    skip "alarm(), sleep() incompatible, can't test additional options", 7;
  }

  $cmd[3] = "-s=10";
  ($fh_in, $fh_out, $fh_err, $pid, $job) 
    = Forks::Super::open3(@cmd, {timeout => 5});
  
  Forks::Super::Debug::use_Carp_Always();

  ok(defined($fh_in) && defined($fh_out) && defined($fh_err),
     "open3: child fh available");
  ok(defined($job), "open3: received job object");
  ok($job->{state} eq 'ACTIVE', "open3: respects additional options");
  sleep 1;
  $msg = sprintf "%05x", rand() * 99999;
  $z = print $fh_in "$msg\n";
  Forks::Super::close_fh($pid,'stdin');
  ok($z > 0, "open3: print to input handle ok = $z");
  sleep 5;
  @out = <$fh_out>;
  Forks::Super::close_fh($pid, 'stdout');
  @err = <$fh_err>;
  Forks::Super::close_fh($pid, 'stderr');
  if (!Forks::Super::Config::CONFIG('filehandles')) {
    @err = grep { !/set_signal_pid/ } @err;
  }

  ok(@out == 1 && $out[0] =~ /^Hello/, 
     "open3: time out  \@out='@out'" . scalar @out);
  ok(@err == 0 || $err[0] =~ /timeout/, "open3: job timed out")
      or diag("error was @err\n");
  waitpid $pid,0;
  ok($job->{status} != 0, 
     "open3: job timed out status $job->{status}!=0")  ### 28 ###
    or diag("status was $job->{status}, expected ! 0");
}

#############################################################################
