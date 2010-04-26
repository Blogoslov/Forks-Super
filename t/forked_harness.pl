#! /usr/bin/perl -w
# forked_harness.pl [options] tests
#
# Forks::Super proof-of-concept to run unit tests in parallel
#
# good for
#     fast testing
#       * if you have lots of tests and your framework is mature
#         enough that you expect the vast majority to pass
#       * if you have an intermittent failure and you might
#         need to run a test several times to reproduce
#         the problem
#     stress testing
#       * run your tests under a heavier CPU load
#       * can expose issues caused by multiple instances of
#         your script running at once
#
# options:
#
#  --harness|-h:         wrap tests in the ExtUtils::Command::MM::test_harness
#  --callbacks=[s][f][q]:print debug information when a test starts/finishes
#          |-c [s][f][q] /is queued
#  --verbose|-v:         with -h, use verbose test harness
#  --include|-I lib:     use Perl lib dirs [default: blib/lib, blib/arch]
#  --popts|-p option:    pass option to perl interpreter during test
#                        [e.g.: -p -d:Trace, -p -MCarp::Always]
#  --shuffle|-s:         run tests in random order
#  --timeout|-t n:       abort a test after <n> seconds [default: 120]
#  --repeat|-r n:        do up to <n> iterations of testing. Pause after each
#                        iteration, and abort if iteration had error(s)
#  --xrepeat|-x n:       run each test <n> times in each iteration
#  --maxproc|-m n:       run up to <n> tests simultaneously [default: 9]
#  --quiet|-q:           produce less output (-q is *not* the opposite of -v!)
#  --debug|-d:           produce output about what forked_harness.pl is doing
#  --abort-on-fail|-a:   stop after the first test failure
#  --grep pattern:       grab test output matching <pattern>, print all at end

use lib qw(blib/lib);
use Forks::Super MAX_PROC => 10, ON_BUSY => 'queue';
use Getopt::Long;
use Time::HiRes;
use POSIX ':sys_wait_h';
use strict;
$| = 1;
$^T = Time::HiRes::gettimeofday();

my $timeout = 120;
my $use_harness = '';
my $use_callbacks = '';
my $test_verbose = $ENV{TEST_VERBOSE} || 0;
my @use_libs = qw(blib/lib blib/arch);
my @perl_opts = ();
my $shuffle = '';
my $repeat = 1;
my $xrepeat = 1;
my $quiet = 0;
my $maxproc = &maxproc_initial;
my $check_endgame = 0;
my $abort_on_first_error = '';
my $debug = '';
my @output_patterns = ();
$::fail35584 = '';

# [-h] [-c] [-v] [-I lib [-I lib [...]]] [-p xxx [-p xxx [...]]] [-s] 
# [-t nnn] [-r nnn] [-x nnn] [-m nnn] [-q] [-a] [-g patt [-g patt [...]]

# abcdefghijklmnopqrstuvwxyz
# x s    x@   i  @xixi x i  
my $result = GetOptions("harness" => \$use_harness,
	   "callbacks=s" => \$use_callbacks,
	   "verbose" => \$test_verbose,
	   "include=s" => \@use_libs,
	   "popts=s" => \@perl_opts,
	   "shuffle" => \$shuffle,
	   "timeout=i" => \$timeout,
	   "repeat=i" => \$repeat,
           "xrepeat=i" => \$xrepeat,
	   "maxproc=i" => \$maxproc,
	   "quiet" => \$quiet,
           "debug" => \$debug,
	   "grep=s" => \@output_patterns,
	   "abort-on-fail" => \$abort_on_first_error);
my @captured = ();
my %fail = ();

$test_verbose ||= 0;
$repeat = 1 if $repeat < 1;
$xrepeat = 1 if $xrepeat < 1;
$Forks::Super::MAX_PROC = $maxproc if $maxproc;
$Forks::Super::Util::DEFAULT_PAUSE = 0.10;

