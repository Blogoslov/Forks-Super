# forked_harness.pl [options] tests
#
# Forks::Super proof-of-concept to run unit tests in parallel.
#
# this framework is good for
#     fast testing
#       * if you have lots of tests and your distribution is mature
#         enough that you expect the vast majority to pass
#       * if you have an intermittent failure and you might
#         need to run a test many many times to reproduce
#         a problem
#     stress testing
#       * run your tests under a heavier CPU load
#       * expose issues caused by multiple instances of
#         a test script running at once
#
# The Makefile for the Forks::Super module includes additional targets
# that use this script:
#
#     # fasttest -- run all tests once, in "parallel" (using
#     #    Forks::Super to manage and throttle the tests)
#     fasttest :: pure_all
#           $(PERLRUN) t/forked_harness.pl $(TEST_FILES) -h
#
#     # stresstest -- run all tests 100 times, in parallel
#     stresstest :: pure_all
#           $(PERLRUN) t/forked_harness.pl $(TEST_FILES) -r 20 -x 5 -s -q
#
#
# options:
#
#  --harness|-h:         wrap tests in the ExtUtils::Command::MM::test_harness
#  --verbose|-v:         with -h, use verbose test harness
#  --include|-I lib:     use Perl lib dirs [default: blib/lib, blib/arch]
#  --popts|-p option:    pass option to perl interpreter during test
#                        [e.g.: -p -d:Trace, -p -MCarp::Always]
#  --shuffle|-s:         run tests in random order
#  --timeout|-t n:       abort a test after <n> seconds [default: 150]
#  --repeat|-r n:        do up to <n> iterations of testing. Pause after each
#                        iteration, and abort if iteration had error(s)
#  --xrepeat|-x n:       run each test <n> times in each iteration
#  --maxproc|-m n:       run up to <n> tests simultaneously
#  --quiet|-q:           produce less output (-q is *not* the opposite of -v!)
#  --really-quiet|--qq   just show test status, no other output
#  --debug|-d:           produce output about what forked_harness.pl is doing
#  --abort-on-fail|-a:   stop after the first test failure
#  --color|-C:           colorize output (requires Term::ANSIColor >=3.00)
#  --env|-E var=value:   pass environment variable value to the tests
#
# Environment:
#  COLOR                 if true, try to colorize output [like -C flag]
#  ENDGAME_CHECK         if true, check that program cleans up after itself
#  MAX_PROC              default max processes [like -m flag]
#  TEST_VERBOSE          if true, use verbose test harness [like -v flag]
#

BEGIN {
  if ($^O eq 'MSWin32' && $ENV{IPC_DIR} eq 'undef') {
    delete $ENV{IPC_DIR};
    push @ARGV, "-E", "undef";
  }
}

use lib qw(blib/lib blib/arch lib .);
use Forks::Super MAX_PROC => 10, ON_BUSY => 'queue';
use IO::Handle;
use Getopt::Long;
eval "use Time::HiRes;1" 
  or do { *Time::HiRes::time = sub { time } };
use POSIX ':sys_wait_h';
use strict;
use warnings;
$| = 1;
$^T = Time::HiRes::time();
if (${^TAINT}) {
  if ($^O eq 'MSWin32') {
    ($ENV{PATH}) = $ENV{PATH} =~ /(.*)/;
  } else {
    $ENV{PATH} = "/bin:/usr/bin:/usr/local/bin";
  }
  ($^X)=$^X=~/(.*)/;
  ($ENV{HOME})=$ENV{HOME}=~/(.*)/;
  @ARGV = map /(.*)/, @ARGV;
}

my @use_libs = qw(blib/lib blib/arch);
my @perl_opts = ();
my @env = ();
my $maxproc = &maxproc_initial;
my $use_color = $ENV{COLOR} && -t STDOUT &&
  eval { use Term::ANSIColor; $Term::ANSIColor::VERSION >= 3.00 };
my $timeout = 150;
my $repeat = 1;
my $xrepeat = 1;
my $test_verbose = $ENV{TEST_VERBOSE} || 0;
my $check_endgame = $ENV{ENDGAME_CHECK} || 0;
my $quiet = 0;
my $really_quiet = 0;
my $abort_on_first_error = 0;
my $use_harness = '';
my $shuffle = '';
my $debug = '';
my $use_socket = '';
$::fail35584 = '';

