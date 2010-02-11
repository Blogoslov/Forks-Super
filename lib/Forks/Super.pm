package Forks::Super;
use Tie::Enum;
use 5.007003;     # for "safe" signals -- see perlipc
use Exporter;
use POSIX ':sys_wait_h';
use Carp;
use File::Path;
use IO::Handle;
use strict;
use warnings;
$| = 1;

our $VERSION = '0.13';
use base 'Exporter'; # our @ISA = qw(Exporter);

our @EXPORT = qw(fork wait waitall waitpid);
our @EXPORT_OK = qw(isValidPid pause Time read_stdout read_stderr bg_eval);
our %EXPORT_TAGS = ( 'test' =>  [ 'isValidPid', 'Time', 'bg_eval' ],
		     'test_config' => [ 'isValidPid', 'Time', 'bg_eval' ],
		     'all' => [ @EXPORT_OK ] );

sub _init {
  return if $Forks::Super::INITIALIZED;
  $Forks::Super::INITIALIZED++;
  $Forks::Super::MAIN_PID = $$;
  # open(Forks::Super::DEBUG, '>&',STDERR)   # "bareword" in v5.6.x
  open(Forks::Super::DEBUG, '>&STDERR') 
    or *Forks::Super::DEBUG = *STDERR 
    or carp "Debugging not available in Forks::Super module!\n";
  *Forks::Super::DEBUG->autoflush(1);
  $Forks::Super::REAP_NOTHING_MSGS = 0;
  $Forks::Super::NUM_PAUSE_CALLS = 0;
  $Forks::Super::NEXT_DEFERRED_ID = -100000;
  %Forks::Super::CONFIG = ();

  $Forks::Super::MAX_PROC = 0;
  $Forks::Super::MAX_LOAD = 0;
  $Forks::Super::DEBUG = $ENV{FORKS_SUPER_DEBUG} || "0";
  $Forks::Super::CHILD_FORK_OK = 0;
  $Forks::Super::QUEUE_MONITOR_FREQ = 30;
  $Forks::Super::DONT_CLEANUP = 0;
  $Forks::Super::DEFAULT_PAUSE = 0.25;
  $Forks::Super::SIGNALS_TRAPPED = 0;
  $Forks::Super::SOCKET_READ_TIMEOUT = 1.0;

  tie $Forks::Super::ON_BUSY, 'Tie::Enum', qw(block fail queue);
  tie $Forks::Super::QUEUE_INTERRUPT, 'Tie::Enum', ('', keys %SIG);
  $Forks::Super::ON_BUSY = 'block';
  $Forks::Super::QUEUE_INTERRUPT = 'USR1' if grep {/USR1/} keys %SIG;

  $SIG{CHLD} = \&Forks::Super::handle_CHLD;
  $Forks::Super::INHIBIT_QUEUE_MONITOR = $^O eq "MSWin32";
  return;
}

sub import {
  my ($class,@args) = @_;
  my @tags;
  _init();
  for (my $i=0; $i<@args; $i++) {
    if ($args[$i] eq "MAX_PROC") {
      $Forks::Super::MAX_PROC = $args[++$i];
    } elsif ($args[$i] eq "MAX_LOAD") {
      $Forks::Super::MAX_LOAD = $args[++$i];
    } elsif ($args[$i] eq "DEBUG") {
      $Forks::Super::DEBUG = $args[++$i];
    } elsif ($args[$i] eq "ON_BUSY") {
      $Forks::Super::ON_BUSY = $args[++$i];
    } elsif ($args[$i] eq "CHILD_FORK_OK") {
      $Forks::Super::CHILD_FORK_OK = $args[++$i];
    } elsif ($args[$i] eq "QUEUE_MONITOR_FREQ") {
      $Forks::Super::QUEUE_MONITOR_FREQ = $args[++$i];
    } elsif ($args[$i] eq "QUEUE_INTERRUPT") {
      $Forks::Super::QUEUE_INTERRUPT = $args[++$i];
    } elsif ($args[$i] eq "FH_DIR") {
      my $dir = $args[++$i];
      if ($dir =~ /\S/ && -d $dir && -r $dir && -w $dir && -x $dir) {
	Forks::Super::Job::_set_fh_dir($dir);
      } else {
	carp "Invalid value \"$dir\" for FH_DIR: $!";
      }
    } else {
      push @tags, $args[$i];
    }
  }

  $Forks::Super::IMPORT{$_}++ foreach @tags;
  Forks::Super->export_to_level(1, "Forks::Super", @tags, @EXPORT);
  return;
}

################# to export ###################


sub fork {
  my ($opts) = @_;
  if (ref $opts ne 'HASH') {
    $opts = { @_ };
  }

  my $job = Forks::Super::Job->new($opts);
  $job->preconfig;
  if (defined $job->{__test}) {
    return $job->{__test};
  }

  _debug('fork(): ', $job->toString(), ' initialized.') if $job->{debug};

  until ($job->can_launch) {

    _debug("fork(): job can not launch. Behavior=$job->{_on_busy}")
      if $job->{debug};

    if ($job->{_on_busy} eq "FAIL") {
      $job->run_callback("fail");
      return -1;
    } elsif ($job->{_on_busy} eq "QUEUE") {
      $job->run_callback("queue");
      queue_job($job);
      return $job->{pid};
    } else {
      pause();
    }
  }

  _debug('Forks::Super::fork(): launch approved for job')
    if $job->{debug};
  return $job->launch;
}

sub wait {
  debug("invoked Forks::Super::wait") if $Forks::Super::DEBUG;
  return Forks::Super::waitpid(-1,0);
}

sub waitpid {
  my ($target,$flags,@dummy) = @_;
  if ($^O eq "MSWin32") {
    handle_CHLD(-1);
  }

  if (@dummy > 0) {
    carp "Too many arguments for Forks::Super::waitpid()";
    foreach my $dflag (@dummy) {
      $flags |= $dflag;
    }
  }
  if (not defined $flags) {
    carp "Not enough arguments for Forks::Super::waitpid()";
    $flags = 0;
  }

  # waitpid:
  #   -1:    wait on any process
  #   t>0:   wait on process #t
  #    0:    wait on any process in current process group
  #   -t:    wait on any process in process group #t

  # return -1 if there are no eligible procs to wait for
  my $no_hang = ($flags & WNOHANG) != 0;
  if (_is_number($target) && $target == -1) {
    return _waitpid_any($no_hang);
  } elsif (defined $Forks::Super::ALL_JOBS{$target}) {
    return _waitpid_target($no_hang, $target);
  } elsif (0 < (my @wantarray = Forks::Super::Job::getByName($target))) {
    return _waitpid_name($no_hang, $target);
  } elsif (!_is_number($target)) {
    return -1;
  } elsif ($target > 0) {
    # invalid pid
    return -1;
  } elsif (Forks::Super::CONFIG("getpgrp")) {
    if ($target == 0) {
      $target = getpgrp();
    } else {
      $target = -$target;
    }
    return _waitpid_pgrp($no_hang, $target);
  } else {
    return -1;
  }
}

sub _is_number {
  my $a = shift;
  $a =~ s/^\s+//;
  $a =~ s/\s+$//;
  $a =~ s/e[+-]?\d+$//;
  $a =~ s/^[\+\-]//;
  $a =~ /^\d+.?\d*$/ || $a =~ /^\.\d+/;
}

sub waitall {
  debug("Forks::Super::waitall(): waiting on all procs")
    if $Forks::Super::DEBUG;
  do {
    run_queue() if @Forks::Super::QUEUE > 0;
  } while isValidPid(Forks::Super::wait);
  return 1;  # future enhancement: allow timeout and return 0 or -1 on timeout
}

##################################################################



# optional exported functions

# a portable way to check the return value of fork()
# and see if the call succeeded. For a fork() call that
# results in a "deferred" job, this function will
# return zero.
sub isValidPid {
  my ($pid) = @_;
  return $^O eq "MSWin32"
    ? $pid != 0 && $pid != -1 && $pid >= -50000
    : $pid > 0;
}

##################################################################

# wait on any process
sub _waitpid_any {
  my ($no_hang) = @_;
  my ($pid, $nactive) = _reap();
  unless ($no_hang) {
    while (!isValidPid($pid) && $nactive > 0) {
      pause();
      ($pid, $nactive) = _reap();
    }
  }
  if (defined $Forks::Super::ALL_JOBS{$pid}) {
    pause() while not defined $Forks::Super::ALL_JOBS{$pid}->{status};
    $? = $Forks::Super::ALL_JOBS{$pid}->{status};
  }
  return $pid;
}

# wait on a specific process
sub _waitpid_target {
  my ($no_hang, $target) = @_;
  my $job = $Forks::Super::ALL_JOBS{$target};
  if ($job->{state} eq 'COMPLETE') {
    $job->mark_reaped;
    return $job->{real_pid};
  } elsif ($no_hang  or
	   $job->{state} eq 'REAPED'  or
	   $job->{state} eq 'DEFERRED') {
    return -1;
  } else {
    # block until job is complete.
    while ($job->{state} ne 'COMPLETE' and $job->{state} ne 'REAPED') {
      pause();
      run_queue() if $job->{state} eq 'DEFERRED';
    }
    $job->mark_reaped;
    return $job->{real_pid};
  }
}

sub _waitpid_name {
  my ($no_hang, $target) = @_;
  my @jobs = Forks::Super::Job::getByName($target);
  if (@jobs == 0) {
    return -1;
  }
  my @jobs_to_wait_for = ();
  foreach my $job (@jobs) {
    if ($job->{state} eq 'COMPLETE') {
      $job->mark_reaped;
      return $job->{real_pid};
    } elsif ($job->{state} ne 'REAPED' && $job->{state} ne 'DEFERRED') {
      push @jobs_to_wait_for, $job;
    }
  }
  if ($no_hang || @jobs_to_wait_for == 0) {
    return -1;
  }

  # otherwise block until a job is complete
  @jobs = grep { $_->{state} eq 'COMPLETE' || $_->{state} eq 'REAPED' } @jobs_to_wait_for;
  while (@jobs == 0) {
    pause();
    run_queue() if grep {$_->{state} eq 'DEFERRED'} @jobs_to_wait_for;
    @jobs = grep { $_->{state} eq 'COMPLETE' || $_->{state} eq 'REAPED'} @jobs_to_wait_for;
  }
  $jobs[0]->mark_reaped;
  return $jobs[0]->{real_pid};
}

# wait on any process from a specific process group
sub _waitpid_pgrp {
  my ($no_hang, $target) = @_;
  my ($pid, $nactive) = _reap($target);
  unless ($no_hang) {
    while (!isValidPid($pid) && $nactive > 0) {
      pause();
      ($pid, $nactive) = _reap($target);
    }
  }
  $? = $Forks::Super::ALL_JOBS{$pid}->{status}
    if defined $Forks::Super::ALL_JOBS{$pid};
  return $pid;
}

#sub killall {
#  die "Not implemented\n";
#}

#
# delay execution in the current thread.
# Depending on what packages are available, there
# are lots of better ways to do this than sleep 1.
#
#  1. Time::HiRes  usleep
#  2. 4-arg select kludge
#
# Also protect this function against interruption
# by sleeping more more if the original sleep call
# did not complete.
# Interruption can happen if the program receives
# a CHLD or <strike>USR1</strike> 
# $Forks::Super::QUEUE_INTERRUPT signal in the 
# middle of the sleep call.
#
sub pause {
  my $delay = shift || $Forks::Super::DEFAULT_PAUSE;
  my $expire = Forks::Super::Time() + ($delay || 0.25);

  if (CONFIG("Time::HiRes")) {
    while (Forks::Super::Time() < $expire) {
      if ($^O eq "MSWin32") {
	handle_CHLD(-1);
      }
      run_queue() if @Forks::Super::QUEUE > 0;
      
      # cygwin segfault here?
      Time::HiRes::sleep(0.1 * ($delay || 1));
    }
  } else {
    my $stall = $delay * 0.1;
    $stall = 0.1 if $stall < 0.1;
    $stall = $delay if $stall > $delay;
    $stall = 0.10 if $stall > 0.10;

    while ($delay > 0) {
      if ($^O eq "MSWin32") {
	handle_CHLD(-1);
	run_queue() if @Forks::Super::QUEUE > 0;
      }

      if ($stall >= 1) {
	sleep $stall;
      } elsif (CONFIG("select4")) {
	select undef, undef, undef, $stall < $delay ? $stall : $delay;
      } else {
	$stall = 1;
	sleep $stall;
      }
      $delay -= $stall;
    }
  }

  # Win32 code
  if ($^O eq "MSWin32" && $$ == $Forks::Super::MAIN_PID) {
    Forks::Super::handle_CHLD(-1);
    Forks::Super::run_queue() if @Forks::Super::QUEUE > 0;
  } else {

    # pause() may be called from a child. The Forks::Super::init_child
    # method should remove all parent state from a new child process
    # so, for example, the child doesn't try to examine the parent's
    # queue (if $Forks::Super::CHILD_FORK_OK > 0 and the child creates its own
    # queue, that is a different story).
    if (@Forks::Super::QUEUE > 0 &&
	++$Forks::Super::NUM_PAUSE_CALLS % 10 == 0) {
      run_queue();
    }
  }
  return;
}

#
# flexible drop in for time that will use Time::HiRes time if available.
#
sub Time {
  return CONFIG("Time::HiRes") 
    ? scalar Time::HiRes::gettimeofday() : CORE::time();
}

sub Ctime {
    my $t = Forks::Super::Time();
    return sprintf "%02d:%02d:%02d.%03d: ",
      ($t/3600)%24,($t/60)%60,$t%60,($t*1000)%1000;
}

sub _handle_bastards {
  foreach my $pid (keys %Forks::Super::BASTARD_DATA) {
    my $job = $Forks::Super::ALL_JOBS{$pid};
    if (defined $job) {
      $job->mark_complete;
      ($job->{end}, $job->{status}) =
	\@{delete $Forks::Super::BASTARD_DATA{$pid}};

    }
  }
}

#
# The handle_CHLD() subroutine takes care of reaping
# processes from the operating system. This method's
# part of the relay is taking the reaped process
# and updating the job's state.
#
# Optionally takes a process group ID to reap processes
# from that specific group.
#
# return the process id of the job that was reaped, or
# -1 if no eligible jobs were reaped. In wantarray mode,
# return the number of eligible processes (state == ACTIVE
# or  state == COMPLETE  or  STATE == SUSPENDED) that were
# not reaped.
#
sub _reap {
  my ($optional_pgid) = @_; # to reap procs from specific group
  handle_CHLD(-1) if $^O eq "MSWin32";

  _handle_bastards();

  my @j = @Forks::Super::ALL_JOBS;
  @j = grep { $_->{pgid} == $optional_pgid } @Forks::Super::ALL_JOBS
    if defined $optional_pgid;

  # see if any jobs are complete (signaled the SIGCHLD handler)
  # but have not been reaped.
  my @waiting = grep { $_->{state} eq 'COMPLETE' } @j;
  debug('Forks::Super::_reap(): found ', scalar @waiting,
    ' complete & unreaped processes') if $Forks::Super::DEBUG;

  if (@waiting > 0) {
    @waiting = sort { $a->{end} <=> $b->{end} } @waiting;
    my $job = shift @waiting;
    my $real_pid = $job->{real_pid};
    my $pid = $job->{pid};

    _debug("Forks::Super::_reap(): reaping $pid/$real_pid.")
      if $job->{debug};
    return $real_pid if not wantarray;

    my $nactive = grep { $_->{state} eq 'ACTIVE'  or
			   $_->{state} eq 'DEFERRED'  or
			   $_->{state} eq 'SUSPENDED'  or    # for future use
			   $_->{state} eq 'COMPLETE' } @j;

    debug("Forks::Super::_reap(): $nactive remain.") if $Forks::Super::DEBUG;
    $job->mark_reaped;
    return ($real_pid, $nactive);
  }

  my @active = grep { $_->{state} eq 'ACTIVE' or
			$_->{state} eq 'DEFERRED' or
			$_->{state} eq 'SUSPENDED' or         # for future use
			$_->{state} eq 'COMPLETE' } @j;

  # the failure to reap active jobs may occur because the jobs are still
  # running, or it may occur because the signal handler was overwhelmed
  if (@active > 0) {
    ++$Forks::Super::REAP_NOTHING_MSGS;
    if ($Forks::Super::REAP_NOTHING_MSGS % 10 == 0) {
      handle_CHLD(-1);
    }
  }

  return -1 if not wantarray;

  my $nactive = @active;

  if ($Forks::Super::DEBUG) {
    debug('Forks::Super::_reap(): nothing to reap now. ',
	  "$nactive remain.");

    if (!$Forks::Super::IMPORT{":test"}) {
      if ($Forks::Super::REAP_NOTHING_MSGS % 5 == 0) {
	debug('-------------------------');
	debug('Active jobs:');
	debug('   ', $_->toString()) for @active;
	debug('-------------------------');
      }
    }
  }

  return (-1, $nactive);
}

#
# called from a child process immediately after it
# is created. Erases all the global state that only needs
# to be available to the parent.
#
sub init_child {
  if ($$ == $Forks::Super::MAIN_PID) {
    carp "Forks::Super::init_child() method called from main process!";
    return;
  }
  @Forks::Super::ALL_JOBS = ();
  @Forks::Super::QUEUE = ();
  $SIG{CHLD} = $SIG{CLD} = 'DEFAULT';
  if ($Forks::Super::QUEUE_INTERRUPT && CONFIG("SIGUSR1")) {
    $SIG{$Forks::Super::QUEUE_INTERRUPT} = 'DEFAULT';
  }
  Forks::Super::Job::_untrap_signals();
  %Forks::Super::SIG_OLD = ();

  delete $Forks::Super::CONFIG{filehandles};
  undef $Forks::Super::FH_DIR;
  undef $Forks::Super::FH_DIR_DEDICATED;

  if (-p STDIN or defined getsockname(STDIN)) {
    close STDIN;
    open(STDIN, '<', '/dev/null');
  }
  if (-p STDOUT or defined getsockname(STDOUT)) {
    close STDOUT;
    open(STDOUT, '>', '/dev/null');
  }
  if (-p STDERR or defined getsockname(STDERR)) {
    close STDERR;
    open(STDERR, '>', '/dev/null');
  }
  return;
}