my $glob_required = 0;
if (@ARGV == 0) {
  # XXX - read  $(TEST_FILES) from Makefile
  open(MFILE, '<', 'Makefile') 
    or open(MFILE, '<', '../Makefile')
    or die "No test files specified, can't read defaults from Makefile!\n";
  my ($test_files) = grep { /^TEST_FILES\s*=/ } <MFILE>;
  close MFILE;
  $test_files =~ s/\s+=/= /;
  my @test_files = split /\s+/, $test_files;
  shift @test_files;

  @ARGV = @test_files;
  $glob_required = 1;
}

if ($^O eq 'MSWin32' || $glob_required) {
  # might need to glob the command line arg ourselves ...
  my @to_glob = grep { /[*?]/ } @ARGV;
  if (@to_glob > 0) {
    @ARGV = grep { !/[*?]/ } @ARGV;
    push @ARGV, glob($_) foreach @to_glob;
  }
}

my @test_files = (@ARGV) x $xrepeat;
my @result = ();
my $total_status = 0;
my $iteration;
my $ntests = scalar @test_files;
if ($debug) {
  # running too many tests simultaneously will use up all your filehandles ...
  print STDERR "There are $ntests tests to run (", 
    scalar @ARGV, " x $xrepeat)\n";
}
my (%j,$count);

$SIG{SEGV} = \&handle_SIGSEGV;
&main;
if (@captured > 0) {
  print "============================================\n";
  print "|= captured output from all test\n";
  print "|===========================================\n";
  print map {"|- $_"} @captured;
  print "============================================\n\n";
  @captured = ();
}
if (@result > 0) {
  print "\n\n\n\n\nThere were errors in iteration #$iteration:\n";
  print "----------------------------------\n";
  print @result;

  open(LOG, ">>", "/tmp/forked_harness.log");
  print LOG scalar localtime, "\n";
  print LOG @result;
  print LOG "=====================================\n";
  close LOG;

  print "\n\n\n\n\n\n\n\n\n\n";
  print scalar localtime, "\n";
  print @result;
  print "=====================================\n";
}
if (scalar keys %fail > 0) {
  print "\nTest failures:\n";
  print "==============\n";
  foreach my $test_file (sort keys %fail) {
    foreach my $test_no (sort {$a<=>$b} keys %{$fail{$test_file}}) {
      print "\t$test_file#$test_no ";
      if ($fail{$test_file}{$test_no} == 1) {
	print "1 time\n";
      } else {
	print "$fail{$test_file}{$test_no} times\n";
      }
    }
  }
  print "================\n";
}

sub handle_SIGSEGV {
  use Carp;
  print STDERR "\n" x 10;
  Carp::confess "SIGSEGV caught in $0 @ARGV\n";
}

sub main {
  if ($debug) {
    print "Test files: @test_files\n";
  }

  for ($iteration = 1; $iteration <= $repeat; $iteration++) {
    print "Iteration #$iteration/$repeat\n" if $repeat>1;
    if ($iteration > 1) {
      sleep 1;
    }

    if ($shuffle) {
      for (my $j = $#test_files; $j >= 1; $j--) {
	my $k = int($j * rand());
	($test_files[$j],$test_files[$k]) = ($test_files[$k],$test_files[$j]);
      }
    }

    %j = ();
    $count = 0;

    foreach my $test_file (@test_files) {
      launch_test_file($test_file);

      if ($debug) {
	print "Queue size: ", scalar @Forks::Super::Queue::QUEUE, "\n";
      }

      if (rand() > 0.95 || @Forks::Super::Queue::QUEUE > 0) {
	my $reap = waitpid -1, WNOHANG;
	while (Forks::Super::isValidPid($reap)) {
	  return if &process($reap) eq "ABORT";
	  $reap = -1;
	  $reap = waitpid -1, WNOHANG;
	}
      }
    }

    if ($debug) {
      print "All tests launched for this iteration, waiting for results.\n";
    }

    while (Forks::Super::Util::isValidPid(my $pid = wait)) {

      return if &process($pid) eq "ABORT";

    }
    if ($total_status > 0) {
      last;
    }
  }  # next iteration
  return;
}