# [-h] [-c] [-v] [-I lib [-I lib [...]]] [-p xxx [-p xxx [...]]] [-s] 
# [-t nnn] [-r nnn] [-x nnn] [-m nnn] [-q] [-a] 
# abcdefghijklmnopqrstuvwxyz
# x s    x@   i  @xixi x i x 
my $result = GetOptions("harness" => \$use_harness,
	   "C|color" => \$use_color,
	   "verbose" => \$test_verbose,
	   "include=s" => \@use_libs,
	   "popts=s" => \@perl_opts,
	   "env=s" => \@env,
	   "s|shuffle" => \$shuffle,
	   "timeout=i" => \$timeout,
	   "r|repeat=i" => \$repeat,
           "xrepeat=i" => \$xrepeat,
	   "maxproc=i" => \$maxproc,
	   "q|quiet" => \$quiet,
	   "qq|really-quiet" => \$really_quiet,
           "debug" => \$debug,
	   "z|socket" => \$use_socket,
	   "abort-on-fail" => \$abort_on_first_error);
my %fail = ();
if ($ENV{TAINT_CHECK} || ${^TAINT}) {
  @perl_opts = map { /(.*)/ } @perl_opts;
  push @perl_opts, "-T";
}

$test_verbose ||= 0;
$repeat = 1 if $repeat < 1;
$xrepeat = 1 if $xrepeat < 1;
$quiet ||= $really_quiet;
$Forks::Super::MAX_PROC = $maxproc if $maxproc;
$Forks::Super::ON_BUSY = 'block' if $ENV{BLOCK};
sub color_print;

# these colors are appropriate when your terminal has a dark background.
# How can this program determine when your terminal has a dark background?
my %colors = (ITERATION => 'bold white',
	      GOOD_STATUS => 'bold green',
	      BAD_STATUS => 'bold red',
	      'STDERR' => 'yellow bold',
	      NORMAL => '');


#####################################################3
#
# determine the set of test scripts to run
#


my $glob_required = 0;
if (@ARGV == 0) {
  # read  $(TEST_FILES) from Makefile
  my $mfile;
  open($mfile, '<', 'Makefile') 
    or open($mfile, '<', '../Makefile')
    or die "No test files specified, can't read defaults from Makefile!\n";
  my ($test_files) = grep { /^TEST_FILES\s*=/ } <$mfile>;
  close $mfile;
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
my $total_fail = 0;
my $iteration;
my $ntests = scalar @test_files;
if ($debug) {
  # running too many tests simultaneously will use up all your filehandles ...
  print STDERR "There are $ntests tests to run (", 
    scalar @ARGV, " x $xrepeat)\n";
}
my (%j,$count);

&main;
&summarize;
&check_endgame if $check_endgame;
exit ($total_fail > 254 ? 254 : $total_fail);
# exit ($total_status > 254 << 8 ? 254 : $total_status >> 8);

##################################################################
#
# iterate over list of test files and run tests in background processes.
# when child processes are reaped, dispatch &process_test_output
# to analyze the output
#
sub main {
  if ($debug) {
    print "Test files: @test_files\n";
  }
  if (@test_files == 0) {
    die "No tests specified.\n";
  }

  for ($iteration = 1; $iteration <= $repeat; $iteration++) {
    color_print 'ITERATION', "Iteration #$iteration/$repeat\n" if $repeat>1;
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

      $test_file =~ /(.*)/;
      $test_file = $1;
      
      launch_test_file($test_file);

      if ($debug) {
	print "Queue size: ", scalar @Forks::Super::Queue::QUEUE, "\n";
      }

      # see if any tests have finished lately
      my $reap = waitpid -1, WNOHANG;
      while (Forks::Super::Util::isValidPid($reap)) {
	return if process_test_output($reap) eq "ABORT";
	$reap = -1;
	$reap = waitpid -1, WNOHANG;
      }
    }

    # all tests have launched. Now wait for all tests to complete.

    if ($debug) {
      print "All tests launched for this iteration, waiting for results.\n";
    }

    my $pid = wait;
    while (Forks::Super::Util::isValidPid($pid)) {
      return if process_test_output($pid) eq "ABORT";
      $pid = wait;
    }
    if ($total_status > 0) {
      last;
    }
  }  # next iteration
  return;
}