END {
  # child cleanup
  if ($$ != $Forks::Super::MAIN_PID) {
    &Forks::Super::child_exit(-9999);
  }
}

sub child_exit {
  my ($code) = @_;
  if (CONFIG("alarm")) {
    alarm 0;
  }
  # close filehandles ? Nah.
  # close sockethandles ? Nah.
  if (CONFIG("getpgrp")) {
    setpgrp(0, $Forks::Super::MAIN_PID);
    kill 'TERM', -$$;
  }
  CORE::exit $code if $code != -9999;
}


#
# count the number of active processes
#
sub count_active_processes {
  my $optional_pgid = shift;
  if (defined $optional_pgid) {
    return scalar grep {
      $_->{state} eq 'ACTIVE'
	and $_->{pgid} == $optional_pgid } @Forks::Super::ALL_JOBS;
  }
  return scalar grep { defined $_->{state} 
			 && $_->{state} eq 'ACTIVE' } @Forks::Super::ALL_JOBS;
}


#
# get the current CPU load. May not be possible
# to do on all operating systems.
#
sub get_cpu_load {
  # check CONFIG about how to get_cpu_load
  # not implemented
  return 0.0;
}





#
# once there are jobs in the queue, we'll need to call
# run_queue() every once in a while to make sure those
# jobs get started when they are eligible. Certain
# events (the CHLD handler being invoked, the
# waitall method) call run_queue but that still doesn't
# guarantee that it will be called frequently enough.
#
# This method sets up a background process (using
# CORE::fork -- it won't be subject to reaping by
# this module's wait/waitpid/waitall methods)
# to periodically send USR1^H^H^H^H
# $Forks::Super::QUEUE_INTERRUPT signals to this
#
sub _launch_queue_monitor {
  return unless CONFIG("SIGUSR1");

  $Forks::Super::QUEUE_MONITOR_PID = CORE::fork();
  $SIG{$Forks::Super::QUEUE_INTERRUPT} = \&Forks::Super::check_queue;
  if (not defined $Forks::Super::QUEUE_MONITOR_PID) {
    warn "queue monitoring sub process could not be launched: $!\n";
    return;
  }
  if ($Forks::Super::QUEUE_MONITOR_PID == 0) {
    init_child();
    for (;;) {
      sleep $Forks::Super::QUEUE_MONITOR_FREQ;
      kill $Forks::Super::QUEUE_INTERRUPT, $Forks::Super::MAIN_PID;
    }
    Forks::Super::child_exit(0);
  }
  return;
}

END {
  if ($$ == $Forks::Super::MAIN_PID) {
    if (defined $Forks::Super::QUEUE_MONITOR_PID &&
	$Forks::Super::QUEUE_MONITOR_PID > 0) {
      kill 3, $Forks::Super::QUEUE_MONITOR_PID;
    }
  }
}

#
# add a new job to the queue.
# may run with no arg to populate queue from existing
# deferred jobs
#
sub queue_job {
  my $job = shift;
  if (defined $job) {
    $job->{state} = 'DEFERRED';
    $job->{pid} = $Forks::Super::NEXT_DEFERRED_ID--;
    $Forks::Super::ALL_JOBS{$job->{pid}} = $job;
  }

  my @q = grep { $_->{state} eq 'DEFERRED' } @Forks::Super::ALL_JOBS;
  @Forks::Super::QUEUE = @q;

  if (@Forks::Super::QUEUE > 0 && 
      !defined $Forks::Super::QUEUE_MONITOR_PID && 
      !$Forks::Super::INHIBIT_QUEUE_MONITOR) {

    _launch_queue_monitor();
  }
  return;
}

#
# attempt to launch all jobs that are currently in the
# DEFFERED state.
#
sub run_queue {

  # tasks for run_queue:
  #   assemble all DEFERRED jobs
  #   order by priority
  #   go through the list and attempt to launch each job in order.

  debug('run_queue(): examining deferred jobs') if $Forks::Super::DEBUG;
  my $job_was_launched;
  do {
    $job_was_launched = 0;
    my @deferred_jobs = sort { $b->{queue_priority} <=> $a->{queue_priority} }
      grep { defined $_->{state} &&
	       $_->{state} eq 'DEFERRED' } @Forks::Super::ALL_JOBS;
    foreach my $job (@deferred_jobs) {
      if ($job->can_launch) {
	_debug("Launching deferred job $job->{pid}")
	  if $job->{debug};
	my $pid = $job->launch();
	if ($pid == 0) {
	  if (defined $job->{sub} or defined $job->{cmd} or defined $job->{exec}) {
	    croak "Forks::Super::run_queue(): ",
	      "fork on deferred job unexpectedly returned a process id of 0!\n";
	  }
	  croak "Forks::Super::run_queue(): ",
	    "deferred job must have a 'sub', 'cmd', or 'exec' option!\n";
	}
	$job_was_launched = 1;
	last;
      } elsif ($job->{debug}) {
	_debug("Still must wait to launch job $job->{pid}");
      }
    }
  } while ($job_was_launched);
  queue_job(); # refresh @Forks::Super::QUEUE
  return;
}

#
# SIGUSR1 handler. A background process will send periodic USR1^H^H^H^H
# $Forks::Super::QUEUE_INTERRUPT signals back to this process. On 
# receipt of these signals, this process should examine the queue. 
# This will keep us from ignoring the queue for too long.
#
# Note this automatic housecleaning is not available on some OS's
# like Windows. Those users may need to call  Forks::Super::check_queue
# or  Forks::Super::run_queue  manually from time to time.
#
sub check_queue {
  run_queue();
  return;
}

#
# default SIGCHLD handler to reap completed child
# processes.
#
# may also be invoked synchronously with argument -1
# if we are worried that some previous CHLD signals
# were not handled correctly.
#
sub handle_CHLD {
  # so far I have never observed this local function getting called.
  local $SIG{CHLD} = sub {
    $Forks::Super::SIGCHLD_CAUGHT[0]++;
    $Forks::Super::SIGCHLD_CAUGHT[1]++;
    debug("Forks::Super::handle_CHLD[2]: SIGCHLD caught local")
      if $Forks::Super::DEBUG;
  } if $^O ne "MSWin32";
  $Forks::Super::SIGCHLD_CAUGHT[0]++;
  if ($Forks::Super::SIG_DEBUG) {
    push @Forks::Super::CHLD_HANDLE_HISTORY, "start\n";
  }
  my $sig = shift;
  if ($sig ne "-1" && $Forks::Super::DEBUG) {
    debug("Forks::Super::handle_CHLD(): $sig received");
  }

  my $nhandled = 0;

  for (;;) {
    my $pid = -1;
    my $old_status = $?;
    my $status = $old_status;
    for (my $tries=1; !isValidPid($pid) && $tries <= 10; $tries++) {
      $pid = CORE::waitpid -1, WNOHANG;
      $status = $?;
    }
    $? = $old_status;
    last if !isValidPid($pid);

    $nhandled++;

    if (defined $Forks::Super::ALL_JOBS{$pid}) {
      debug("Forks::Super::handle_CHLD(): ",
	    "preliminary reap for $pid status=$status")
	if $Forks::Super::DEBUG;
      push @Forks::Super::CHLD_HANDLE_HISTORY, "reap $pid $status\n"
	if $Forks::Super::SIG_DEBUG;

      my $j = $Forks::Super::ALL_JOBS{$pid};
      $j->{status} = $status;
      $j->mark_complete;
    } else {
      # There are (at least) two reasons that we get to this code branch:
      #
      # 1. A child process completes so quickly that it is reaped in this subroutine
      #    before the parent process has finished initializing its state.
      #    Treat this as a bastard pid. We'll check later if the parent process
      #    knows about this process.
      # 2. In Cygwin, the system sometimes fails to clean up the process
      #    correctly. I notice this mainly with deferred jobs.
      debug("Forks::Super::handle_CHLD(): got CHLD signal ",
	    "but can't find child to reap; pid=$pid") if $Forks::Super::DEBUG;

      $Forks::Super::BASTARD_DATA{$pid} = [ Forks::Super::Time(), $status ];
    }
  }
  run_queue() if $nhandled > 0 && @Forks::Super::QUEUE > 0;
  if ($Forks::Super::SIG_DEBUG) {
    push @Forks::Super::CHLD_HANDLE_HISTORY, "end\n";
  }
  return;
}

#
# try to import some modules, with the expectation that the module
# might not be available.
#
# Hmmmm. We often run this subroutine from the children, which could mean
# we have to run it for every child.
#
sub CONFIG {
  my ($module, $warn, @settings) = @_;
  if (defined $Forks::Super::CONFIG{$module}) {
    return $Forks::Super::CONFIG{$module};
  }

  # check for OS-dependent Perl functionality
  if ($module eq "getpgrp" or $module eq "alarm" 
      or $module eq "SIGUSR1" or $module eq "getpriority"
      or $module eq "select4") {

    return $Forks::Super::CONFIG{$module} = _CONFIG_Perl_component($module);
  } elsif (substr($module,0,1) eq "/") {
    return $Forks::Super::CONFIG{$module} = _CONFIG_external_program($module);
  } else {
    return $Forks::Super::CONFIG{$module} =
      _CONFIG_module($module,$warn,@settings);
  }
}

sub _CONFIG_module {
  my ($module,$warn, @settings) = @_;
  my $zz = eval " require $module ";
  if ($@) {
    carp "Module $module could not be loaded: $@\n" if $warn;
      if ($Forks::Super::IMPORT{":test_config"}) {
	print STDERR "CONFIG\{$module\} failed\n";
      }
    return 0;
  }

  if (@settings) {
    $zz = eval " $module->import(\@settings) ";
    if ($@) {
      carp "Module $module was loaded but could not import with settings [",
	join (",", @settings), "]\n" if $warn;
    }
  }
  if ($Forks::Super::IMPORT{":test_config"}) {
    print STDERR "CONFIG\{$module\} enabled\n";
  }
  return 1;
}

sub _CONFIG_Perl_component {
  my ($component) = @_;
  local $@;
  if ($component eq "getpgrp") {
    undef $@;
    my $z = eval { getpgrp() };
    $Forks::Super::CONFIG{"getpgrp"} = $@ ? 0 : 1;
  } elsif ($component eq "getpriority") {
    undef $@;
    my $z = eval { getpriority(0,0) };
    $Forks::Super::CONFIG{"getpriority"} = $@ ? 0 : 1;
  } elsif ($component eq "alarm") {
    undef $@;
    my $z = eval { alarm 0 };
    $Forks::Super::CONFIG{"alarm"} = $@ ? 0 : 1;
  } elsif ($component eq "SIGUSR1") {

    # %SIG is a special hash -- defined $SIG{USR1} might be false
    # but USR1 might still appear in keys %SIG.

    my $SIG = join " ", " ", keys %SIG, " ";
    $Forks::Super::CONFIG{"SIGUSR1"} =
      $SIG =~ / $Forks::Super::QUEUE_INTERRUPT / ? 1 : 0;
  } elsif ($component eq "select4") { # 4-arg version of select
    undef $@;
    my $z = eval { select undef,undef,undef,0.5 };
    $Forks::Super::CONFIG{"select4"} = $@ ? 0 : 1;
  }

  # getppid  is another OS-dependent Perl system call

  if ($Forks::Super::IMPORT{":test_config"}) {
    if ($Forks::Super::CONFIG{$component}) {
      print STDERR "CONFIG\{$component\} enabled\n";
    } else {
      print STDERR "CONFIG\{$component\} failed\n";
    }
  }
  return $Forks::Super::CONFIG{$component};
}

sub _CONFIG_external_program {
  my ($external_program) = @_;
  if (-x $external_program) {
    if ($Forks::Super::IMPORT{":test_config"}) {
      print STDERR "CONFIG\{$external_program\} enabled\n";
    }
    return $external_program;
  } elsif (-x "/usr$external_program") {
    if ($Forks::Super::IMPORT{":test_config"}) {
      print STDERR "CONFIG\{/usr$external_program\} enabled\n";
    }
    return $Forks::Super::CONFIG{$external_program} = "/usr$external_program";
  } else {
    if ($Forks::Super::IMPORT{":test_config"}) {
      print STDERR "CONFIG\{$external_program\} failed\n";
    }
    return 0;
  }
}


#
# returns the exit status of the given process ID or job ID.
# return undef if we don't think the process is complete yet.
#
sub status {
  my $job = shift;
  if (ref $job ne 'Forks::Super::Job') {
    $job = Forks::Super::Job::get($job) || return;
  }
  return $job->{status}; # might be undef
}

sub state {
  my $job = shift;
  if (ref $job ne 'Forks::Super::Job') {
    $job = Forks::Super::Job::get($job) || return;
  }
  return $job->{state};
}

sub write_stdin {
  my ($job, @msg) = @_;
  if (ref $job ne 'Forks::Super::Job') {
    $job = $Forks::Super::ALL_JOBS{$job} || return;
  }
  my $fh = $job->{child_stdin};
  if (defined $fh) {
    return print $fh @msg;
  } else {
    carp "Forks::Super::write_stdin(): ",
      "Attempted write on child $job->{pid} with no STDIN filehandle";
  }
  return;
}

sub _read_socket {
  my ($job, $sh, $wantarray) = @_;

  if (!defined $job && $$ != $Forks::Super::MAIN_PID) {
    $job = $Forks::Super::Job::self;
  }

  if (!defined $sh) {
    carp "read on undefined filehandle for ",$job->toString();
  }

  if ($sh->blocking() || $^O eq "MSWin32") {
    my $fileno = fileno($sh);
    if (not defined $fileno) {
      $fileno = $Forks::Super::FILENO{$sh};
      Carp::cluck "Cannot determine FILENO for socket handle $sh!";
    }

    my ($rin,$rout,$ein,$eout);
    my $timeout = $Forks::Super::SOCKET_READ_TIMEOUT || 1.0;
    $rin = '';
    vec($rin, $fileno, 1) = 1;

    # perldoc select: warns against mixing select4 (unbuffered input) with
    # readline (buffered input). Oops. Do I have to do my own buffering? Weak.

    local $!; undef $!;
    my ($nfound,$timeleft) = select $rout=$rin,undef,undef, $timeout;
    if (!$nfound) {
      if ($Forks::Super::DEBUG) {
	debug("no input found on $sh/$fileno");
      }
      return;
    }

    if ($nfound == -1) {
      warn "Error in select4(): $! $^E. \$eout=$eout; \$ein=$ein\n";
    }
  }
  return readline($sh);
}

#
# called from the parent process,
# attempts to read a line from standard output filehandle
# of the specified child.
#
# returns "" if the process is running but there is no
# output waiting on the filehandle
#
# returns undef if the process has completed and there is
# no output waiting on the filehandle
#
# performs trivial seek on filehandle before reading.
# this will reduce performance but will always clear
# error condition and eof condition on handle
#
sub read_stdout {
  my ($job, $block_NOT_IMPLEMENTED) = @_;
  if (ref $job ne 'Forks::Super::Job') {
    $job = $Forks::Super::ALL_JOBS{$job} || return;
  }
  if ($job->{child_stdout_closed}) {
    if ($job->{debug} && !$job->{_warned_stdout_closed}++) {
      _debug("Forks::Super::read_stdout(): ",
	    "fh closed for $job->{pid}");
    }
    return;
  }
  my $fh = $job->{child_stdout};
  if (not defined $fh) {
    if ($job->{debug}) {
      _debug("Forks::Super::read_stdout(): ",
	    "fh unavailable for $job->{pid}");
    }
    $job->{child_stdout_closed}++;
    return;
  }
  if (defined getsockname($fh)) {
    return _read_socket($job, $fh, wantarray);
  }

  undef $!;
  if (wantarray) {
    my @lines = readline($fh);
    if (0 == @lines) {
      if ($job->is_complete && Forks::Super::Time() - $job->{end} > 3) {
	if ($job->{debug}) {
	  _debug("Forks::Super::read_stdout(): ",
		"child $job->{pid} is complete. Closing $fh");
	}
	$job->{child_stdout_closed}++;
	close $fh;
	return;
      } else {
	@lines = ('');
	seek $fh, 0, 1;
	Forks::Super::pause();
      }
    }
    return @lines;
  } else {
    my $line = readline($fh);
    if (not defined $line) {
      if ($job->is_complete && Forks::Super::Time() - $job->{end} > 3) {
	if ($job->{debug}) {
	  _debug("Forks::Super::read_stdout(): :",
		"child $job->{pid} is complete. Closing $fh");
	}
	$job->{child_stdout_closed}++;
	close $fh;
	return;
      } else {
	$line = '';
	seek $fh, 0, 1;
	Forks::Super::pause();
      }
    }
    return $line;
  }
}