if ($total_status == 0) {
  $iteration--;
  print "All tests successful. $iteration iterations.\n";
}

my $elapsed = Time::HiRes::gettimeofday() - $^T;
printf "Elapsed time: %.3f\n", $elapsed; sleep 3 if $debug;



# Ideally,
#   * There are no stray .fhfork<nnn> directories
#   * There are no stray processes
&check_endgame if $check_endgame;

exit $total_status >> 8;

sub launch_test_file {
  my ($test_file) = @_;
  my ($test_harness, @cmd);
  if ($use_harness) {
    $test_harness = "test_harness($test_verbose";
    $test_harness .= ",'$_'" foreach @use_libs;
    $test_harness .= ")";
    @cmd = ($^X, "-MExtUtils::Command::MM", "-e",
	    $test_harness, $test_file);
  } else {
    @cmd = ($^X, @perl_opts, (map{"-I$_"}@use_libs), $test_file);
  }

  my $callbacks = {};
  if ($use_callbacks =~ /q/) {
    $callbacks->{queue} = sub { print "Queue $test_file\n" };
  }
  if ($use_callbacks =~ /s/) {
    $callbacks->{start} = sub { print "Start $test_file\n" };
  }
  if ($use_callbacks =~ /f/) {
    $callbacks->{finish} = sub { print "Finish $test_file\n" };
  }
  
  if ($debug) {
    print "Launching test $test_file:\n";
  }
  my $pid = fork {
    cmd => [ @cmd ],
      child_fh => "out,err",
	callback => $callbacks,
	  timeout => $timeout
	};

  $j{$pid} = $test_file;
  $j{"$test_file:pid"} = $pid;
  $j{"$pid:count"} = ++$count;
  $j{"$test_file:iteration"} = $iteration;
}