# read the options to the perl interpreter from a shebang line
#     #! perl -w -T     ==>  (-w, -T)
sub _get_perl_opts {
  my ($file) = @_;
  open my $ph, '<', $file or return ();
  my $shebang = <$ph>;
  close $ph;
  return $shebang =~ /^#!/ ? grep { /^-/ } split /\s+/, $shebang : ();
}

sub launch_test_file {
  my ($test_file) = @_;
  my ($test_harness, @cmd);
  if (grep { /^-t$/i } @perl_opts) {
    $ENV{PATH} = "";
  }
  if ($use_harness) {
    $test_harness = "test_harness($test_verbose";
    $test_harness .= ",'$_'" foreach @use_libs;
    $test_harness .= ")";
    if ($] < 5.007) {
      @cmd = ($^X, '-Iblib/lib', '-Iblib/arch', 
	      '-e', 'use Test::Harness qw(&runtests $verbose);',
	      '-e', '$verbose=0;', 
	      '-e', 'runtests @ARGV',
	      $test_file);
    } else {
      @cmd = ($^X, "-MExtUtils::Command::MM", "-e",
	      $test_harness, $test_file);
    }
  } else {
    my @extra_opts = _get_perl_opts($test_file);
    @cmd = ($^X, @perl_opts, @extra_opts, (map{"-I$_"}@use_libs), $test_file);
  }

  if ($debug) {
    print "Launching test $test_file:\n";
  }
  my $child_fh = "out,err";
  $child_fh .= ",socket" if $use_socket;
  if ($] < 5.007) {
    # workaround for Cygwin 5.6.1 where sockets/pipes
    # don't function right ...
    $child_fh = "in,$child_fh";
  }

  @cmd = map /(.*)/, @cmd if ${^TAINT};
  foreach my $env (@env) {
    my ($k,$v) = split /=/, $env, 2;
    $ENV{$k} = $v;
  }
  my $pid = fork {
    cmd => [ @cmd ],
    child_fh => $child_fh,
    timeout => $timeout,
  };

  $j{$pid} = $test_file;
  $j{"$test_file:pid"} = $pid;
  $j{"$pid:count"} = ++$count;
  $j{"$test_file:iteration"} = $iteration;
}