#
# like read_stdout() but for stderr.
#
sub read_stderr {
  my ($job, $block_NOT_IMPLEMENTED) = @_;
  if (ref $job ne 'Forks::Super::Job') {
    $job = $Forks::Super::ALL_JOBS{$job} || return;
  }
  if ($job->{child_stderr_closed}) {
    if ($job->{debug} && !$job->{_warned_stderr_closed}++) {
      _debug("Forks::Super::read_stderr(): ",
	    "fh closed for $job->{pid}");
    }
    return;
  }
  my $fh = $job->{child_stderr};
  if (not defined $fh) {
    if ($job->{debug}) {
      _debug("Forks::Super::read_stderr(): ",
	    "fh unavailable for $job->{pid}");
    }
    $job->{child_stderr_closed}++;
    return;
  }
  if (defined getsockname($fh)) {
    return _read_socket($job, $fh, wantarray);
  }

  undef $!;
  if (wantarray) {
    my @lines = readline($fh);
    if (0 == @lines) {
      if ($job->is_complete && Forks::Super::Time() - $job->{end} > 3) {
	if ($job->{debug}) {
	  _debug("Forks::Super::read_stderr(): ",
		"child $job->{pid} is complete. Closing $fh");
	}
	$job->{child_stderr_closed}++;
	close $fh;
	return;
      } else {
	@lines = ('');
	seek $fh, 0, 1;
	Forks::Super::pause();
      }
    }
    return @lines;
  } else {
    my $line = readline($fh);
    if (not defined $line) {
      if ($job->is_complete && Forks::Super::Time() - $job->{end} > 3) {
	if ($job->{debug}) {
	  _debug("Forks::Super::read_stderr(): ",
		"child $job->{pid} is complete. Closing $fh");
	}
	$job->{child_stderr_closed}++;
	close $fh;
	return;
      } else {
	$line = '';
	seek $fh, 0, 1;
	Forks::Super::pause();
      }
    }
    return $line;
  }
}

##################################################

sub bg_eval (&;@) {
  require YAML;
  my ($code, @other_options) = @_;
  if (@other_options > 0 && ref $other_options[0] eq "HASH") {
    @other_options = %{$other_options[0]};
  }
  my $p = $$;
  my ($result, @result);
  if (wantarray) {
    tie @result, 'Forks::Super::BackgroundTieArray', $code, @other_options;
    return @result;
  } else {
    tie $result, 'Forks::Super::BackgroundTieScalar', $code, @other_options;
    if ($$ != $p) {
      # a WTF observed on MSWin32
      croak "$p changed to $$!\n";
    }
    return \$result;
  }
}

sub Forks::Super::BackgroundTieScalar::TIESCALAR {
  my ($class, $code, %other_options) = @_;
  my $self = { code => $code, value_set => 0 };
  $self->{job_id} = Forks::Super::fork { %other_options, child_fh => "out",
			  sub => sub {
			    my $Result = $code->();
			    print STDOUT YAML::Dump($Result);
			  } };
  $self->{job} = Forks::Super::Job::get($self->{job_id});
  $self->{value} = undef;
  bless $self, $class;
  return $self;
}

sub Forks::Super::BackgroundTieScalar::_retrieve_value {
  my $self = shift;
  if (!$self->{job}->is_complete) {
    my $pid = Forks::Super::waitpid $self->{job_id}, 0;
    if ($pid != $self->{job}->{real_pid}) {
      carp "bg_eval: failed to retrieve result from process!";
      $self->{value_set} = 1;
      return;
    }
  }
  my ($result) = YAML::Load( join'', Forks::Super::read_stdout($self->{job_id}) );
  $self->{value_set} = 1;
  return $self->{value} = $result;
}

sub Forks::Super::BackgroundTieScalar::FETCH {
  my $self = shift;
  if (!$self->{value_set}) {
    $self->_retrieve_value;
  }
  return $self->{value};
}

sub Forks::Super::BackgroundTieScalar::STORE {
  my ($self, $new_value) = @_;
  if (!$self->{value_set}) {
    $self->_retrieve_value;
  }
  my $old_value = $self->{value};
  $self->{value} = $new_value;
  return $old_value;
}

sub Forks::Super::BackgroundTieArray::TIEARRAY {
  my ($classname, $code, %other_options) = @_;
  my $self = { code => $code, value_set => 0, value => undef };
  $self->{job_id} = Forks::Super::fork { %other_options, child_fh => "out",
	  sub => sub {
	    my @Result = $code->();
	    print STDOUT YAML::Dump(@Result);
	  } };
  $self->{job} = Forks::Super::Job::get($self->{job_id});
  bless $self, $classname;
  return $self;
}

sub Forks::Super::BackgroundTieArray::_retrieve_value {
  my $self = shift;
  if (!$self->{job}->is_complete) {
    my $pid = Forks::Super::waitpid $self->{job_id}, 0;
    if ($pid != $self->{job}->{real_pid}) {
      carp "bg_eval: failed to retrieve result from process";
      $self->{value_set} = 1;
      return;
    }
  }
  my @result = YAML::Load( join'', Forks::Super::read_stdout($self->{job_id}) );
  $self->{value} = [ @result ];
  $self->{value_set} = 1;
  return;
}

sub Forks::Super::BackgroundTieArray::FETCH {
  my ($self, $index) = @_;
  if (!$self->{value_set}) {
    $self->_retrieve_value;
  }
  return $self->{value}->[$index];
}

sub Forks::Super::BackgroundTieArray::STORE {
  my ($self, $index, $new_value) = @_;
  if (!$self->{value_set}) {
    $self->_retrieve_value;
  }
  my $old_value = $self->{value}->[$index];
  $self->{value}->[$index] = $new_value;
  return $old_value;
}

sub Forks::Super::BackgroundTieArray::FETCHSIZE {
  my $self = shift;
  if (!$self->{value_set}) {
    $self->_retrieve_value;
  }
  return scalar @{$self->{value}};
}

sub Forks::Super::BackgroundTieArray::STORESIZE {
  my ($self, $count) = @_;
  if (!$self->{value_set}) {
    $self->_retrieve_value;
  }
  my $diff = $count - $self->FETCHSIZE();
  if ($diff > 0) {
    push @{$self->{value}}, (undef) x $diff;
  } else {
    splice @{$self->{value}}, $diff;
  }
}

sub Forks::Super::BackgroundTieArray::DELETE {
  my ($self, $index) = @_;
  if (!$self->{value_set}) {
    $self->_retrieve_value;
  }
  return delete $self->{value}->[$index];
}

sub Forks::Super::BackgroundTieArray::CLEAR {
  my $self = shift;
  if (!$self->{value_set}) {
    $self->_retrieve_value;
  }
  $self->{value} = [];
}

sub Forks::Super::BackgroundTieArray::PUSH {
  my ($self, @list) = @_;
  if (!$self->{value_set}) {
    $self->_retrieve_value;
  }
  push @{$self->{value}}, @list;
  return $self->FETCHSIZE();
}

sub Forks::Super::BackgroundTieArray::UNSHIFT {
  my ($self, @list) = @_;
  if (!$self->{value_set}) {
    $self->_retrieve_value;
  }
  unshift @{$self->{value}}, @list;
  return $self->FETCHSIZE();
}

sub Forks::Super::BackgroundTieArray::POP {
  my $self = shift;
  if (!$self->{value_set}) {
    $self->_retrieve_value;
  }
  return pop @{$self->{value}};
}

sub Forks::Super::BackgroundTieArray::SHIFT {
  my $self = shift;
  if (!$self->{value_set}) {
    $self->_retrieve_value;
  }
  return shift @{$self->{value}};
}

sub Forks::Super::BackgroundTieArray::SPLICE {
  my ($self, $offset, $length, @list) = @_;
  $offset = 0 if !defined $offset;
  $length = $self->FETCHSIZE() - $offset if !defined $length;
  if (!$self->{value_set}) {
    $self->_retrieve_value;
  }
  return splice @{$self->{value}}, $offset, $length, @list;
}

sub Forks::Super::BackgroundTieArray::EXISTS {
  my ($self, $index) = @_;
  if (!$self->{value_set}) {
    $self->_retrieve_value;
  }
  return exists $self->{value}->[$index];
}

sub debug {
  my @msg = @_;
  if ($Forks::Super::DEBUG) {
    _debug(@msg);
  }
  return;
}

sub _debug {
  my @msg = @_;
  print Forks::Super::DEBUG Forks::Super::Ctime()," ",@msg,"\n";
  return;
}

1;

#############################################################################

package Forks::Super::Job;
use Carp;
use IO::Handle;
use warnings;
$Forks::Super::Job::VERSION = $VERSION;

$Forks::Super::Job::DEFAULT_QUEUE_PRIORITY = 0;

sub new {
  my ($class, $opts) = @_;
  my $this = {};
  if (ref $opts eq 'HASH') {
    $this->{$_} = $opts->{$_} foreach keys %$opts;
  }
  $this->{created} = Forks::Super::Time();
  $this->{state} = 'NEW';
  $this->{ppid} = $$;
  push @Forks::Super::ALL_JOBS, $this;
  return bless $this, 'Forks::Super::Job';
}

#
# indicates whether job is complete
#
sub is_complete {
  my $job = shift;
  return defined $job->{state} &&
    ($job->{state} eq 'COMPLETE' || $job->{state} eq 'REAPED');
}

#
# indicates whether a job has started
#
sub is_started {
  my $job = shift;
  return $job->is_complete ||
    $job->{state} eq 'ACTIVE' ||
      $job->{state} eq 'SUSPENDED';
}

sub mark_complete {
  my $job = shift;
  $job->{state} = 'COMPLETE';
  $job->{end} = Forks::Super::Time();

  $job->run_callback("collect");
  $job->run_callback("finish");
}

sub mark_reaped {
  my $job = shift;
  $job->{state} = 'REAPED';
  $job->{reaped} = Forks::Super::Time();
  $? = $job->{status};
  debug("Job $job->{pid} reaped") if $job->{debug};
  return;
}

#
# determine whether a job is eligible to start
#
sub can_launch {
  no strict 'refs';

  my $job = shift;
  $job->{last_check} = Forks::Super::Time();
  if (defined $job->{can_launch}) {
    if (ref $job->{can_launch} eq 'CODE') {
      return $job->{can_launch}->($job);
    } elsif (ref $job->{can_launch} eq '') {
      #no strict 'refs';
      my $can_launch_sub = $job->{can_launch};
      return $can_launch_sub->($job);
    }
  } else {
    return $job->_can_launch;
  }
}

sub _can_launch_delayed_start_check {
  my $job = shift;
  return 1 if !defined $job->{start_after} || 
    Forks::Super::Time() >= $job->{start_after};

  debug('Forks::Super::Job::_can_launch(): ',
	'start delay requested. launch fail') if $job->{debug};
  #$job->{_on_busy} = 'QUEUE' if not defined $job->{on_busy};
  $job->{_on_busy} = 'QUEUE' if not defined $job->{_on_busy};
  return 0;
}

sub _can_launch_dependency_check {
  my $job = shift;
  my @dep_on = defined $job->{depend_on} ? @{$job->{depend_on}} : ();
  my @dep_start = defined $job->{depend_start} ? @{$job->{depend_start}} : ();

  foreach my $dj (@dep_on) {
    my $j = $Forks::Super::ALL_JOBS{$dj};
    if (not defined $j) {
      carp "Job dependency $dj for job $job->{pid} is invalid. Ignoring.\n";
      next;
    }
    unless ($j->is_complete) {
      debug('Forks::Super::Job::_can_launch(): ',
	"job waiting for job $j->{pid} to finish. launch fail.")
	if $j->{debug};
      return 0;
    }
  }

  foreach my $dj (@dep_start) {
    my $j = $Forks::Super::ALL_JOBS{$dj};
    if (not defined $j) {
      carp "Job start dependency $dj for job $job->{pid} is invalid. ",
	"Ignoring.\n";
      next;
    }
    unless ($j->is_started) {
      debug('Forks::Super::Job::_can_launch(): ',
	"job waiting for job $j->{pid} to start. launch fail.")
	if $j->{debug};
      return 0;
    }
  }
  return 1;
}

#
# default function for determining whether the system
# is too busy to create a new child process or not
#
sub _can_launch {
  # no warnings qw(once);

  # XXX - need better handling of case  $max_proc = "0"

  my $job = shift;
  my $max_proc = defined $job->{max_proc}
    ? $job->{max_proc} : $Forks::Super::MAX_PROC;
  my $max_load = defined $job->{max_load}
    ? $job->{max_load} : $Forks::Super::MAX_LOAD;
  my $force = defined $job->{max_load} && $job->{force};

  if ($force) {
    debug('Forks::Super::Job::_can_launch(): force attr set. launch ok')
      if $job->{debug};
    return 1;
  }

  return 0 if not $job->_can_launch_delayed_start_check;
  return 0 if not $job->_can_launch_dependency_check;

  if ($max_proc > 0) {
    my $num_active = Forks::Super::count_active_processes();
    if ($num_active >= $max_proc) {
      debug('Forks::Super::Job::_can_launch(): ',
	"active jobs $num_active exceeds limit $max_proc. ",
	    'launch fail.') if $job->{debug};
      return 0;
    }
  }

  if (0 && $max_load > 0) {  # feature disabled
    my $load = Forks::Super::get_cpu_load();
    if ($load > $max_load) {
      debug('Forks::Super::Job::_can_launch(): ',
	"cpu load $load exceeds limit $max_load. launch fail.")
	if $job->{debug};
      return 0;
    }
  }

  debug('Forks::Super::Job::_can_launch(): system not busy. launch ok.')
    if $job->{debug};
  return 1;
}

#
# make a system fork call and configure the job object
# in the parent and the child processes
#
sub launch {
  my $job = shift;
  if ($job->is_started) {
    Carp::confess "Forks::Super::Job::launch() ",
	"called on a job in state $job->{state}!\n";
  }

  if ($$ != $Forks::Super::MAIN_PID && $Forks::Super::CHILD_FORK_OK < 1) {
    return _launch_from_child($job);
  }
  $job->preconfig_fh;
  $job->preconfig2;





  my $retries = $job->{retries} || 1;


  my $pid = CORE::fork();
  while (!defined $pid && --$retries > 0) {
    carp "system fork call returned undef. Retrying ...";
    pause(1 + ($job->{retries} || 1) - $retries);
  }







  if (!defined $pid) {
    debug('Forks::Super::Job::launch(): CORE::fork() returned undefined!')
      if $job->{debug};
    return;
  }


  if (Forks::Super::isValidPid($pid)) { # parent
    $Forks::Super::ALL_JOBS{$pid} = $job;
    if (defined $job->{state} && 
	$job->{state} ne 'NEW' &&
	$job->{state} ne 'DEFERRED') {
      warn "Forks::Super::Job::launch(): ",
	"job $pid already has state: $job->{state}\n";
    } else {
      $job->{state} = 'ACTIVE';

      #
      # it is possible that this child exited quickly and has already
      # been reaped in the SIGCHLD handler. In that case, the signal
      # handler should have made an entry in %Forks::Super::BASTARD_DATA
      # for this process.
      #
      if (defined $Forks::Super::BASTARD_DATA{$pid}) {
	warn "Job $pid reaped before parent initialization.\n";
	$job->mark_complete;
	($job->{end}, $job->{status})
	  = @{delete $Forks::Super::BASTARD_DATA{$pid}};
      }
    }
    $job->{real_pid} = $pid;
    $job->{pid} = $pid unless defined $job->{pid};
    $job->{start} = Forks::Super::Time();

    $job->config_parent;
    $job->run_callback("start");
    return $pid;
  } elsif ($pid != 0) {
    Carp::confess "Forks::Super::launch(): ",
	"Somehow we got pid=$pid from fork call.";
  }

  # child
  Forks::Super::init_child();
  $job->config_child;
  if ($job->{style} eq 'cmd') {
    local $ENV{_FORK_PPID} = $$ if $^O eq "MSWin32";
    local $ENV{_FORK_PID} = $$ if $^O eq "MSWin32";
    _debug("Executing [ @{$job->{cmd}} ]") if $job->{debug};
    my $c1 = system( @{$job->{cmd}} );
    _debug("Exit code of $job->{pid} was $c1") if $job->{debug};
    exit $c1 >> 8;
  } elsif ($job->{style} eq 'exec') {
    local $ENV{_FORK_PPID} = $$ if $^O eq "MSWin32";
    local $ENV{_FORK_PID} = $$ if $^O eq "MSWin32";
    _debug("Exec'ing [ @{$job->{exec}} ]") if $job->{debug};
    exec( @{$job->{exec}} );
  } elsif ($job->{style} eq 'sub') {
    no strict 'refs';
    $job->{sub}->(@{$job->{args}});
    _debug("Job $$ subroutine call has completed") if $job->{debug};
    exit 0;
  }
  return 0;
}

sub _launch_from_child {
  my $job = shift;
  if ($Forks::Super::CHILD_FORK_OK == 0) {
    if ($Forks::Super::IMPORT{":test"}) {
      carp "fork() not allowed from child\n";
    } else {
      carp 'Forks::Super::Job::launch(): fork() not allowed ',
	"in child process $$ while \$Forks::Super::CHILD_FORK_OK ",
	"is not set!\n";
    }
    return;
  } elsif ($Forks::Super::CHILD_FORK_OK == -1) {
    if ($Forks::Super::IMPORT{":test"}) {
      carp "fork() not allowed from child. Using CORE::fork()\n";
    } else {
      carp "Forks::Super::Job::launch(): Forks::Super::fork() ",
	"call not allowed\n",
	"in child process $$ while \$Forks::Super::CHILD_FORK_OK <= 0.\n",
	  "Will create child of child with CORE::fork()\n";
    }
    my $pid = CORE::fork();
    if (defined $pid && $pid == 0) {
      # child of child
      Forks::Super::init_child();
      return $pid;
    }
    return $pid;
  }
  return;
}

# returns a Forks::Super::Job object with the given identifier
sub get {
  my $id = shift;
  if (!defined $id) {
    Carp::cluck "undef value passed to Forks::Super::Job::get()";
  }
  if (defined $Forks::Super::ALL_JOBS{$id}) {
    return $Forks::Super::ALL_JOBS{$id};
  }
  return getByPid($id) || getByName($id);
}

sub getByPid {
  my $id = shift;
  if (_is_number($id)) {
    my @j = grep { (defined $_->{pid} && $_->{pid} == $id) ||
		   (defined $_->{real_pid} && $_->{real_pid} == $id) 
		 } @Forks::Super::ALL_JOBS;
    return $j[0] if @j > 0;
  }
  return;
}