sub process {
  my ($pid) = @_;

  # keep track of what else is running right now
  my @jj = grep { $_->{state} eq "ACTIVE" } @Forks::Super::ALL_JOBS;

  my $j = Forks::Super::Job::get($pid);
  my $status = $j->{status};
  my $test_file = $j{$j->{pid}};
  my $test_time = sprintf '%.3fs', $j->{end} - $j->{start};
  my @stdout = Forks::Super::read_stdout($pid);
  my @stderr = Forks::Super::read_stderr($pid);
  $j->close_fh;

  if ($debug) {
    print "Processing results of test $test_file\n";
  }

  my $redo = 0;

  if ($^O eq "linux" && $status == 35584) {
    $redo++;
  }

  my $pp = $j->{pid};
  my $count = $j{"$pp:count"};
  my $iter = $j{"$test_file:iteration"};
  my $dashes = "-" x (40 + length($test_file));
    
  # print "\n$dashes\n";
  print "------------------- $test_file -------------------\n";
  print "|= TEST=$iter.$count/$repeat.$ntests; ",
    "STATUS[$test_file]: $status \[ $total_status + $::fail35584 \] ",
    "TIME=$test_time\n";

  if ($status > 0 || $quiet == 0) {
    print map{"|- $_"}@stdout;
    print "$dashes\n";
    print map{"|- $_"}@stderr;
  }

  my @s = @stdout;
  my $not_ok = 0;
  foreach my $s (@s) {
    if ($s =~ /^not ok (\d+)/) {
      $fail{$test_file}{$1}++;
      $not_ok++;
    }
    foreach my $pattern (@output_patterns) {
      if ($s =~ qr/$pattern/) {
	push @captured, "$test_file: $s";
	last;
      }
    }
  }
  if ($status == 35584 && $not_ok == 0) {
    $redo++;
  }
  # XXX elsif ($quiet && $use_harness) { should summarize test results }

  if (grep { /^Failed/ && /100.00% okay/ } @stderr) {
    $redo++;
  }

  if ($redo) {

    # in Forks::Super module testing, we observe an
    # intermittent segmentation fault that occurs after
    # a test has passed. It seems to occur when the
    # module and/or the perl interpreter are cleaning up,
    # and it causes the test to be marked as failed, even if
    # all of the individual tests were ok.
    # Rerun this test if we trap the condition.

    print "Received status == $status for a test of $test_file, ",
      "possibly an intermittent segmentation fault. Rerunning ...\n";
    launch_test_file($test_file);
    $::fail35584++;
    return $::fail35584 > 10 * $j{"$test_file:iteration"} 
      ? "ABORT" : "CONTINUE";
  }







  # print "$dashes\n";

  $total_status = $status if $total_status < $status;
  if ($status != 0) {
    if (!$use_harness 
	|| (grep /Result: FAIL/, @stdout)
        || (grep /Failed Test/, @stdout)) {
      push @result, "Error in $test_file: $status / $total_status\n";
      push @result, "--------------------------------------\n";
      push @result, 
	@stdout, "-----------------------------------\n", 
	  @stderr, "===================================\n";
    } else {
      $status = 0;
    }
  }
  my $num_dequeued = 0;
  my $num_terminated = 0;
  if ($total_status > 0 && $abort_on_first_error) {
    foreach my $j (@Forks::Super::Queue::QUEUE) {
      $j->mark_complete;
      $j->{status} = -1;
      $num_dequeued++;
      Forks::Super::Queue::queue_job();
    }
    foreach my $j (@Forks::Super::ALL_JOBS) {
      next if ref $j ne "Forks::Super::Job";
      next if not defined $j->{status};
      if ($j->{status} eq "ACTIVE" 
	  && Forks::Super::isValidPid($j->{real_pid})) {
	$num_terminated += kill 'TERM', $j->{real_pid};
      }
    }
    print STDERR "Removed $num_dequeued jobs from queue; ",
      "terminated $num_terminated active jobs.\n";
    $abort_on_first_error = 2;
    return "ABORT";
  }
  return $total_status > 0 && $abort_on_first_error ? "ABORT" : "CONTINUE";
}




#
# this subroutine is specific to *testing* the Forks::Super module.
# If you are adapting this script for other purposes, you can
# leave this part out.
#
sub check_endgame {

  # Forks::Super shouldn't leave temporary dirs/files around
  # after testing, but it might

  my $x = $Forks::Super::FH_DIR;
  if (!defined $x) {
    my $p = fork { child_fh => "out", sub => {} };
    waitpid $p, 0;
    $x = $Forks::Super::FH_DIR;
  }

  print "Checking endgame\n";
  sleep 12;

  my @fhforks = ();
  opendir(D, $x);
  while (my $g = readdir(D)) {
    if ($g =~ /^.fhfork/) {
      opendir(E, "$x/$g");
      my $gg = readdir(E);
      closedir E;
      $gg -= 2;
      print STDERR "Directory $x/$g still exists with $gg files\n";
    }
  }
  closedir D;

  $0 = "-";
  # to do: check the process table and see if any of the
  #    processes came from here ...
}

#
# find good initial setting for $Forks::Super::MAX_PROC.
# This can be overridden with -m|--maxproc command-line arg.
#
sub maxproc_initial {
  if ($ENV{MAX_PROC}) {
    return $ENV{MAX_PROC};
  }
  eval {
    require Sys::CpuAffinity;
  };
  if ($@) {
    return 9;
  }
  my $n = Sys::CpuAffinity::getNumCpus();
  if ($n <= 0) {
    return 9;
  }
  my @mask = Sys::CpuAffinity::getAffinity($$);
  if (@mask < $n) {
    $n = @mask;
  }
  if ($n == 1) {
    return 4;
  } elsif ($n == 2) {
    return 6;
  } else {
    return int(2 * $n + 1);
  }
}


__END__