sub process_test_output {
  my ($pid) = @_;

  # keep track of what else is running right now
  my @jj = grep { $_->{state} eq "ACTIVE" } @Forks::Super::ALL_JOBS;

  my $j = Forks::Super::Job::get($pid);
  my $status = $j->{status};
  my $test_file = $j{$j->{pid}};
  my $test_time = sprintf '%6.3fs', $j->{end} - $j->{start};
  my @stdout = Forks::Super::read_stdout($pid);
  my @stderr = Forks::Super::read_stderr($pid);
  $j->close_fh;

  if ($debug) {
    print "Processing results of test $test_file\n";
  }

  # see which tests failed ...
  my @s = @stdout;
  my $not_ok = 0;
  foreach my $s (@s) {
    if ($s =~ /^not ok (\d+)/) {        # raw test output
      $fail{$test_file}{$1}++;
      $not_ok++;
    }

    # ExtUtils::MM::test_harness output
    elsif ($s =~ /Failed tests?:\s+(.+)/
       || $s =~ /DIED. FAILED tests? (.+)/) {
      my @failed_tests = split /\s*,\s*/, $1;
      foreach my $failed_test (@failed_tests) {
	my ($test1,$test2) = split /-/, $failed_test;
	$test2 ||= $test1;
	$fail{$test_file}{$_}++ for $test1..$test2;
      }
      $not_ok++;
    }
    elsif ($s =~ /Non-zero exit status: (\d+)/) {
      my $actual_status = $status & 0xFF00;
      my $expected_status = $1 << 8;
      if ($actual_status != $expected_status) {
	warn "Status $status from test $test_file does not match ",
	  "reported exit status $expected_status\n";
      }
      $fail{$test_file} ||= {"NZEC_$expected_status" => 1};
      $not_ok++;
    }
    elsif ($s =~ /Non-zero wait status: (\d+)/) {
      my $actual_status = $status;
      my $expected_status = $1;
      if ($actual_status != $expected_status) {
	warn "Status $status from test $test_file does not match ",
	  "reported wait status $expected_status\n";
      }
      $fail{$test_file}{"NZWS_$expected_status"}++;
      $not_ok++;
    }
    elsif ($s =~ /Result: FAIL/) {
      # even if all tests pass, exit status is zero,
      # test could fail if you didn't follow the plan
      $fail{$test_file} ||= { "BadPlan" => 1 };
      $not_ok++;
    }
  }
#  if ($use_harness && $quiet && $not_ok == 0) {
  if ($use_harness && $not_ok == 0) {
    # look for one of:
    #     t/nn-xxx.t .. ok
    #     t/nn-xxx.t....ok
    my @stdout2 = grep { / ?\.+ ?ok/ } @stdout;
    if (@stdout2 > 0) {
      @stdout = @stdout2;
    } else {
      # the output didn't say anything about test failures and
      # the exit code was zero, but the output also didn't say "ok" --
      # this test is not quite right.
      # Could have timed out.
      $not_ok = 0.5;
      $status = 0.5;

      if ($j->{end} && $j->{timeout}
	  && $j->{end} - $j->{start} >= $j->{timeout} * 0.99) {
	  $fail{$test_file}{"TIMEOUT"}++;
      } else {
	  $fail{$test_file}{"Unknown Error"}++;
      }

      unless ($really_quiet) {
	color_print 'STDERR', "Not quite right: ", $j->toString(), "\n";
	color_print 'STDERR', "OUTPUT: ", @stdout, "\n";
	color_print 'STDERR', "ERROR: ", @stderr, "\n";
      }
    }
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
  my $status_color = $status > 0 ? 'BAD_STATUS' : 'GOOD_STATUS';
  my $sep_color = $status > 0 ? 'BAD_STATUS' : 'NORMAL';
  if ($quiet == 0 || $status > 0) {
    if ($really_quiet == 0) {
      color_print $sep_color, "------------------- $test_file -------------------\n";
    }
  }
  my $aggr_status = $::fail35584 
    ? "$total_status+$::fail35584" : $total_status;
  my $test_id = sprintf "%*s", 
    2*length("$repeat$ntests")+3, "$iter.$count/$repeat.$ntests";

  if ($use_harness && $quiet && $not_ok == 0) {
    if (1 || $really_quiet < 0) {
      color_print $status_color, "|= test=$test_id; ",
	"status: $status/$aggr_status ","time=$test_time ", "| ", @stdout;
    }
  } else {
    if ($status > 0 || $really_quiet == 0) {
      color_print $status_color, "|= test=$test_id; ",
	"status: $status/$aggr_status time=$test_time | $test_file\n";
    } else {
      print " test=$test_id | $test_file $status             \r";
      *STDOUT->flush;
    }
  }

  if ($status > 0 || $quiet == 0) {
    if ($really_quiet == 0) {
      print map{"|- $_"}@stdout;
      print "|= $dashes\n";
      color_print 'STDERR', map{"|: $_"}@stderr;
    }
  }

  # there are some circumstances where the tests passed but there
  # was some intermittent error during cleanup. Detect some of these
  # and redo the test.

  if (grep { /^Failed/ && /100.00% okay/ } @stderr) {
    $redo++;
  } elsif ($use_harness && grep /All \d+ subtests passed/, @stdout) {
    $redo++;
  } elsif ($status == 35584 && $not_ok == 0) {
    $redo++;
  } elsif ($status != 0 && $not_ok == 0) {
    $fail{$test_file}{'unknown'} += 1;
  }
  # elsif ($quiet && $use_harness) { should summarize test results }

  if ($redo) {

    # in Forks::Super module testing, we observe an
    # intermittent segmentation fault that occurs after
    # a test has passed. It seems to occur when the
    # module and/or the perl interpreter are cleaning up,
    # and it causes the test to be marked as failed, even if
    # all of the individual tests were ok.
    # <strike>Rerun this test if we trap the condition.</strike>

    print "Received status == $status for a test of $test_file, ",
      "possibly an intermittent segmentation fault. Rerunning ...\n";
    launch_test_file($test_file);
    $::fail35584++;
    #return $::fail35584 > 10 * $j{"$test_file:iteration"} 
    #  ? "ABORT" : "CONTINUE";
    return "ABORT";
  }







  # print "$dashes\n";

  $total_status = $status if $total_status < $status;
  $total_fail += $status >> 8 if $status > 0;
  if ($status != 0) {
    if (!$use_harness 
	|| (grep /Result: FAIL/, @stdout)
        || (grep /Failed Test/, @stdout)) {
      if ($abort_on_first_error == 0) {
	push @result, "Error in $test_file: $status / $total_status\n";
	push @result, "--------------------------------------\n";
	push @result, 
	  @stdout, "-----------------------------------\n", 
	    @stderr, "===================================\n";
      }
    } else {
      # $status = 0;
    }
  }
  my $num_dequeued = 0;
  my $num_terminated = 0;
  if ($total_status > 0 && $abort_on_first_error) {
    foreach my $j (@Forks::Super::Queue::QUEUE) {
      $j->_mark_complete;
      $j->{status} = -1;
      $num_dequeued++;
      Forks::Super::Queue::queue_job();
    }
    foreach my $j (@Forks::Super::ALL_JOBS) {
      next if ref $j ne "Forks::Super::Job";
      next if not defined $j->{status};
      if ($j->{status} eq "ACTIVE" 
	  && Forks::Super::Util::isValidPid($j->{real_pid})) {
	$num_terminated += kill 'TERM', $j->{real_pid};
      }
    }
    print STDERR "Removed $num_dequeued jobs from queue; ",
      "terminated $num_terminated active jobs.\n";
    $abort_on_first_error = 2;
    return "ABORT";
  }
  $j->dispose;
  return $total_status > 0 && $abort_on_first_error ? "ABORT" : "CONTINUE";
}


sub summarize {
  if (@result > 0) {
    print "\n\n\n\n\nThere were errors in iteration #$iteration:\n";
    print "=====================================\n";
    print scalar localtime, "\n";
    print @result;
    print "=====================================\n";
    print "\n\n\n\n\n";
  }
  if ($really_quiet == 0 && scalar keys %fail > 0) {
    print "\nTest failures:\n";
    print "================\n";
    foreach my $test_file (sort keys %fail) {
	no warnings 'numeric';
	foreach my $test_no (sort {
	    $a+0<=>$b+0 || $a cmp $b
	} keys %{$fail{$test_file}}) {
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
  if ($total_status == 0) {
    $iteration--;
    print "All tests successful. $iteration iterations.\n";
  }
  my $elapsed = Time::HiRes::time() - $^T;
  printf "Elapsed time: %.3f\n", $elapsed; sleep 3 if $debug;
}

#
# make sure the Forks::Super module is cleaning up after itself.
# This is mainly helpful for testing the Forks::Super module.
#
sub check_endgame {
  print "Checking endgame $Forks::Super::IPC_DIR\n";

  # fork so the main process can exit and the Forks::Super
  # module can start cleanup.

  # Forks::Super shouldn't leave temporary dirs/files around
  # after testing, but it might

  my $x = $Forks::Super::IPC_DIR;
  if (!defined $x) {
    my $p = fork { child_fh => "out", sub => {} };
    waitpid $p, 0;
    $x = $Forks::Super::IPC_DIR;
  }

  CORE::fork() && return;

  sleep 12;

  my @fhforks = ();
  opendir(D, $x);
  while (my $g = readdir(D)) {
    if ($g =~ /^.fh/) {
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
# This can be overridden with -m|--maxproc command-line arg
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
    $n = @mask || $n;
  }
  if ($n == 1) {
    return 4;
  } elsif ($n == 2) {
    return 6;
  } else {
    return int(2 * $n + 1);
  }
}

# if appropriate and suppported, enhance output to STDOUT with color.
sub color_print {
  my ($color, @msg) = @_;
  if ($color eq '' || !$use_color) {
    return print STDOUT @msg;
  }
  $color = $colors{$color} if defined $colors{$color};
  if (@msg > 0 && chomp($msg[-1])) {
    return print STDOUT colored([$color], @msg), "\n";
  }
  return print STDOUT colored([$color], @msg);
}
sub color_printf { color_print shift, sprintf @_ }