sub getByName {
  my $id = shift;
  my @j = grep { defined $_->{name} && $_->{name} eq $id } @Forks::Super::ALL_JOBS;
  if (@j > 0) {
    return wantarray ? @j : $j[0];
  }
  return;
}

#
# do further initialization of a Forks::Super::Job object,
# mainly setting derived fields
#
sub preconfig {
  my $job = shift;

  $job->preconfig_style;
  $job->preconfig_busy_action;
  $job->preconfig_start_time;
  $job->preconfig_dependencies;
  $job->preconfig_callbacks;
  return;
}

# some final initialization just before launch
sub preconfig2 {
  my $job = shift;
  if (!defined $job->{debug}) {
    $job->{debug} = $Forks::Super::DEBUG;
  }
}

#
# prepend package qualifier from current context to a scalar subroutine name
#
sub _qualify_sub_name {
  my $name = shift;
  if (ref $name eq "CODE" || $name =~ /::/ || $name =~ /\'/) {
    return $name;
  }

  my $i = 2;
  my $calling_package = caller($i);
  while ($calling_package =~ /Forks::Super/) {
    $i++;
    $calling_package = caller($i);
  }
  return join "::", $calling_package, $name;
}

sub preconfig_style {
  my $job = shift;

  ###################
  # set up style.
  #
  if (defined $job->{cmd}) {
    if (ref $job->{cmd} eq '') {
      $job->{cmd} = [ $job->{cmd} ];
    }
    $job->{style} = "cmd";
  } elsif (defined $job->{exec}) {
    if (ref $job->{exec} eq '') {
      $job->{exec} = [ $job->{exec} ];
    }
    $job->{style} = "exec";
  } elsif (defined $job->{sub}) {
    $job->{style} = "sub";
    $job->{sub} = _qualify_sub_name $job->{sub};
    if (defined $job->{args}) {
      if (ref $job->{args} eq '') {
	$job->{args} = [ $job->{args} ];
      }
    } else {
      $job->{args} = [];
    }
  } else {
    $job->{style} = "natural";
  }
  return;
}

# XXX - refactor candidate - remove obsolete attr names
sub preconfig_fh {
  my $job = shift;

  my $config = {};
  if (defined $job->{child_fh}) {
    my $fh_spec = $job->{child_fh};
    if (ref $fh_spec eq "ARRAY") {
      $fh_spec = join ":", @$fh_spec;
    }
    if ($fh_spec =~ /all/i) {
      foreach my $attr (qw(get_child_stdin get_child_stdout 
			   get_child_stderr in out err all)) {
	$config->{$attr} = 1;
      }
    } else {
      if ($fh_spec =~ /(?<!jo)in/i) {
	$config->{get_child_stdin} = $config->{in} = 1;
      }
      if ($fh_spec =~ /out/i) {
	$config->{get_child_stdout} = $config->{out} = 1;
      }
      if ($fh_spec =~ /err/i) {
	$config->{get_child_stderr} = $config->{err} = 1;
      }
      if ($fh_spec =~ /join/i) {
	$config->{join_child_stderr} = $config->{join} = 1;
	$config->{get_child_stdout} = $config->{out} = 1;
	$config->{get_child_stderr} = $config->{err} = 1;
      }
      if ($fh_spec =~ /sock/i) {
	$config->{sockets} = 1;
      }
    }
  } else {
    if (defined $job->{get_child_fh} or defined $job->{get_child_filehandles}) {
      foreach my $attr (qw(get_child_stdin get_child_stdout 
			   get_child_stderr in out err all)) {
	$config->{$attr} = 1;
      }
    } else {
      foreach my $key (qw(get_child_stdin get_child_stdout
			  get_child_stderr join_child_stderr)) {
	if (defined $job->{$key}) {
	  $config->{$key} = $job->{$key};
	  if ($key =~ /join/) {
	    $config->{join} = $job->{$key};
	  } else {
	    $config->{substr($key,13)} = $job->{$key};
	  }
	}
      }
    }
  }

  # choose file names -- if sockets are used and successfully set up,
  # the files will not be created.
  if ($config->{get_child_stdin}) {
    $config->{f_in} = _choose_fh_filename();
    debug("Using $config->{f_in} as shared file for child STDIN") 
      if $job->{debug};
  }
  if ($config->{get_child_stdout}) {
    $config->{f_out} = _choose_fh_filename();
    debug("Using $config->{f_out} as shared file for child STDOUT") 
      if $job->{debug};
  }
  if ($config->{get_child_stderr}) {
    $config->{f_err} = _choose_fh_filename();
    debug("Using $config->{f_err} as shared file for child STDERR") 
      if $job->{debug};
  }

  if ($config->{sockets}) {
    $job->preconfig_fh_sockets($config);
  }

  if (0 < scalar keys %$config) {
    if (defined $Forks::Super::CONFIG{filehandles} 
	and $Forks::Super::CONFIG{filehandles} == 0) {
      warn "interprocess filehandles not available!\n";
      return;  # filehandle feature not available
    }
    $job->{fh_config} = $config;
  }
  return;
}

sub preconfig_fh_sockets {
  my ($job,$config) = @_;
  if (!Forks::Super::CONFIG("Socket")) {
    carp "Forks::Super::Job::preconfig_fh_sockets(): ",
      "Socket unavailable. Will try to use regular filehandles for child ipc.";
    delete $config->{sockets};
    return;
  }
  if ($config->{in} || $config->{out} || $config->{err}) {
    ($config->{csock},$config->{psock}) = _create_socket_pair();

    if (not defined $config->{csock}) {
      delete $config->{sockets};
      return;
    } elsif ($job->{debug}) {
      debug("created socket pair/$config->{csock}:", fileno($config->{csock}),
	    "/$config->{psock}:",fileno($config->{psock}));
    }
    if ($config->{out} && $config->{err} && !$config->{join}) {
      ($config->{csock2},$config->{psock2}) = _create_socket_pair();
      if (not defined $config->{csock2}) {
	delete $config->{sockets};
	return;
      } elsif ($job->{debug}) {
	debug("created socket pair/$config->{csock2}:", fileno($config->{csock2}),
	      "/$config->{psock2}:",fileno($config->{psock2}));
      }
    }
  }
}

sub _create_socket_pair {
  if (!Forks::Super::CONFIG("Socket")) {
    croak "Forks::Super::Job::_create_socket_pair(): no Socket";
  }
  my ($s_child, $s_parent);
  local $!;
  undef $!;
  if (Forks::Super::CONFIG("IO::Socket")) {
    ($s_child, $s_parent) = IO::Socket->socketpair(Socket::AF_UNIX(), Socket::SOCK_STREAM(), Socket::PF_UNSPEC());
    if (!(defined $s_child && defined $s_parent)) {
      warn "IO::Socket->socketpair(AF_UNIX) failed. Trying AF_INET\n";
      ($s_child, $s_parent) = IO::Socket->socketpair(Socket::AF_INET(), Socket::SOCK_STREAM(), Socket::PF_UNSPEC());
    } 
  } else {
    my $z = socketpair($s_child, $s_parent, Socket::AF_UNIX(), Socket::SOCK_STREAM(), Socket::PF_UNSPEC());
    if ($z == 0) {
      warn "socketpair(AF_UNIX) failed. Trying AF_INET\n";
      $z = socketpair($s_child, $s_parent, Socket::AF_INET(), Socket::SOCK_STREAM(), Socket::PF_UNSPEC());
      if ($z == 0) {
	undef $s_child;
	undef $s_parent;
      }
    }
  }
  if (!(defined $s_child && defined $s_parent)) {
    carp "Forks::Super::Job::_create_socket_pair(): socketpair failed $! $^E!";
    return;
  }
  $s_child->autoflush(1);
  $s_parent->autoflush(1);
  $s_child->blocking(not $^O ne "MSWin32");
  $s_parent->blocking(not $^O ne "MSWin32");
  $Forks::Super::FILENO{$s_child} = fileno($s_child);
  $Forks::Super::FILENO{$s_parent} = fileno($s_parent);
  return ($s_child,$s_parent);
}


sub _choose_fh_filename {
  if (not defined $Forks::Super::FH_DIR) {
    _identify_shared_fh_dir();
  }
  if ($Forks::Super::CONFIG{filehandles}) {
    $Forks::Super::FH_COUNT++;
    my $file = sprintf ("%s/.fh_%03d", 
			$Forks::Super::FH_DIR, $Forks::Super::FH_COUNT);

    if ($^O eq "MSWin32") {
      $file =~ s!/!\\!g;
    }

    push @Forks::Super::FH_FILES, $file;

    if (!$Forks::Super::FH_DIR_DEDICATED && -f $file) {
      carp "IPC file $file already exists!";
      debug("$file already exists ...") if $Forks::Super::DEBUG;
#      unlink $file;
    }

    return $file;
  }
}

#
# choose a writeable but discrete location for files to
# handle interprocess communication.
#
sub _identify_shared_fh_dir {
  return if defined $Forks::Super::FH_DIR;
  $Forks::Super::CONFIG{filehandles} = 0;

  # what are the good candidates ???
  # Any:       .
  # Windows:   C:/Temp C:/Windows/Temp %HOME%
  # Other:     /tmp $HOME /var/tmp
  my @search_dirs = ($ENV{"HOME"}, $ENV{"PWD"});
  if ($^O =~ /Win32/) {
    push @search_dirs, "C:/Temp", $ENV{"TEMP"}, "C:/Windows/Temp",
      "C:/Winnt/Temp", "D:/Windows/Temp", "D:/Winnt/Temp", 
      "E:/Windows/Temp", "E:/Winnt/Temp", ".";
  } else {
    unshift @search_dirs, ".";
    push @search_dirs, "/tmp", "/var/tmp";
  }

  foreach my $dir (@search_dirs) {

    next unless defined $dir && $dir =~ /\S/;
    debug("Considering $dir as shared filehandle dir ...")
      if $Forks::Super::DEBUG;
    next unless -d $dir;
    next unless -r $dir && -w $dir && -x $dir;
    _set_fh_dir($dir);
    $Forks::Super::CONFIG{filehandles} = 1;
    debug("Selected $Forks::Super::FH_DIR as shared filehandle dir ...")
      if $Forks::Super::DEBUG;
    last;
  }
  return;
}

sub _set_fh_dir {
  my ($dir) = @_;
  $Forks::Super::FH_DIR = $dir;
  $Forks::Super::FH_DIR_DEDICATED = 0;

  if (-e "$dir/.fhfork$$") {
    my $n = 0;
    while (-e "$dir/.fhfork$$-$n") {
      $n++;
    }
    if (mkdir "$dir/.fhfork$$-$n"
	and -r "$dir/.fhfork$$-$n"
	and -w "$dir/.fhfork$$-$n"
	and -x "$dir/.fhfork$$-$n") {
      $Forks::Super::FH_DIR = "$dir/.fhfork$$-$n";
      $Forks::Super::FH_DIR_DEDICATED = 1;
      debug("dedicated fh dir: $Forks::Super::FH_DIR") if $Forks::Super::DEBUG;
    } elsif ($Forks::Super::DEBUG) {
      debug("failed to make dedicated fh dir: $dir/.fhfork$$-$n");
    }
  } else {
    if (mkdir "$dir/.fhfork$$"
	and -r "$dir/.fhfork$$"
	and -w "$dir/.fhfork$$"
	and -x "$dir/.fhfork$$") {
      $Forks::Super::FH_DIR = "$dir/.fhfork$$";
      $Forks::Super::FH_DIR_DEDICATED = 1;
      if ($Forks::Super::DEBUG) {
	debug("dedicated fh dir: $Forks::Super::FH_DIR");
      }
    } elsif ($Forks::Super::DEBUG) {
      debug("Failed to make dedicated fh dir: $dir/.fhfork$$");
    }
  }
  return;
}

sub preconfig_callbacks {
  my $job = shift;
  if (!defined $job->{callback}) {
    return;
  }
  if (ref $job->{callback} eq "" || ref $job->{callback} eq "CODE") {
    $job->{callback} = { finish => $job->{callback} };
  }
  foreach my $callback_type (qw(finish start queue fail)) {
    if (defined $job->{callback}{$callback_type}) {
      $job->{"_callback_" . $callback_type} 
	= _qualify_sub_name($job->{callback}{$callback_type});
      if ($job->{debug}) {
	_debug("Forks::Super::Job: registered callback type $callback_type");
      }
    }
  }
}

sub run_callback {
  my ($job, $callback) = @_;
  my $key = "_callback_$callback";
  if (!defined $job->{$key}) {
    return;
  }
  if ($job->{debug}) {
    _debug("Forks::Super: Job ",$job->{pid}," running $callback callback");
  }
  my $ref = ref $job->{$key};
  if ($ref ne "CODE" && ref ne "") {
    carp "Forks::Super::Job::run_callback: invalid callback $callback. ",
      "Got $ref, expected CODE or subroutine name";
    return;
  }

  $job->{"callback_time_$callback"} = Forks::Super::Time();
  $callback = delete $job->{$key};

  no strict 'refs';
  $callback->($job, $job->{pid});
}

sub preconfig_busy_action {
  my $job = shift;

  ######################
  # what will we do if the job cannot launch?
  #
  if (defined $job->{on_busy}) {
    $job->{_on_busy} = $job->{on_busy};
  } else {
    $job->{_on_busy} = $Forks::Super::ON_BUSY;
  }
  $job->{_on_busy} = uc $job->{_on_busy};

  ########################
  # make a queue priority available if needed
  #
  if (not defined $job->{queue_priority}) {
    $job->{queue_priority} = $Forks::Super::Job::DEFAULT_QUEUE_PRIORITY;
    $Forks::Super::Job::DEFAULT_QUEUE_PRIORITY -= 1E-6;
  }
  return;
}

sub preconfig_start_time {
  my $job = shift;

  ###########################
  # configure a future start time
  if (defined $job->{delay}) {
    my $start_time = Forks::Super::Time() + $job->{delay};

    if ((not defined $job->{start_after}) || $job->{start_after} > $start_time) {
      $job->{start_after} = $start_time;
    }
    delete $job->{delay};
    debug('Forks::Super::Job::_can_launch(): start delay requested.')
      if $job->{debug};
  }
  return;
}

sub preconfig_dependencies {
  my $job = shift;

  ##########################
  # assert dependencies are expressed as array refs
  # expand job names to pids
  #
  if (defined $job->{depend_on}) {
    if (ref $job->{depend_on} eq '') {
      $job->{depend_on} = [ $job->{depend_on} ];
    }
    $job->{depend_on} = _expand_names($job, $job->{depend_on});
  }
  if (defined $job->{depend_start}) {
    if (ref $job->{depend_start} eq '') {
      $job->{depend_start} = [ $job->{depend_start} ];
    }
    $job->{depend_start} = _expand_names($job, $job->{depend_start});
  }
  return;
}

sub _expand_names {
  my $job = shift;
  my @in = @{$_[0]};
  my @out = ();
  foreach my $id (@in) {
    if (_is_number($id) && defined $Forks::Super::ALL_JOBS{$id}) {
      push @out, $id;
    } else {
      my @j = Forks::Super::Job::getByName($id);
      if (@j > 0) {
	foreach my $j (@j) {
	  next if $j eq $job;
	  push @out, $j->{pid};
	}
      } else {
	carp "Forks::Super: Job dependency identifier \"$id\" is invaild. Ignoring";
      }
    }
  }
  return [ @out ];
}

sub Forks::Super::Job::_is_number { return Forks::Super::_is_number(@_) }


END {
  if ($$ == $Forks::Super::MAIN_PID) {
    _untrap_signals();
    $SIG{CHLD} = 'DEFAULT';
    if (defined $Forks::Super::FH_DIR && !$Forks::Super::DONT_CLEANUP) {
      END_cleanup();
    }
  }
}

#
# if cleanup is desired, trap signals that would normally terminate
# the program.
#
sub _trap_signals {
  return if $Forks::Super::SIGNALS_TRAPPED++;
  return if $^O eq "MSWin32";
  if ($Forks::Super::DEBUG) {
    debug("trapping INT/TERM/HUP/QUIT signals");
  }
  foreach my $sig (qw(INT TERM HUP QUIT PIPE ALRM)) {
    $Forks::Super::SIG_OLD{$sig} = $SIG{$sig};
    $SIG{$sig} = sub { 
      my $SIG=shift;
      if ($Forks::Super::DEBUG) {
	debug("trapping: $SIG");
      }
      _untrap_signals();
      exit 1;
    }
  }
}

sub _untrap_signals {
  foreach my $sig (keys %Forks::Super::SIG_OLD) {
    $SIG{$sig} = $Forks::Super::SIG_OLD{$sig} = $SIG{$sig};
  }
}

# if we have created temporary files for IPC, clean them up.
# clean them up even if the children are still alive -- these files
# are exclusively for IPC, and IPC isn't needed after the parent
# process is done.
sub END_cleanup {

  if ($$ == $Forks::Super::MAIN_PID) {
    foreach my $fh (values %Forks::Super::CHILD_STDIN,
		    values %Forks::Super::CHILD_STDOUT,
		    values %Forks::Super::CHILD_STDERR) {
      close $fh;
    }
  }

  if (defined $Forks::Super::FH_DIR_DEDICATED) {
    if (0 && $Forks::Super::IMPORT{":test"}) {
      print STDERR "END_cleanup(): removing $Forks::Super::FH_DIR\n";
    } else {
      if ($Forks::Super::DEBUG) {
	debug('END block: clean up files in ',
	    "dedicated IPC file dir $Forks::Super::FH_DIR");
      }
    }

    my $clean_up_ok = File::Path::rmtree($Forks::Super::FH_DIR, 0, 1);
    if ($clean_up_ok <= 0) {
      warn "Clean up of $Forks::Super::FH_DIR may not have succeeded.\n";
    }

    # There are two unusual features of MSWin32 to note here:
    # 1. If child processes are still alive and still have the
    #    IPC files open, the parent process will be unable to delete them.
    # 2. The parent process will not be able to exit until the
    #    child processes have completed.

    if (-d $Forks::Super::FH_DIR) {
      if (0 == rmdir $Forks::Super::FH_DIR) {
	if ($^O eq "MSWin32") {
	  warn "Must wait for all children to finish before ",
	    "removing $Forks::Super::FH_DIR\n";
	  1 while -1 != CORE::wait;
	  File::Path::rmtree($Forks::Super::FH_DIR, 0, 1);
	  rmdir $Forks::Super::FH_DIR;
	} else {
	  warn "Failed to remove $Forks::Super::FH_DIR/: $!\n";
	}
      }   # endif  rmdir
    }     # endif  -d $Forks::Super::FH_DIR
  } elsif (defined $Forks::Super::FH_DIR) {
    if (defined @Forks::Super::FH_FILES) {
      foreach my $fh_file (@Forks::Super::FH_FILES) {
	unless (unlink $fh_file) {
	  warn "Forks::Super END: possible issue removing temp file $fh_file: $!\n";
	}
      }
    }
  }
  return;
}



#
# set some additional attributes of a Forks::Super::Job after the
# child is successfully launched.
#
sub config_parent {
  my $job = shift;
  $job->config_fh_parent;
  if (Forks::Super::CONFIG("getpgrp")) {
    $job->{pgid} = getpgrp($job->{pid});

    # when  timeout =>   or   expiration =>  is used, PGID of child will be
    # set to child PID
    if (defined $job->{timeout} or defined $job->{expiration}) {
      $job->{pgid} = $job->{real_pid};
    }
  }
  return;
}

sub config_fh_parent_stdin {
  my $job = shift;
  my $fh_config = $job->{fh_config};

  if ($fh_config->{in} && $fh_config->{sockets}) {
    $fh_config->{s_in} = $fh_config->{psock};
    $job->{child_stdin} = $Forks::Super::CHILD_STDIN{$job->{real_pid}}
      = $Forks::Super::CHILD_STDIN{$job->{pid}} = $fh_config->{s_in};
    $fh_config->{f_in} = "__socket__";
    debug("Setting up socket to $job->{pid} stdin $fh_config->{s_in} ",fileno($fh_config->{s_in})) if $job->{debug};
  } elsif ($fh_config->{get_child_stdin} and defined $fh_config->{f_in}) {
    my $fh;
    if (open ($fh, '>', $fh_config->{f_in})) {
      debug("Opening $fh_config->{f_in} in parent as child STDIN") if $job->{debug};
      $job->{child_stdin} = $Forks::Super::CHILD_STDIN{$job->{real_pid}} = $fh;
      $Forks::Super::CHILD_STDIN{$job->{pid}} = $fh;
      $fh->autoflush(1);

      debug("Setting up link to $job->{pid} stdin in $fh_config->{f_in}")
	if $job->{debug};

    } else {
      warn "Forks::Super::Job::config_fh_parent(): ",
	"could not open filehandle to write child STDIN: $!\n";
    }
  }
  return;
}

sub config_fh_parent_stdout {
  my $job = shift;
  my $fh_config = $job->{fh_config};

  if ($fh_config->{out} && $fh_config->{sockets}) {
    $fh_config->{s_out} = $fh_config->{psock};
    $job->{child_stdout} = $Forks::Super::CHILD_STDOUT{$job->{real_pid}}
      = $Forks::Super::CHILD_STDOUT{$job->{pid}} = $fh_config->{s_out};
    $fh_config->{f_out} = "__socket__";
    debug("Setting up socket to $job->{pid} stdout $fh_config->{s_out} ",fileno($fh_config->{s_out})) if $job->{debug};

  } elsif ($fh_config->{get_child_stdout} and defined $fh_config->{f_out}) {
    # creation of $fh_config->{f_out} may be delayed. 
    # don't panic if we can't open it right away.
    my ($try, $fh);
    debug("Opening ", $fh_config->{f_out}, " in parent as child STDOUT") if $job->{debug};
    for ($try=1; $try<=11; $try++) {
      local $! = 0;
      if ($try <= 10 && open($fh, '<', $fh_config->{f_out})) {

	debug("Opened child STDOUT in parent on try #$try") if $job->{debug};
	$job->{child_stdout} = $Forks::Super::CHILD_STDOUT{$job->{real_pid}} = $fh;
	$Forks::Super::CHILD_STDOUT{$job->{pid}} = $fh;

	debug("Setting up link to $job->{pid} stdout in $fh_config->{f_out}")
	  if $job->{debug};

	last;
      } else {
	Forks::Super::pause(0.1 * $try);
      }
    }
    if ($try > 10) {
      warn "Forks::Super::Job::config_fh_parent(): ",
	"could not open filehandle to read child STDOUT: $!\n";
    }
  }
  if ($fh_config->{join} || $fh_config->{join_child_stderr}) {
    delete $fh_config->{err};
    delete $fh_config->{get_child_stderr};
    $job->{child_stderr} = $Forks::Super::CHILD_STDERR{$job->{real_pid}}
      = $Forks::Super::CHILD_STDERR{$job->{pid}} = $job->{child_stdout};
    $fh_config->{f_err} = $fh_config->{f_out};
    debug("Joining stderr to stdout for $job->{pid}") if $job->{debug};
  }
  return;
}

sub config_fh_parent_stderr {
  my $job = shift;
  my $fh_config = $job->{fh_config};

  if ($fh_config->{err} && $fh_config->{sockets}) {
    $fh_config->{s_err} = $fh_config->{s_out} ? $fh_config->{psock2} : $fh_config->{psock};
    $job->{child_stderr} = $Forks::Super::CHILD_STDERR{$job->{real_pid}}
      = $Forks::Super::CHILD_STDERR{$job->{pid}} = $fh_config->{s_err};
    $fh_config->{f_err} = "__socket__";
    debug("Setting up socket to $job->{pid} stderr $fh_config->{s_err} ",fileno($fh_config->{s_err})) if $job->{debug};

  } elsif ($fh_config->{get_child_stderr} and defined $fh_config->{f_err}) {
    delete $fh_config->{join_child_stderr};
    my ($try, $fh);
    debug("Opening ", $fh_config->{f_err}, " in parent as child STDERR")
      if $job->{debug};
    for ($try=1; $try<=11; $try++) {
      if ($try <= 10 && open($fh, '<', $fh_config->{f_err})) {
	debug("Opened child STDERR in parent on try #$try") if $job->{debug};
	$job->{child_stderr} = $Forks::Super::CHILD_STDERR{$job->{real_pid}} = $fh;
	$Forks::Super::CHILD_STDERR{$job->{pid}} = $fh;

	debug("Setting up link to $job->{pid} stderr in $fh_config->{f_err}")
	  if $job->{debug};

	last;
      } else {
	Forks::Super::pause(0.1 * $try);
      }
    }
    if ($try > 10) {
      warn "Forks::Super::Job::config_fh_parent(): ",
	"could not open filehandle to read child STDERR: $!\n";
    }
  }
  return;
}

#
# open filehandles to the STDIN, STDOUT, STDERR processes of the job
# to be used by the parent. Presumably the child process is opening
# the same files at about the same time.
#
sub config_fh_parent {
  my $job = shift;
  return if not defined $job->{fh_config};

  _trap_signals();
  my $fh_config = $job->{fh_config};

  # set up stdin first.
  $job->config_fh_parent_stdin;
  $job->config_fh_parent_stdout;
  $job->config_fh_parent_stderr;
  if ($job->{fh_config}->{sockets}) {
    close $job->{fh_config}->{csock};
    close $job->{fh_config}->{csock2} if defined $job->{fh_config}->{csock2};
  }

  return;
}

sub config_child {
  my $job = shift;
  $Forks::Super::Job::self = $job;
  $job->config_callback_child;
  $job->config_debug_child;
  $job->config_fh_child;
  $job->config_timeout_child;
  $job->config_os_child;
  return;
}

sub config_callback_child {
  my $job = shift;
  delete $job->{$_} for grep { /^_?callback/ } keys %$job;
}

sub config_debug_child {
  my $job = shift;
  if ($job->{debug} && $job->{undebug}) {
    if (!$Forks::Super::IMPORT{":test"}) {
      _debug("Disabling debugging in child $job->{pid}");
    }
    $Forks::Super::DEBUG = 0;
    $job->{debug} = 0;
  }
}

sub config_fh_child_stdin {
  my $job = shift;
  local $!;
  undef $!;
  my $fh_config = $job->{fh_config};

  if ($fh_config->{in} && $fh_config->{sockets}) {
    close STDIN;
    if (open(STDIN, '<&' . fileno($fh_config->{csock}))) {
      *STDIN->autoflush(1);
      $Forks::Super::FILENO{*STDIN} = fileno(STDIN);
    } else {
      warn "Forks::Super::Job::config_fh_child_stdin(): ",
	"could not attach child STDIN to input sockethandle: $!\n";
    }
    debug("Opening ",*STDIN,"/",fileno(STDIN), " in child STDIN") if $job->{debug};
  } elsif ($fh_config->{get_child_stdin} && $fh_config->{f_in}) {
    # creation of $fh_config->{f_in} may be delayed. 
    # don't panic if we can't open it right away.
    my ($try, $fh);
    debug("Opening ", $fh_config->{f_in}, " in child STDIN") if $job->{debug};
    for ($try=1; $try<=11; $try++) {
      if ($try <= 10 && open($fh, '<', $fh_config->{f_in})) {
	close STDIN if $^O eq "MSWin32";
	open(STDIN, "<&" . fileno($fh) )
	  or warn "Forks::Super::Job::config_fh_child(): ",
	    "could not attach child STDIN to input filehandle: $!\n";
	debug("Reopened STDIN in child on try #$try") if $job->{debug};

	# XXX - Unfortunately, if redirecting STDIN fails (and it might
	# if the parent is late in opening up the file), we have probably
	# already redirected STDERR and we won't get to see the above
	# warning message

	last;
      } else {
	Forks::Super::pause(0.1 * $try);
      }
    }
    if ($try > 10) {
      warn "Forks::Super::Job::config_fh_child(): ",
	"could not open filehandle to provide child STDIN: $!\n";
    }
  }
  return;
}

sub config_fh_child_stdout {
  my $job = shift;
  local $!;
  undef $!;
  my $fh_config = $job->{fh_config};

  if ($fh_config->{out} && $fh_config->{sockets}) {
    close STDOUT;
    if (open(STDOUT, '>&' . fileno($fh_config->{csock}))) {
      *STDOUT->autoflush(1);
      select STDOUT;
    } else {
      warn "Forks::Super::Job::config_fh_child_stdout(): ",
	"could not attach child STDOUT to output sockethandle: $!\n";
    }
    debug("Opening ",*STDOUT,"/",fileno(STDOUT)," in child STDOUT") if $job->{debug};

    if ($fh_config->{join} || $fh_config->{join_child_stderr}) {
      delete $fh_config->{err};
      delete $fh_config->{get_child_stderr};
      close STDERR;
      if (open(STDERR, ">&" . fileno($fh_config->{csock}))) {
        *STDERR->autoflush(1);
	debug("Joining ",*STDERR,"/",fileno(STDERR)," STDERR to child STDOUT") if $job->{debug};
      } else {
        warn "Forks::Super::Job::config_fh_child_stdout(): ",
          "could not join child STDERR to STDOUT sockethandle: $!\n";
      }
    }

  } elsif ($fh_config->{get_child_stdout} && $fh_config->{f_out}) {
    my $fh;
    debug("Opening up $fh_config->{f_out} for output in the child   $$")
      if $job->{debug};
    if (open($fh, '>', $fh_config->{f_out})) {
      $fh->autoflush(1);
      close STDOUT if $^O eq "MSWin32";
      if (open(STDOUT, '>&' . fileno($fh))) {  # v5.6 compatibility
	*STDOUT->autoflush(1);

	if ($fh_config->{join_child_stderr}) {
	  delete $fh_config->{get_child_stderr};
	  close STDERR if $^O eq "MSWin32";
	  if (open(STDERR, '>&' . fileno($fh))) {
	    *STDERR->autoflush(1);
	  } else {
	    warn "Forks::Super::Job::config_fh_child(): ",
	      "could not attach STDERR to child output filehandle: $!\n";
	  }
	}
      } else {
	warn "Forks::Super::Job::config_fh_child(): ",
	  "could not attach STDOUT to child output filehandle: $!\n";
      }
    } else {
      warn "Forks::Super::Job::config_fh_child(): ",
	"could not open filehandle to provide child STDOUT: $!\n";
    }
  }
  return;
}

sub config_fh_child_stderr {
  my $job = shift;
  my $fh_config = $job->{fh_config};

  if ($fh_config->{err} && $fh_config->{sockets}) {
    close STDERR;
    if (open(STDERR, ">&" . fileno($fh_config->{$fh_config->{out} ? "csock2" : "csock"}))) {
      *STDERR->autoflush(1);
      debug("Opening ",*STDERR,"/",fileno(STDERR)," in child STDERR") if $job->{debug};      
    } else {
      warn "Forks::Super::Job::config_fh_child_stderr(): ",
	"could not attach STDERR to child error sockethandle: $!\n";
    }
  } elsif ($fh_config->{get_child_stderr} && $fh_config->{f_err}) {
    my $fh;
    debug("Opening $fh_config->{f_err} as child STDERR")
      if $job->{debug};
    if (open($fh, '>', $fh_config->{f_err})) {
      close STDERR if $^O eq "MSWin32";
      if (open(STDERR, '>&' . fileno($fh))) {
	$fh->autoflush(1);
	*STDERR->autoflush(1);
      } else {
	warn "Forks::Super::Job::config_fh_child_stderr(): ",
	  "could not attach STDERR to child error filehandle: $!\n";
      }
    } else {
      warn "Forks::Super::Job::config_fh_child_stderr(): ",
	"could not open filehandle to provide child STDERR: $!\n";
    }
  }
  return;
}

#
# open handles to the files that the parent process will
# have access to, and assign them to the local STDIN, STDOUT,
# and STDERR filehandles.
#
sub config_fh_child {
  my $job = shift;
  return if not defined $job->{fh_config};
  if ($job->{style} eq 'cmd' || $job->{style} eq 'exec') {
    $job->config_cmd_fh_child;
    return;
  }

  $job->config_fh_child_stdout;
  $job->config_fh_child_stderr;
  $job->config_fh_child_stdin;
  if ($job->{fh_config} && $job->{fh_config}->{sockets}) {
    close $job->{fh_config}->{psock};
    close $job->{fh_config}->{psock2} if defined $job->{fh_config}->{psock2};   
  }
  return;
}

# McCabe score: 24
sub config_cmd_fh_child {
  my $job = shift;
  my $fh_config = $job->{fh_config};
  my $cmd_or_exec = $job->{exec} ? 'exec' : 'cmd';
  my @cmd = @{$job->{$cmd_or_exec}};
  if (@cmd > 1) {
    my @new_cmd = ();
    foreach my $cmd (@cmd) {
      if ($cmd !~ /[\s\'\"\[\]\;\(\)\<\>\t\|\?\&]/x) {
	push @new_cmd, $cmd;
      } elsif ($cmd !~ /\'/) {
	push @new_cmd, "'$cmd'";
      } else {
	my $cmd2 = $cmd;
	$cmd2 =~ s/([\s\'\"\\\[\]\;\(\)\<\>\t\|\?\&])/\\$1/gx;
	push @new_cmd, "\"$cmd2\"";
      }
    }
    @cmd = ();
    push @cmd, (join " ", @new_cmd);
  }

  # XXX - not idiot proof. FH dir could have a metacharacter.
  if ($fh_config->{get_child_stdout} && $fh_config->{f_out}) {
    if ($^O eq "MSWin32") {
      $cmd[0] .= " >\"$fh_config->{f_out}\"";
    } else {
      $cmd[0] .= " >'$fh_config->{f_out}'";
    }
    if ($fh_config->{join_child_stderr}) {
      $cmd[0] .= " 2>&1";
    }
  }
  if ($fh_config->{get_child_stderr} && $fh_config->{f_err}
      && !$fh_config->{join_child_stderr}) {
    if ($^O eq "MSWin32") {
      $cmd[0] .= " 2>\"$fh_config->{f_err}\"";
    } else {
      $cmd[0] .= " 2>'$fh_config->{f_err}'";
    }
  }
  if ($fh_config->{get_child_stdin} && $fh_config->{f_in}) {
    if ($^O eq "MSWin32") {
      $cmd[0] .= " <\"$fh_config->{f_in}\"";
    } else {
      $cmd[0] .= " <'$fh_config->{f_in}'";
    }

    # the external command must not be launched until the 

    my $try;
    for ($try = 0; $try <= 10; $try++) {
      if (-r $fh_config->{f_in}) {
	$try = 0;
	last;
      }
      Forks::Super::pause(0.1 * $try);
    }
    if ($try >= 10) {
      warn 'Forks::Super::Job::config_cmd_fh_child(): ',
	"child was not able to detect STDIN file $fh_config->{f_in}. ",
	"Child may not have any input to read.\n";
    }
  }
  debug("Forks::Super::Job::config_cmd_fh_config(): child cmd is   $cmd[0]  ")
    if $job->{debug};

  $job->{$cmd_or_exec} = [ @cmd ];
  return;
}

#
# If desired, set an alarm and alarm signal handler on a child process
# to kill the child.
# Should only run from a child process immediately after the fork.
#
sub config_timeout_child {
  my $job = shift;
  my $timeout = 9E9;
  if (defined $job->{timeout}) {
    $timeout = $job->{timeout};
    if ($job->{style} eq "exec") {
      carp "Forks::Super: exec option used, timeout option ignored";
      return;
    }
  }
  if (defined $job->{expiration}) {
    if ($job->{expiration} - Forks::Super::Time() < $timeout) {
      $timeout = $job->{expiration} - Forks::Super::Time();
    }
    if ($job->{style} eq "exec") {
      carp "Forks::Super: exec option used, expiration option ignored";
      return;
    }
  }
  if ($timeout > 9E8) {
    return;
  }

  # if allowed by the OS, establish a new process group for this child.
  # This will make it easier to kill off this child and all of its
  # children when desired.
  if (Forks::Super::CONFIG("getpgrp")) {
    setpgrp(0, $$);
    $job->{pgid} = getpgrp();
    if ($job->{debug}) {
      _debug("Forks::Super::Job::config_timeout_child: ",
	     "Child process group changed to $job->{pgid}");
    }
  }

  if ($timeout < 1) {
    if ($Forks::Super::IMPORT{":test"}) {
      die "quick timeout\n";
    } 
    croak "Forks::Super::Job::config_timeout_child(): quick timeout";
  }

  $SIG{ALRM} = sub { 
    warn "Forks::Super: child process timeout\n";
    exit 1;
  };
  if (Forks::Super::CONFIG("alarm")) {
    alarm $timeout;
    debug("Forks::Super::Job::config_timeout_child(): ",
	  "alarm set for ${timeout}s in child process $$")
      if $job->{debug};
  } else {
    carp "Forks::Super: alarm() not available, ",
      "timeout,expiration options ignored.\n";
  }
  return;
}

#
# If desired and if the platform supports it, set
# job-specific operating system settings like
# process priority and CPU affinity.
# Should only be run from a child process
# immediately after the fork.
#
sub config_os_child {
  my $job = shift;

  if (defined $job->{name}) {
    $0 = $job->{name}; # might affect ps(1) output
  } else {
    $job->{name} = $$;
  }

  $ENV{_FORK_PPID} = $$ if $^O eq "MSWin32";
  if (defined $job->{os_priority}) {
    my $p = $job->{os_priority} + 0;
    my $q = -999;

    if ($^O eq "MSWin32" && Forks::Super::CONFIG("Win32::API")) {
      my $win32_thread_api = _get_win32_thread_api();
      if (!defined $win32_thread_api->{"_error"}) {
	my $thread_id = $win32_thread_api->{"GetCurrentThreadId"}->Call();
	my ($handle, $old_affinity);
	if ($thread_id) {
	  $handle = $win32_thread_api->{"OpenThread"}->Call(0x0060,0,$thread_id)
	    || $win32_thread_api->{"OpenThread"}->Call(0x0400,0,$thread_id);
	}
	if ($handle) {
	  my $result = $win32_thread_api->{"SetThreadPriority"}->Call($handle,$p);
	  if ($result) {
	    if ($job->{debug}) {
	      _debug("updated thread priority to $p for job $job->{pid}");
	    }
	  } else {
	    carp "Forks::Super::Job::config_os_child(): ",
	      "setpriority() call failed $p ==> $q\n";
	  }
	}
      }
    } else {
      my $z = eval "setpriority(0,0,$p); \$q = getpriority(0,0)";
      if ($@) {
	carp "Forks::Super::Job::config_os_child(): ",
	  "setpriority() call failed $p ==> $q\n";
      }
    }
  }

  if (defined $job->{cpu_affinity}) {
    my $n = $job->{cpu_affinity};
    if ($n == 0) {
      carp "Forks::Super::Job::config_os_child(): ",
	"desired cpu affinity set to zero. Is that what you really want?\n";
    }

    if ($^O =~ /cygwin/i && Forks::Super::CONFIG("Win32::Process")) {
      my $winpid = Win32::Process::GetCurrentProcessID();
      my $processHandle;
      if (Win32::Process::Open($processHandle, $winpid, 0)) {
	$processHandle->SetProcessAffinityMask($n);
      } else {
	carp "Forks::Super::Job::config_os_child(): ",
	  "Win32::Process::Open call failed for Windows PID $winpid, ",
	  "can not update CPU affinity";
      }
    } elsif ($^O=~/linux/i && Forks::Super::CONFIG("/bin/taskset")) {
      $n = sprintf "0%o", $n;
      system(Forks::Super::CONFIG("/bin/taskset"),"-p",$n,$$);
    } elsif ($^O eq "MSWin32" && Forks::Super::CONFIG("Win32::API")) {
      my $win32_thread_api = _get_win32_thread_api();
      if (!defined $win32_thread_api->{"_error"}) {
	my $thread_id = $win32_thread_api->{"GetCurrentThreadId"}->Call();
	my ($handle, $old_affinity);
	if ($thread_id) {
	  # is 0x0060 right for all versions of Windows ??
	  $handle = $win32_thread_api->{"OpenThread"}->Call(0x0060, 0, $thread_id);
	}
	if ($handle) {
	  $old_affinity = $win32_thread_api->{"SetThreadAffinityMask"}->Call($handle, $n);
	  if ($job->{debug}) {
	    debug("CPU affinity for Win32 thread id $thread_id: ",
		  "$old_affinity ==> $n\n");
	  }
	} else {
	  carp "Forks::Super::Job::config_os_child(): ",
	    "Invliad handle for Win32 thread id $thread_id";
	}
      }
    } elsif (Forks::Super::CONFIG('BSD::Process::Affinity')) {
      # this code is not tested and not guaranteed to work
      my $z = eval 'BSD::Process::Affinity->get_process_mask()
                    ->from_bitmask($n)->update()';
      if ($@ && 0 == $Forks::Super::Job::WARNED_ABOUT_AFFINITY++) {
	warn "Forks::Super::Job::config_os_child(): ",
	  "cannot update CPU affinity\n";
      }
    } elsif (0 == $Forks::Super::Job::WARNED_ABOUT_AFFINITY++) {
      warn "Forks::Super::Job::config_os_child(): ",
	"cannot update CPU affinity\n";
    }
  }
  return;
}

sub _get_win32_thread_api {
  if (!$Forks::Super::Job::WIN32_THREAD_API_INITIALIZED) {
    local $!;
    undef $!;
    my $win32_thread_api = 
      # needed for setting CPU affinity
      { "GetCurrentThreadId" =>
		Win32::API->new('kernel32','int GetCurrentThreadId()'),
	"OpenThread" =>
		Win32::API->new('kernel32', 
				q[HANDLE OpenThread(DWORD a,BOOL b,DWORD c)]),
	"SetThreadAffinityMask" =>
		Win32::API->new('kernel32',
				"DWORD SetThreadAffinityMask(HANDLE h,DWORD d)"),

	# needed for setting thread priority
	"SetThreadPriority" =>
		Win32::API->new('kernel32', "BOOL SetThreadPriority(HANDLE h,int n)"),
      };
    if ($!) {
      $win32_thread_api->{"_error"} = "$! / $^E";
    }

    undef $!;
    $win32_thread_api->{"GetProcessAffinityMask"} =
      Win32::API->new('kernel32', "BOOL GetProcessAffinityMask(HANDLE h,PDWORD a,PDWORD b)");
    $win32_thread_api->{"GetThreadPriority"} =
      Win32::API->new('kernel32', "int GetThreadPriority(HANDLE h)");

    if ($win32_thread_api->{"_error"}) {
      carp "error in Win32::API thread initialization: ",
	$win32_thread_api->{"_error"};
    }
    $Forks::Super::Job::WIN32_THREAD_API = $win32_thread_api;
    $Forks::Super::Job::WIN32_THREAD_API_INITIALIZED++;
  }
  return $Forks::Super::Job::WIN32_THREAD_API;
}


#
# Produces string representation of a Forks::Super::Job object.
#
sub toString {
  my $job = shift;
  my @to_display = qw(pid state create);
  foreach my $attr (qw(real_pid style cmd exec sub args start end reaped 
		       status closure pgid)) {
    push @to_display, $attr if defined $job->{$attr};
  }
  my @output = ();
  foreach my $attr (@to_display) {
    next unless defined $job->{$attr};
    if (ref $job->{$attr} eq 'ARRAY') {
      push @output, "$attr=[" . join(q{,},@{$job->{$attr}}) . ']';
    } else {
      push @output, "$attr=" . $job->{$attr};
    }
  }
  return '{' . join (q{;},@output), '}';
}

#
# Print information about all known jobs.
#
sub printAll {
  print "ALL JOBS\n";
  print "--------\n";
  foreach my $job
    (sort {$a->{pid} <=> $b->{pid} || 
	     $a->{created} <=> $b->{created}} @Forks::Super::ALL_JOBS) {
      
      print $job->toString(), "\n";
      print "----------------------------\n";
    }
  return;
}

sub debug {
  my @msg = @_;
  Forks::Super::_debug(@msg);
  return;
}

sub _debug {
  my @msg = @_;
  Forks::Super::_debug(@msg);
  return;
}

1;

__END__

--------------------------------------------------------------------------------

=head1 NAME

Forks::Super - extensions and convenience methods for managing background processes.

=head1 VERSION

Version 0.13

=head1 SYNOPSIS

    use Forks::Super;
    use Forks::Super MAX_PROC => 5, DEBUG => 1;

    # familiar use - parent returns PID>0, child returns zero
    $pid = fork();
    die "fork failed" unless defined $pid;
    if ($pid > 0) {
        # parent code
    } else {
        # child code
    }

    # wait for a child process to finish
    $w = wait;                  # blocking wait on any child, $? holds child exit status
    $w = waitpid $pid, 0;       # blocking wait on specific child
    $w = waitpid $pid, WNOHANG; # non-blocking wait, use with POSIX ':sys_wait_h'
    $w = waitpid 0, $flag;      # wait on any process in current process group
    waitall;                    # block until all children are finished

    # -------------- helpful extensions ---------------------
    # fork directly to a shell command. Child doesn't return.
    $pid = fork { cmd => "./myScript 17 24 $n" };
    $pid = fork { exec => [ "/bin/prog" , $file, "-x", 13 ] };

    # fork directly to a Perl subroutine. Child doesn't return.
    $pid = fork { sub => $methodNameOrRef , args => [ @methodArguments ] };
    $pid = fork { sub => \&subroutine, args => [ @args ] };
    $pid = fork { sub => sub { "anonymous sub" }, args => [ @args ] );

    # put a time limit on the child process
    $pid = fork { cmd => $command, timeout => 30 };            # kill child if not done in 30s
    $pid = fork { sub => $subRef , expiration => 1260000000 }; # complete by 8AM Dec 5, 2009 UTC

    # obtain standard filehandles for the child process
    $pid = fork { child_fh => "in,out,err" };
    if ($pid == 0) {      # child process
      sleep 1;
      $x = <STDIN>; # read from parent's $Forks::Super::CHILD_STDIN{$pid}
      print rand() > 0.5 ? "Yes\n" : "No\n" if $x eq "Clean your room\n";
      sleep 2;
      $i_can_haz_ice_cream = <STDIN>;
      if ($i_can_haz_ice_cream !~ /you can have ice cream/ && rand() < 0.5) {
          print STDERR '@#$&#$*&#$*&',"\n";
      }
      exit 0;
    } # else parent process
    $child_stdin = $Forks::Super::CHILD_STDIN{$pid};
    print $child_stdin "Clean your room\n";
    sleep 2;
    $child_stdout = $Forks::Super::CHILD_STDOUT{$pid};
    $child_response = <$child_stdout>; # -or-  = Forks::Super::read_stdout($pid);
    if ($child_response eq "Yes\n") {
        print $child_stdin "Good boy. You can have ice cream.\n";
    } else {
        print $child_stdin "Bad boy. No ice cream for you.\n";
        sleep 2;
        $child_err = Forks::Super::read_stderr($pid);
        # -or-  $child_err = readline($Forks::Super::CHILD_STDERR{$pid});
        print $child_stdin "And no back talking!\n" if $child_err;
    }

    # ---------- manage jobs and system resources ---------------
    # runs 100 tasks but the fork call blocks when there are already 5 jobs running
    $Forks::Super::MAX_PROC = 5;
    $Forks::Super::ON_BUSY = 'block';
    for ($i=0; $i<100; $i++) {
      $pid = fork { cmd => $task[$i] };
    }

    # jobs fail (without blocking) if the system is too busy
    $Forks::Super::MAX_PROC = 5;
    $Forks::Super::ON_BUSY = 'fail';
    $pid = fork { cmd => $task };
    if    ($pid > 0) { print "'$task' is running\n" }
    elsif ($pid < 0) { print "5 or more jobs running -- didn't start '$task'\n"; }

    # $Forks::Super::MAX_PROC setting can be overridden. Start job immediately if < 3 jobs running
    $pid = fork { sub => 'MyModule::MyMethod', args => [ @b ], max_proc => 3 };

    # try to fork no matter how busy the system is
    $pid = fork { force => 1, sub => \&MyMethod, args => [ @my_args ] };

    # when system is busy, queue jobs. When system is not busy, some jobs on the queue will start.
    # if job is queued, return value from fork() is a very negative number
    $Forks::Super::ON_BUSY = 'queue';
    $pid = fork { cmd => $command };
    $pid = fork { cmd => $useless_command, queue_priority => -5 };
    $pid = fork { cmd => $important_command, queue_priority => 5 };
    $pid = fork { cmd => $future_job, delay => 20 }   # keep job on queue for at least 20s

    # assign descriptive names to tasks
    $pid1 = fork { cmd => $command, name => "my task" };
    $pid2 = waitpid "my task", 0;

    # run callbacks at various points of job life-cycle
    $pid = fork { cmd => $command, callback => \&on_complete };
    $pid = fork { sub => $sub, callback => { start => 'on_start', finish => \&on_complete,
                                             queue => sub { print "Job $_[1] queued.\n" } } };

    # set up dependency relationships
    $pid1 = fork { cmd => $job1 };
    $pid2 = fork { cmd => $job2, depend_on => $pid1 };            # put on queue until job 1 is complete
    $pid4 = fork { cmd => $job4, depend_start => [$pid2,$pid3] }; # put on queue until jobs 2,3 have started

    $pid5 = fork { cmd => $job5, name => "group C" };
    $pid6 = fork { cmd => $job6, name => "group C" };
    $pid7 = fork { cmd => $job7, depend_on => "group C" }; # wait for jobs 5 & 6 to complete

    # manage OS settings on jobs -- not available on all systems
    $pid1 = fork { os_priority => 10 };    # like nice(1) on Un*x
    $pid2 = fork { cpu_affinity => 0x5 };  # background task will prefer CPUs #0 and #2

    # job information
    $state = Forks::Super::state($pid);    # 'ACTIVE', 'DEFERRED', 'COMPLETE', 'REAPED'
    $status = Forks::Super::status($pid);  # exit status for completed jobs

    # --- evaluate long running expressions in the background
    $result = bg_eval { a_long_running_calculation() };
    # sometime later ...
    print "Result was $$result\n";

=head1 DESCRIPTION

This package provides new definitions for the Perl functions
C<fork>, C<wait>, and C<waitpid> with richer functionality.
The new features are designed to make it more convenient to
spawn background processes and more convenient to manage them
and to get the most out of your system's resources.

=head1 C<$pid = fork( \%options )>

The new C<fork> call attempts to spawn a new process.
With no arguments, it behaves the same as the Perl system
call L<< C<fork()>|perlfunc/fork >>:

=over 4

=item * 

creating a new process running the same program at the same point

=item * 

returning the process id (PID) of the child process to the parent.

On Windows, this is a I<pseudo-process ID> 

=item * 

returning 0 to the child process

=item * 

returning C<undef> if the fork call was unsuccessful

=back

=head2 Options for instructing the child process

The C<fork> call supports three options, C<cmd>, C<exec>,
and C<sub> (or C<sub>/C<args>)
that will instruct the child process to carry out a specific task. Using 
either of these options causes the child process not to return from the 
C<fork> call.

=over 4

=item C<< $child_pid = fork { cmd => $shell_command } >>

=item C<< $child_pid = fork { cmd => \@shell_command } >>

On successful launch of the child process, runs the specified shell command
in the child process with the Perl C<system()> function. When the system
call is complete, the child process exits with the same exit status that
was returned by the system call. 

Returns the PID of the child process to
the parent process. Does not return from the child process, so you do not
need to check the fork() return value to determine whether code is
executing in the parent or child process.

=back

=over 4

=item C<< $child_pid = fork { exec => $shell_command } >>

=item C<< $child_pid = fork { exec => \@shell_command } >>

Like the C<cmd> option, but the background process launches the
shell command with C<exec> instead of with C<system>.

Using C<exec> instead of C<cmd> will spawn one fewer process,
but note that the C<timeout> and C<expiration> options cannot
be used with the C<exec> option (see 
L<"Options for simple job management">).

=back

=over 4

=item C<< $child_pid = fork { sub => $subroutineName [, args => \@args ] } >>

=item C<< $child_pid = fork { sub => \&subroutineReference [, args => \@args ] } >>

=item C<< $child_pid = fork { sub => sub { ... code ... } [, args => \@args ] } >>

On successful launch of the child process, C<fork> invokes the specified
Perl subroutine with the specified set of method arguments (if provided).
If the subroutine completes normally, the child process exits with
a status of zero. If the subroutine exits abnormally (i.e., if it
C<die>s, or if the subroutine invokes C<exit> with a non-zero
argument), the child process exits with non-zero status. 

Returns the PID of the child process to the parent process.
Does not return from the child process, so you do not need to check the
fork() return value to determine whether code is running in the parent or
child process.

If neither the C<cmd> or the C<sub> option is provided to the fork call,
then the fork() call behaves like a Perl C<fork()> call, returning 
the child PID to the parent and also returning zero to the child.

=back

=head2 Options for simple job management

=over 4

=item C<< fork { timeout => $delay_in_seconds } >>

=item C<< fork { expiration => $timestamp_in_seconds_since_epoch_time } >>

Puts a deadline on the child process and causes the child to C<die> 
if it has not completed by the deadline. With the C<timeout> option,
you specify that the child process should not survive longer than the
specified number of seconds. With C<expiration>, you are specifying
an epoch time (like the one returned by the C<time> function) as the
child process's deadline.

If the C<setpgrp()> system call is implemented on your system,
then this module will reset the process group ID of the child 
process. On timeout, the module will attempt to kill off all
subprocesses of the expiring child process.

If the deadline is some time in the past (if the timeout is
not positive, or the expiration is earlier than the current time),
then the child process will die immediately after it is created.

Note that this feature uses the Perl C<alarm> call with a
handler for C<SIGALRM>. If you use this feature and also specify a
C<sub> to invoke, and that subroutine also tries to use the
C<alarm> feature or set a handler for C<SIGALRM>, the results 
will be undefined.

The C<timeout> and C<expiration> options cannot be used with the
C<exec> option, since the child process will not be able to
generate a C<SIGALRM> after an C<exec> call.

=item C<< fork { delay => $delay_in_seconds } >>

=item C<< fork { start_after => $timestamp_in_epoch_time } >>

Causes the child process to be spawned at some time in the future. 
The return value from a C<fork> call that uses these features
will not be a process id, but it will be a very negative number
called a job ID. See the section on L</"Deferred processes">
for information on what to do with a job ID.

A deferred job will start B<no earlier> than its appointed time
in the future. Depending on what circumstances the queued jobs
are examined, the actual start time of the job could be significantly
later than the appointed time.

A job may have both a minimum start time (through C<delay> or
C<start_after> options) and a maximum end time (through
C<timeout> and C<expiration>). Jobs with inconsistent times
(end time is not later than start time) will be killed of
as soon as they are created.

=item C<< fork { child_fh => $fh_spec } >>

=item C<< fork { child_fh => [ @fh_spec ] } >>

B<Note: API change since v0.10.>

Launches a child process and makes the child process's 
STDIN, STDOUT, and/or STDERR filehandles available to
the parent process in the scalar variables
$Forks::Super::CHILD_STDIN{$pid}, $Forks::Super::CHILD_STDOUT{$pid},
and/or $Forks::Super::CHILD_STDERR{$pid}, where $pid is the PID
return value from the fork call. This feature makes it possible,
even convenient, for a parent process to communicate with a
child, as this contrived example shows.

    $pid = fork { sub => \&pig_latinize, timeout => 10,
                  child_fh => "all" };

    # in the parent, $Forks::Super::CHILD_STDIN{$pid} is an *output* filehandle
    print {$Forks::Super::CHILD_STDIN{$pid}} "The blue jay flew away in May\n";

    sleep 2; # give child time to start up and get ready for input

    # and $Forks::Super::CHILD_STDOUT{$pid} is an *input* handle
    $result = <{$Forks::Super::CHILD_STDOUT{$pid}}>;
    print "Pig Latin translator says: $result\n"; # ==> eThay ueblay ayjay ewflay awayay inay ayMay\n
    @errors = <{$Forks::Super::CHILD_STDERR{$pid}>;
    print "Pig Latin translator complains: @errors\n" if @errors > 0;

    sub pig_latinize {
      for (;;) {
        while (<STDIN>) {
	  foreach my $word (split /\s+/) {
            if ($word =~ /^qu/i) {
              print substr($word,2) . substr($word,0,2) . "ay";  # STDOUT
            } elsif ($word =~ /^([b-df-hj-np-tv-z][b-df-hj-np-tv-xz]*)/i) {
              my $prefix = 1;
              $word =~ s/[b-df-hj-np-tv-z][b-df-hj-np-tv-xz]*//i;
	      print $word . $prefix . "ay";
	    } elsif ($word =~ /^[aeiou]/i) {
              print $word . "ay";
            } else {
	      print STDERR "Didn't recognize this word: $word\n";
            }
            print " ";
          }
	  print "\n";
        }
      }
    }

The set of filehandles to make available are specified either as
a non-alphanumeric delimited string, or list reference. This spec
may contain one or more of the words C<in>, C<out>, C<err>,
C<join>, C<all>, or C<socket>. 

C<in>, C<out>, and C<err> mean that the child's STDIN, STDOUT,
and STDERR, respectively, will be available in the parent process
through the filehandles in C<$Forks::Super::CHILD_STDIN{$pid}>,
C<$Forks::Super::CHILD_STDOUT{$pid}>, 
and C<$Forks::Super::CHILD_STDERR{$pid}>, where C<$pid> is the
child's process ID. C<all> is a convenient way to specify
C<in>, C<out>, and C<err>. C<join> specifies that the child's
STDOUT and STDERR will be returned through the same filehandle,
specified as both C<$Forks::Super::CHILD_STDOUT{$pid}> and
C<$Forks::Super::CHILD_STDERR{$pid}>.

If C<socket> is specified, then local sockets will be used to
pass between parent and child instead of temporary files.

=back

=head3 Socket handles vs. file handles

Here are some things to keep in mind when deciding whether to
use sockets or regular files for parent-child IPC:

=over 4

=item * 

Sockets have a performance advantage, especially at 
child process start-up.

=item * 

Socket input buffers have limited capacity. Write operations 
can block if the socket reader is not vigilant

=item * 

On Windows, sockets are blocking, and care must be taken
to prevent your script from reading on an empty socket

=back

=cut 

It is an open question (that is to say: I personally haven't researched it)
whether opening socket handles counts against your program's limit
of simultaneous open filehandles.

=head3 Socket and file handle gotchas

Some things to keep in mind when using socket or file handles
to communicate with a child process.

=over 4

=item * 

care should be taken before C<close>'ing a socket handle.
The same socket handle can be used for both reading and writing.
Don't close a handle when you are only done with one half of the
socket operations.

=item * 

The test C<defined getsockname($handle)> can determine
whether C<$handle> is a socket handle or a regular filehandle.

=item * 

The following idiom is safe to use on both socket handles
and regular filehandles:

    shutdown($handle,2) || close $handle;

=item * 

IPC in this module is asynchronous. In general, you
cannot tell whether the parent/child has written anything to
be read in the child/parent. So getting C<undef> when reading
from the C<$Forks::Super::CHILD_STDOUT{$pid}> handle does not
necessarily mean that the child has finished (or even started!)
writing to its STDOUT. Check out the C<seek HANDLE,0,1> trick
in L<the perlfunc documentation for seek|perlfunc/seek> 
about reading from a handle after you have
already read past the end. You may find it useful for your
parent and child processes to follow some convention (for example,
a special word like C<"__END__">) to denote the end of input.

=back

=head2 Options for complicated job management

The C<fork()> call from this module supports options that help to
manage child processes or groups of child processes in ways to better
manage your system's resources. For example, you may have a lot of tasks
to perform in the background, but you don't want to overwhelm your 
(possibly shared) system by running them all at once. There are features
to control how many, how, and when your jobs will run.

=over 4

=item C<< fork { name => $name } >>

Attaches a string identifier to the job. The identifier can be used
for several purposes:

=over 4

=item * to obtain a L<Forks::Super::Job> object representing the
background task through the C<Forks::Super::Job::get> or
C<Forks::Super::Job::getByName> methods.

=item * as the first argument to C<waitpid> to wait on a job or jobs
with specific names

=item * to identify and establish dependencies between background tasks.
See the C<depend_on> and C<depend_start> parameters below.

=item * if supported by your system, the name attribute will change
the argument area used by the ps(1) program and change the 
way the background process is displaying in your process viewer.
(See L<$PROGRAM_NAME in perlvar|perlvar/"$PROGRAM_NAME"> 
about overriding the special C<$0> variable.)

=back

=item C<$Forks::Super::MAX_PROC = $max_simultaneous_jobs>

=item C<< fork { max_fork => $max_simultaneous_jobs } >>

Specifies the maximum number of background processes that you want to run.
If a C<fork> call is attempted while there are already the maximum
number of child processes running, then the C<fork()> call will either
block (until some child processes complete), fail (return a negative
value without spawning the child process), or queue the job (returning
a very negative value called a job ID), according to the specified
"on_busy" behavior (see the next item). See the L</"Deferred processes">
section for information about how queued jobs are handled.

On any individual C<fork> call, the maximum number of processes may be
overridden by also specifying C<max_proc> or C<force> options. 

    $Forks::Super::MAX_PROC = 8;
    # launch 2nd job only when system is very not busy
    $pid1 = fork { sub => 'method1' };
    $pid2 = fork { sub => 'method2', max_proc => 1 };
    $pid3 = fork { sub => 'method3' };

Setting $Forks::Super::MAX_PROC to zero or a negative number will disable the
check for too many simultaneous processes.

=item C<$Forks::Super::ON_BUSY = "block" | "fail" | "queue">

=item C<< fork { on_busy => "block" | "fail" | "queue" } >>

Dictates the behavior of C<fork> in the event that the module is not allowed
to launch the specified job for whatever reason.

=over 4

=item C<"block">

If the system cannot create a new child process for the specified job,
it will wait and periodically retry to create the child process until
it is successful. Unless a system fork call is attempted and fails,
C<fork> calls that use this behavior will return a positive PID.

=item C<"fail">

If the system cannot create a new child process for the specified job,
the C<fork> call will immediately return with a small negative
value.

=item C<"queue">

If the system cannot create a new child process for the specified job,
the job will be deferred, and an attempt will be made to launch the
job at a later time. See L</"Deferred processes"> below. The return 
value will be a very negative number (job ID).

=back

On any individual C<fork> call, the default launch failure behavior specified
by $Forks::Super::ON_BUSY can be overridden by specifying a C<on_busy> option:

    $Forks::Super::ON_BUSY = "fail";
    $pid1 = fork { sub => 'myMethod' };
    $pid2 = fork { sub => 'yourMethod', on_busy => "queue" }

=item C<< fork { force => $bool } >>

If the C<force> option is set, the C<fork> call will disregard the
usual criteria for deciding whether a job can spawn a child process,
and will always attempt to create the child process.

=item C<< fork { queue_priority => $priority } >>

In the event that a job cannot immediately create a child process and
is put on the job queue (see L</"Deferred processes">), the C{queue_priority}
specifies the relative priority of the job on the job queue. In general,
eligible jobs with high priority values will be started before jobs
with lower priority values.

=item C<< fork { depend_on => $id } >>

=item C<< fork { depend_on => [ $id_1, $id_2, ... ] } >>

=item C<< fork { depend_start => $id } >>

=item C<< fork { depend_start => [ $id_1, $id_2, ... ] } >>

Indicates a dependency relationship between the job in this C<fork>
call and one or more other jobs. The identifiers may be 
process/job IDs or C<name> attributes (ses above) from
earlier C<fork> calls.

If a C<fork> call specifies a
C<depend_on> option, then that job will be deferred until
all of the child processes specified by the process or job IDs
have B<completed>. If a C<fork> call specifies a
C<depend_start> option, then that job will be deferred until
all of the child processes specified by the process or job
IDs have B<started>.

Invalid process and job IDs in a C<depend_on> or C<depend_start>
setting will produce a warning message but will not prevent 
a job from starting.

Dependencies are established at the time of the C<fork> call
and can only apply to jobs that are known at run time. So for
example, in this code,

    $job1 = fork { cmd => $cmd, name => "job1", depend_on => "job2" };
    $job2 = fork { cmd => $cmd, name => "job2", depend_on => "job1" };

at the time the first job is cereated, the job named "job2" has not
been created yet, so the first job will not have a dependency (and a
warning will be issued when the job is created). This may
be a limitation but it also guarantees that there will be no
circular dependencies.

When a dependency identifier is a name attribute that applies to multiple
jobs, the job will be dependent on B<all> existing jobs with that name:

    # Job 3 will not start until BOTH job 1 and job 2 are done
    $job1 = fork { name => "Sally", ... };
    $job2 = fork { name => "Sally", ... };
    $job3 = fork { depend_on => "Sally", ... };

    # all of these jobs have the same name and depend on ALL previous jobs
    $job4 = fork { name => "Ralph", depend_start => "Ralph", ... }; # no dependencies
    $job5 = fork { name => "Ralph", depend_start => "Ralph", ... }; # depends on Job 4
    $job6 = fork { name => "Ralph", depend_start => "Ralph", ... }; # depends on #4 and #5

=item C<< fork { can_launch => \&methodName } >>

=item C<< fork { can_launch => sub { ... anonymous sub ... } } >>

Supply a user-specified function to determine when a job is
eligible to be started. The function supplied should return
0 if a job is not eligible to start and non-zero if it is
eligible to start. 

During a C<fork> call or when the job queue is being examined,
the user's C<can_launch> method will be invoked with a single
C<Forks::Super::Job> argument containing information about the job
to be launched. User code may make use of the default launch
determination method by invoking the C<_can_launch> method
of the job object:

    # Running on a BSD system with the uptime(1) call.
    # Want to block jobs when the current CPU load 
    # (1 minute) is greater than 4 and respect all other criteria:
    fork { cmd => $my_command,
           can_launch => sub {
             $job = shift;                    # a Forks::Super::Job object
             return 0 if !$job->_can_launch;  # default
             $cpu_load = (split /\s+/,`uptime`)[-3]; # get 1 minute avg CPU load
             return 0 if $cpu_load > 4.0;     # system too busy. let's wait
             return 1;
           } }

=item C<< fork { callback => $subroutineName } >>

=item C<< fork { callback => sub { BLOCK } } >>

=item C<< fork { callback => { start => ..., finish => ..., queue => ..., fail => ... } } >>

Install callbacks to be run when and if certain events in the life cycle
of a background process occur. The first two forms of this option are equivalent to

    fork { callback => { finish => ... } }

and specify code that will be executed when a background process is complete
and the module has received its C<SIGCHLD> event. A C<start> callback is
executed just after a new process is spawned. A C<queue> callback is run
if the job is deferred for any reason (see L</"Deferred processes">) and
the job is placed onto the job queue for the first time. And the C<fail>
callback is run if the job is not going to be launched (that is, a case 
where the C<fork> call would return C<-1>).

Callbacks are invoked with two arguments when they are triggered:
the C<Forks::Super::Job> object that was created with the original
C<fork> call, and the job's ID (the return value from C<fork>).

You should keep your callback functions short and sweet, like you do
for your signal handlers. Sometimes callbacks are invoked from the
signal handler, and the processing of other signals could be
delayed if the callback functions take too long to run.

=item C<< fork { os_priority => $priority } >>

On supported operating systems, and after the successful creation
of the child process, attempt to set the operating system priority
of the child process.

On unsupported systems, this option is ignored.

=item C<< fork { cpu_affinity => $bitmask } >>

On supported operating systems with multiple cores, 
and after the successful creation of the child process, 
attempt to set the process's CPU affinity.
Each bit of the bitmask represents one processor. Set a bit to 1
to allow the process to use the corresponding processor, and set it to
0 to disallow the corresponding processor. There may be additional
restrictions on the valid range of values imposed by the operating
system.

As of version 0.07, supported systems are Cygwin, Win32, Linux,
and possibly BSD.

=item C<< fork { debug => $bool } >>

=item C<< fork { undebug => $bool } >>

Overrides the value in C<$Forks::Super::DEBUG> (see L</"MODULE VARIABLES">)
for this specific job. If specified, the C<debug> parameter
controls only whether the module will output debugging information related
to the job created by this C<fork> call.

Normally, the debugging settings of the parent, including the job-specific
settings, are inherited by child processes. If the C<undebug> option is
specified with a non-zero parameter value, then debugging will be 
disabled in the child process.

=back

=head2 Deferred processes

Whenever some condition exists that prevents a C<fork()> call from
immediately starting a new child process, an option is to B<defer>
the job. Deferred jobs are placed on a queue. At periodic intervals,
in response to periodic events, or whenever you invoke the
C<Forks::Super::run_queue> method in your code, the queue will be examined
to see if any deferred jobs are eligible to be launched.

=head3 Job ID

When a C<fork()> call fails to spawn a child process but instead
defers the job by adding it to the queue, the C<fork()> call will
return a unique, large negative number called the job ID. The
number will be negative and large enough (E<lt>= -100000) so
that it can be distinguished from any possible PID,
Windows pseudo-process ID, process group ID, or C<fork()>
failure code.

Although the job ID is not the actual ID of a system process, 
it may be used like a PID as an argument to C<waitpid>,
as a dependency specification in another C<fork> call's
C<depend_on> or C<depend_start> option, or
the other module methods used to retrieve job information
(See L</"Obtaining job information"> below). Once a deferred
job has been started, it will be possible to obtain the
actual PID (or on Windows, the actual
psuedo-process ID) of the process running that job.

=head3 Job priority

Every job on the queue will have a priority value. A job's
priority may be set explicitly by including the
C<queue_priority> option in the C<fork()> call, or it will
be assigned a default priority near zero. Every time the
queue is examined, the queue will be sorted by this priority
value and an attempt will be made to launch each job in this
order. Note that different jobs may have different criteria
for being launched, and it is possible that that an eligible
low priority job may be started before an ineligible
higher priority job.

=head3 Queue examination

Certain events in the C<SIGCHLD> handler or in the 
C<wait>, C<waitpid>, and/or C<waitall> methods will cause
the list of deferred jobs to be evaluated and to start
eligible jobs. But this configuration does not guarantee
that the queue will be examined in a timely or frequent
enough basis. The user may invoke the

    Forks::Super::run_queue()

method at any time to cause the queue to be examined.

=head2 Special tips for Windows systems

On POSIX systems (including Cygwin), programs using the
C<Forks> module are interrupted when a child process 
completes. A callback function performs some housekeeping
and may perform other duties like trying to dispatch
things from the list of deferred jobs.

Windows systems do not have the signal handling capabilities
of other systems, and so other things equal, a script
running on Windows will not perform the housekeeping
tasks as frequently as a script on other systems.

The method C<Forks::Super::pause> can be used as a drop in
replacement for the Perl C<sleep> call. In a C<pause>
function call, the program will check on active
child processes, reap the ones that have completed, and
attempt to dispatch jobs on the queue. 

Calling C<pause> with an argument of 0 is also a valid
way of invoking the child handler function on Windows.
When used this way, C<pause> returns immediately after
running the child handler.

Child processes are implemented differently in Windows
than in POSIX systems. The C<CORE::fork> and C<Forks::Super::fork>
calls will usually return a B<pseudo-process ID> to the
parent process, and this will be a B<negative value>. 
The Unix idiom of testing whether a C<fork> call returns
a positive number needs to be modified on Windows systems
by testing whether  C<Forks::Super::isValidPid($pid)> returns
true, where C<$pid> is the return value from a C<Forks::Super::fork>
call.

=head1 OTHER FUNCTIONS

=over 4

=item C<$reaped_pid = wait>

Like the Perl L<< C<wait>|perlfunc/wait >> system call, 
blocks until a child process
terminates and returns the PID of the deceased process,
or C<-1> if there are no child processes remaining to reap.
The exit status of the child is returned in C<$?>.

=cut

XXX - future enhancement: take a timeout argument, in which case
it will not behave exactly like the Perl wait system call.

=item C<$reaped_pid = waitpid $pid, $flags>

Waits for a child with a particular PID or a child from
a particular process group to terminate and returns the
PID of the deceased process, or C<-1> if there is no
suitable child process to reap. If the return value contains
a PID, then C<$?> is set to the exit status of that process.

A valid job ID (see L</"Deferred processes">) may be used
as the $pid argument to this method. If the C<waitpid> call
reaps the process associated with the job ID, the return value
will be the actual PID of the deceased child.

Note that the C<waitpid> function can wait on a
job ID even when the job associated with that ID is
still in the job queue, waiting to be started.

A $pid value of C<-1> waits for the first available child
process to terminate and returns its PID.

A $pid value of C<0> waits for the first available child 
from the same process group of the calling process.

A negative C<$pid> that is not recognized as a valid job ID
will be interpreted as a process group ID, and the C<waitpid>
function will return the PID of the first available child 
from the same process group.

On some^H^H^H^H every modern system that I know about,
 a C<$flags> value of C<POSIX::WNOHANG>
is supported to perform a non-blocking wait. See the
Perl L<< C<waitpid>|perlfunc/waitpid >> documentation.

=cut

XXX - include optional third timeout argument

=item C<waitall>

Blocking wait for all child processes, including deferred
jobs that have not started at the time of the C<waitall>
call.

=item C<Forks::Super::isValidPid( $pid )>

Tests whether the return value of a C<fork> call indicates that
a background process was successfully created or not. On POSIX
systems it is sufficient to check whether C<$pid> is a
positive integer, but C<isValidPid> is a more 

=item C<Forks::Super::pause($delay)>

A B<productive> drop-in replacement for the Perl C<sleep>
system call (or C<Time::HiRes::sleep>, if available). On
systems like Windows that lack a proper method for
handling C<SIGCHLD> events, the C<Forks::Super::pause> method
will occasionally reap child processes that have completed
and attempt to dispatch jobs on the queue. 

On other systems, using C<Forks::Super::pause> is less vulnerable
than C<sleep> to interruptions from this module (See 
L<"BUGS AND LIMITATIONS"> below).

=item C<$status = Forks::Super::status($pid)>

Returns the exit status of a completed child process
represented by process ID or job ID $pid. Aside from being
a permanent store of the exit status of a job, using this
method might be a more reliable indicator of a job's status
than checking C<$?> after a C<wait> or C<waitpid> call. It is
possible for this module's C<SIGCHLD> handler to temporarily
corrupt the C<$?> value while it is checking for deceased
processes.

=item C<$line = Forks::Super::read_stdout($pid)>

=item C<@lines = Forks::Super::read_stdout($pid)>

=item C<$line = Forks::Super::read_stderr($pid)>

=item C<@lines = Forks::Super::read_stderr($pid)>

For jobs that were started with the C<get_child_stdout> and C<get_child_stderr>
options enabled, read data from the STDOUT and STDERR filehandles of child
processes. 

Aside from the more readable syntax, these functions may be preferable to

    @lines = < {$Forks::Super::CHILD_STDOUT{$pid}} >;
    $line = < {$Forks::Super::CHILD_STDERR{$pid}} >;

because they will automatically handle clearing the EOF condition
on the filehandles if the parent is reading on the filehandles faster
than the child is writing on them.

Functions work in both scalar and list context. If there is no data to
read on the filehandle, but the child process is still active and could
put more data on the filehandle, these functions return  ""  in scalar
and list context. If there is no more data on the filehandle and the
child process is finished, the functions return C<undef>.

=back

=head3 Obtaining job information

=over 4

=item C<$job = Forks::Super::Job::get($pid)>

Returns a C<Forks::Super::Job> object associated with process ID or job ID C<$pid>.
See L<Forks::Super::Job> for information about the methods and attributes of
these objects.

=item C<@jobs = Forks::Super::Job::getByName($name)>

Returns zero of more C<Forks::Super::Job> objects with the specified
job names. A job receives a name if a C<name> parameter was provided
in the C<Forks::Super::fork> call.

=item C<< $reference = bg_eval { BLOCK } >>

=item C<< $reference = bg_eval { BLOCK } { option => value, ... } >>

Evaluates the specified block of code in a background process. When the
parent process dereferences the result, it uses interprocess communication
to retrieve the result from the child process, waiting until the child
finishes if necessary.

    # Example 1: must wait until job finishes before $$result is available
    $result = bg_eval { sleep 3 ; return 42 };
    print "Result is $$result\n";

    # Example 2: $$result is probably available immediately
    $result = bg_eval { sleep 3 ; return 42 };
    &do_something_that_takes_about_5_seconds();
    print "Result is $$result\n";

The code block is always evaluated in scalar context, though it is
acceptable to return a reference:

    $result = bg_eval {
            @files = File::Find::find(\&criteria, @lots_of_dirs);
            return \@files;
        };
    # ... do something else while that job runs ...
    foreach my $matching_file (@$$result) { # note double dereference
        # ... do something with $matching_file
    }

The background job will be spawned with the C<Forks::Super::fork> call,
and the command will block, fail, or defer a background job in accordance
with all of the other rules of this module. Additional options may be
passed to C<bg_eval>  that will be provided to the C<fork> call. For
example:

    $result = bg_eval {
            return get_from_teh_Internet($something, $where);
        } { timeout => 60, priority => 3 };

will return a reference to C<undef> if the operation takes longer
than 60 seconds. Most valid options for the C<fork> call are also valid
options for C<bg_eval>, including timeouts, delays, job dependencies,
names, and callback. The only invalid options for C<bg_eval> are
C<cmd>, C<sub>, C<exec>, and C<child_fh>.

=item C<< @result = bg_eval { BLOCK } >>

=item C<< @result = bg_eval { BLOCK } { option => value, ... } >>

Evaluates the specified block of code in a background process and in list
context. The parent process retrieves the result from the child through
interprocess communication the first time that an element of the array
is referenced; the parent will wait for the child to finish if necessary.

The background job will be spawned with the C<Forks::Super::fork>
call, and the command will block, fail, or defer a background job in
accordance with all of the rules of this module. Additional options may
be passed to the C<bg_eval> function that will be provided to the
C<Forks::Super::fork> call. For example:

    @result = bg_eval {
            count_words($a_huge_file)
        } { timeout => 60 };

will return an empty list if the operation takes longer than
60 seconds. Any valid options for the C<fork> call are also valid
options for C<bg_eval>, except for C<exec>, C<cmd>, C<sub>, and
C<child_fh>.

=back

=head1 MODULE VARIABLES

Module variables may be initialized on the C<use Forks::Super> line

    # set max simultaneous procs to 5, allow children to call CORE::fork()
    use Forks::Super MAX_PROC => 5, CHILD_FORK_OK => -1;

or they may be set explicitly in the code:

    $Forks::Super::ON_BUSY = 'queue';
    $Forks::Super::FH_DIR = "/home/joe/temp-ipc-files";

Module variables that may be of interest include:

Previous sections discussed the use of C<$Forks::Super::MAX_PROC>
and C<$Forks::Super::ON_BUSY>. Some other module variables that might
be of interest are

=over 4

=item C<$Forks::Super::MAX_PROC>

The maximum number of simultaneous background processes that can
be spawned by C<Forks::Super>. If a C<fork> call is attempted while
there are already at least this many active background processes,
the behavior of the C<fork> call will be determined by the
value in C<$Forks::Super::ON_BUSY> or by the C<on_busy> option passed
to the C<fork> call.

This value will be ignored during a C<fork> call if the C<force> 
option is passed to C<fork> with a non-zero value. The value might also
not be respected if the user supplies a code reference in the
C<can_launch> option and the user-supplied code does not test
whether there are already too many active proceeses.

=item C<$Forks::Super::ON_BUSY = 'block' | 'fail' | 'queue'>

Determines behavior of a C<fork> call when the system is too
busy to create another background process. 

If this value is set
to C<block>, then C<fork> will wait until the system is no
longer too busy and then launch the background process.
The return value will be a normal process ID value (assuming
there was no system error in creating a new process).

If the value is set to C<fail>, the C<fork> call will return
immediately without launching the background process. The return
value will be C<-1>. A C<Forks::Super::Job> object will not be
created.

If the value is set to C<queue>, then the C<fork> call
will create a "deferred" job that will be queued and run at
a later time. Also see the C<queue_priority> option to C<fork>
to set the urgency level of a job in case it is deferred.
The return value will be a large and negative
job ID. 

This value will be ignored in favor of an C<on_busy> option
supplied to the C<fork> call.

=item C<$Forks::Super::CHILD_FORK_OK = -1 | 0 | +1>

Spawning a child process from another child process with this
module has its pitfalls, and this capability is disabled by
default: you will get a warning message and the C<fork()> call
will fail if you try it.

To override hits behavior, set C<$Forks::Super::CHILD_FORK_OK> to 
a non-zero value. Setting it to a positive value will allow
you to use all the functionality of this module from a child
process (with the obvious caveat that you cannot C<wait> on the
child process or a child process from the main process).

Setting C<$Forks::Super::CHILD_FORK_OK> to a negative value will 
disable the functionality of this module but will 
reenable the classic Perl C<fork()> system call from child
processes.

=item C<$Forks::Super::DEBUG, Forks::Super::DEBUG>

To see the internal workings of the C<Forks> module, set
C<$Forks::Super::DEBUG> to a non-zero value. Information messages
will be written to the C<Forks::Super::DEBUG> filehandle. By default
C<Forks::Super::DEBUG> is aliased to C<STDERR>, but it may be reset
by the module user at any time.

Debugging behavior may be overridden for specific jobs
if the C<debug> or C<undebug> option is provided to C<fork>.

=item C<%Forks::Super::CHILD_STDIN>

=item C<%Forks::Super::CHILD_STDOUT>

=item C<%Forks::Super::CHILD_STDERR>

In jobs that request access to the child process filehandles,
these hash arrays contain filehandles to the standard input
and output streams of the child. The filehandles for particular
jobs may be looked up in these tables by process ID or job ID
for jobs that were deferred.

Remember that from the perspective of the parent process,
C<$Forks::Super::CHILD_STDIN{$pid}> is an output filehandle (what you
print to this filehandle can be read in the child's STDIN),
and C<$Forks::Super::CHILD_STDOUT{$pid}> and C<$Forks::Super::CHILD_STDERR{$pid}>
are input filehandles (for reading what the child wrote
to STDOUT and STDERR).

As with any asynchronous communication scheme, you should
be aware of how to clear the EOF condition on filehandles
that are being simultaneously written to and read from by
different processes. A scheme like this works on most systems:

    # in parent, reading STDOUT of a child
    for (;;) {
        while (<{$Forks::Super::CHILD_STDOUT{$pid}}>) {
          print "Child $pid said: $_";
        }

        # EOF reached, but child may write more to filehandle later.
        sleep 1;
        seek $Forks::Super::CHILD_STDOUT{$pid}, 0, 1;
    }

=item C<@Forks::Super::ALL_JOBS>, C<%Forks::Super::ALL_JOBS>

List of all C<Forks::Super::Job> objects that were created from C<fork()> calls,
including deferred and failed jobs. Both process IDs and job IDs
(for jobs that were deferred at one time) can be used to look
up Job objects in the %Forks::Super::ALL_JOBS table.

=item C<$Forks::Super::QUEUE_INTERRUPT>

On systems with mostly-working signal frameworks, this
module installs a signal handler the first time that a
task is deferred. The signal that is trapped is
defined in the variable C<$Forks::Super::QUEUE_INTERRUPT>.
The default value is C<USR1>, and it may be overridden 
directly or set on module import

    use Forks::Super QUEUE_INTERRUPT => 'TERM';
    $Forks::Super::QUEUE_INTERRUPT = 'USR2';

You would only worry about resetting this variable
if you (including other modules that you import) are
making use of an existing C<SIGUSR1> handler.



=back

=head1 DIAGNOSTICS

=over 4

=item C<fork() not allowed in child process ...>

=item C<Forks::Super::fork() call not allowed in child process ...>

When the package variable C<$Forks::Super::CHILD_FORK_OK> is zero, this package does not
allow the C<fork()> method to be called from a child process. 
Set L<C<< $Forks::Super::CHILD_FORK_OK >>|/"MODULE VARIABLES"> 
to change this behavior.

=item C<quick timeout>

A job was configured with a timeout/expiration time such that the 
deadline for the job occurred before the job was even launched. The job
was killed immediately after it was spawned.

=item C<Job start/Job dependency E<lt>nnnE<gt> for job E<lt>nnnE<gt> is invalid. Ignoring.>

A process id or job id that was specified as a C<depend_on> or C<depend_start>
option did not correspond to a known job.

=item C<Job E<lt>nnnE<gt> reaped before parent initialization.>

A child process finished quickly and was reaped by the parent process C<SIGCHLD>
handler before the parent process could even finish initializing the job state.
The state of the job in the parent process might be unavailable or corrupt 
for a short time, but eventually it should be all right.

=item C<interprocess filehandles not available>

=item C<could not open filehandle to provide child STDIN/STDOUT/STDERR>

=item C<child was not able to detect STDIN file ... Child may not have any input to read.>

=item C<could not open filehandle to write child STDIN>

=item C<could not open filehandle to read child STDOUT/STDERR>

Initialization of filehandles for a child process failed. The child process
will continue, but it will be unable to receive input from the parent through
the C<$Forks::Super::CHILD_STDIN{pid}> filehandle, or pass output to the parent through the
filehandles C<$Forks::Super::CHILD_STDOUT{PID}> AND C<$Forks::Super::CHILD_STDERR{pid}>. 

=item C<exec option used, timeout option ignored>

A C<fork> call was made using the incompatible options C<exec> and C<timeout>.

=back

=head1 INCOMPATIBILITIES

Some features use the C<alarm> function and custom
C<SIGALRM> handlers in the child processes. Using other
modules that employ this functionality may cause
undefined behavior. Systems and versions that do not
implement the C<alarm> function (like MSWin32 prior to
Perl v5.7) will not be able to use these features.

The first time that a task is deferred, by default this
module will try to install a C<SIGUSR1> handler. See
the description of C<$Forks::Super::QUEUE_INTERRUPT>
under L</"MODULE VARIABLES"> for changing this behavior
if you intended to use a C<SIGUSR1> handler for
something else.

=head1 DEPENDENCIES

The C<bg_eval> function requires L<YAML>.

Otherwise, there are no hard dependencies 
on non-core modules. Some features, especially operating-system
specific functions,
depend on some modules (C<Win32::API> and C<Win32::Process>
for Wintel systems, for example), but the module will
compile without those modules. Attempts to use these features
without the required modules will be silently ignored.

=head1 BUGS AND LIMITATIONS

A typical script using this module will have a lot of
behind-the-scenes signal handling as child processes
finish and are reaped. These frequent interruptions can
affect the execution of your program. For example, in
this script:

    1: use Forks::Super;
    2: fork(sub => sub { sleep 2 });
    3: sleep 5;
    4: # ... program continues ...

the C<sleep> call in line 3 is probably going to get
interrupted before 5 seconds have elapsed as the end
of the child process spawned in line 2 will interrupt
execution and invoke the SIGCHLD handler.
In some cases there are tedious workarounds:

    3a: $stop_sleeping_at = time + 5;
    3b: sleep 1 while time < $stop_sleeping_at;

It should be noted that signal handling in Perl is much
improved with version 5.7.3, and the problems caused by
such interruptions are much more tractable than they
used to be.

The system implementation of fork'ing and wait'ing varies
from platform to platform. It is possible that this module
or certain features will not work as advertised. Please
report any problems you encounter to E<lt>mob@cpan.orgE<gt>
and I'll see what I can do about it.

=cut

=head1 SEE ALSO

There are reams of other modules on CPAN for managing background
processes. See Parallel::*, Proc::Parallel, Proc::Fork, 
Proc::Launcher.

Inspiration for C<bg_eval> function from L<Acme::Fork::Lazy>.

=head1 AUTHOR

Marty O'Brien, E<lt>mob@cpan.orgE<gt>

=head1 LICENSE AND COPYRIGHT

Copyright (c) 2009-2010, Marty O'Brien.

This library is free software; you can redistribute it and/or modify
it under the same terms as Perl itself, either Perl version 5.8.8 or,
at your option, any later version of Perl 5 you may have available.

=cut



TODO in future releases: See TODO file.

Undocumented:
$Forks::Super::Job::self              available in child process. Reference to the job object that launched the process.

$Forks::Super::SOCKET_READ_TIMEOUT    in _read_socket, length of time to wait for input on the sockethandle being read
                                      before returning  undef 

fork { retries => $n }                if CORE::fork() fails, retry up to $n times
