package Forks::Super; # subject to change
require 5.006001;     # for improvements to Perl fork and signal handling
use Exporter;
use POSIX ':sys_wait_h';
use Carp;
use File::Path;
use strict;
use warnings;

our $VERSION = '0.07';
use base 'Exporter'; # our @ISA = qw(Exporter);

our @EXPORT = qw(fork wait waitall waitpid);
our @EXPORT_OK = qw(isValidPid pause Time);
our %EXPORT_TAGS = ( 'test' =>  [ 'isValidPid', 'Time' ],
		     'test_config' => [ 'isValidPid', 'Time' ]);

sub _init {
  return if $Forks::Super::INITIALIZED;
  $Forks::Super::INITIALIZED++;
  $Forks::Super::MAIN_PID = $$;
  # open(Forks::Super::DEBUG, '>&',STDERR)   # "bareword" in v5.6.x
  open(Forks::Super::DEBUG, '>&STDERR') 
    or *Forks::Super::DEBUG = *STDERR 
    or carp "Debugging not available in Forks::Super module!\n";
  $Forks::Super::REAP_NOTHING_MSGS = 0;
  $Forks::Super::NUM_PAUSE_CALLS = 0;
  $Forks::Super::NEXT_DEFERRED_ID = -100000;
  %Forks::Super::CONFIG = ();

  $Forks::Super::MAX_PROC = 0;
  $Forks::Super::MAX_LOAD = 0;
  $Forks::Super::DEBUG = 0;
  $Forks::Super::ON_BUSY = 'block';
  $Forks::Super::CHILD_FORK_OK = 0;
  $Forks::Super::QUEUE_MONITOR_FREQ = 30;
  $Forks::Super::DONT_CLEANUP = 0;

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
      if ($Forks::Super::ON_BUSY ne "block" &&
	  $Forks::Super::ON_BUSY ne "fail" &&
	  $Forks::Super::ON_BUSY ne "queue") {
	carp "Forks::Super::import(): ",
	  "Invalid value \"$Forks::Super::ON_BUSY\" for ON_BUSY";
	$Forks::Super::ON_BUSY = "block";
      }
    } elsif ($args[$i] eq "CHILD_FORK_OK") {
      $Forks::Super::CHILD_FORK_OK = $args[++$i];
    } elsif ($args[$i] eq "QUEUE_MONITOR_FREQ") {
      $Forks::Super::QUEUE_MONITOR_FREQ = $args[++$i];
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

  debug('fork(): ', $job->toString(), ' initialized.') if $Forks::Super::DEBUG;

  until ($job->can_launch) {

    debug("fork(): job can not launch. Behavior=$job->{_on_busy}")
      if $Forks::Super::DEBUG;

    if ($job->{_on_busy} eq "FAIL") {
      return -1;
    } elsif ($job->{_on_busy} eq "QUEUE") {
      queue_job($job);
      return $job->{pid};
    } else {
      pause();
    }
  }

  debug('Forks::Super::fork(): launch approved for job')
    if $Forks::Super::DEBUG;
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
  if ($target == -1) {
    return _waitpid_any($no_hang);
  } elsif (defined $Forks::Super::ALL_JOBS{$target}) {
    return _waitpid_target($no_hang, $target);
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
# a CHLD or USR1 signal in the middle of the
# sleep call.
#
sub pause {
  my $delay = shift || 0.25;
  my $expire = Forks::Super::Time() + ($delay || 0.25);

  if (CONFIG("Time::HiRes")) {
    while (Forks::Super::Time() < $expire) {
      if ($^O eq "MSWin32") {
	handle_CHLD(-1);
	run_queue() if @Forks::Super::QUEUE > 0;
      }

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
      $job->{state} = 'COMPLETE';
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
    $job->mark_reaped;

    debug("Forks::Super::_reap(): reaping $pid/$real_pid.")
      if $Forks::Super::DEBUG;
    return $real_pid if not wantarray;

    my $nactive = grep { $_->{state} eq 'ACTIVE'  or
			   $_->{state} eq 'DEFERRED'  or
			   $_->{state} eq 'SUSPENDED'  or    # for future use
			   $_->{state} eq 'COMPLETE' } @j;

    debug("Forks::Super::_reap(): $nactive remain.") if $Forks::Super::DEBUG;
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

    if ($Forks::Super::REAP_NOTHING_MSGS % 5 == 0) {
      debug('-------------------------');
      debug('Active jobs:');
      debug('   ', $_->toString()) for @active;
      debug('-------------------------');
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
  $SIG{USR1} = 'DEFAULT' if CONFIG("SIGUSR1");
  delete $Forks::Super::CONFIG{filehandles};
  undef $Forks::Super::FH_DIR;
  undef $Forks::Super::FH_DIR_DEDICATED;
  return;
}

sub child_exit {
  my ($code) = @_;
  if (CONFIG("alarm")) {
    alarm 0;
  }
  # close filehandles ? Nah.
  exit($code);
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
# to periodically send USR1 signals to this
#
sub _launch_queue_monitor {
  return unless CONFIG("SIGUSR1");

  $Forks::Super::QUEUE_MONITOR_PID = CORE::fork();
  $SIG{USR1} = \&Forks::Super::handle_USR1;
  if (not defined $Forks::Super::QUEUE_MONITOR_PID) {
    warn "queue monitoring sub process could not be launched: $!\n";
    return;
  }
  if ($Forks::Super::QUEUE_MONITOR_PID == 0) {
    init_child();
    for (;;) {
      sleep $Forks::Super::QUEUE_MONITOR_FREQ;
      kill 'USR1', $Forks::Super::MAIN_PID;
    }
    Forks::Super::child_exit(0);
  }
  return;
}

END {
  if (defined $Forks::Super::QUEUE_MONITOR_PID &&
      $Forks::Super::QUEUE_MONITOR_PID > 0) {
    kill 3, $Forks::Super::QUEUE_MONITOR_PID;
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

  # what will run_queue do?
  #   assemble all DEFERRED jobs
  #   order by priority
  #   go through the list and attempt to launch each job in order.

  debug('run_queue(): examining deferred jobs') if $Forks::Super::DEBUG;
  my @deferred_jobs = sort { $b->{queue_priority} <=> $a->{queue_priority} }
    grep { defined $_->{state} &&
	     $_->{state} eq 'DEFERRED' } @Forks::Super::ALL_JOBS;
  foreach my $job (@deferred_jobs) {
    if ($job->can_launch) {
      debug("Launching deferred job $job->{pid}") if $Forks::Super::DEBUG;
      my $pid = $job->launch();
      if ($pid == 0) {
	if (defined $job->{sub} or defined $job->{cmd}) {
	  croak "Forks::Super::run_queue(): ",
	    "fork on deferred job unexpectedly returned a process id of 0!\n";
	}
	croak "Forks::Super::run_queue(): ",
	  "deferred job must have a 'sub' or 'cmd' option!\n";
      }
    } elsif ($Forks::Super::DEBUG) {
      debug("Still must wait to launch job $job->{pid}");
    }
  }
  queue_job(); # refresh @Forks::Super::QUEUE
  return;
}

#
# SIGUSR1 handler. A background process will send periodic USR1 signals
# back to this process. On receipt of these signals, this process
# should examine the queue. This will keep us from ignoring the queue
# for too long.
#
sub handle_USR1 {
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
  debug("Forks::Super::handle_CHLD(): $sig received") if $Forks::Super::DEBUG;

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
      $j->{end} = Forks::Super::Time();
      $j->{status} = $status;
      $j->{state} = 'COMPLETE';
    } else {
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
    $Forks::Super::CONFIG{"SIGUSR1"} = $^O eq "MSWin32" ? 0 : 1;
    # XXX - SIGUSR1 is probably not available on more systems than this ...
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
    $job = $Forks::Super::ALL_JOBS{$job} || return;
  }
  return $job->{status}; # might be undef
}

sub write_stdin {
  my ($job, @msg) = @_;
  if (ref $job ne 'Forks::Super::Job') {
    $job = $Forks::Super::ALL_JOBS{$job} || return;
  }
  my $fh = $job->{child_stdin};
  if (defined $fh) {
    print $fh @msg;
  } else {
    carp "Forks::Super::write_stdin(): ",
      "Attempted write on child $job->{pid} with no STDIN filehandle";
  }
  return;
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
    if ($Forks::Super::DEBUG) {
      debug("Forks::Super::read_stdout(): ",
	    "fh closed for $job->{pid}");
    }
    return;
  }
  my $fh = $job->{child_stdout};
  if (not defined $fh) {
    if ($Forks::Super::DEBUG) {
      debug("Forks::Super::read_stdout(): ",
	    "fh unavailable for $job->{pid}");
    }
    $job->{child_stdout_closed}++;
    return;
  }

  undef $!;
  if (wantarray) {
    my @lines = readline($fh);
    if (0 == @lines) {
      if ($job->is_complete && Forks::Super::Time() - $job->{end} > 3) {
	if ($Forks::Super::DEBUG) {
	  debug("Forks::Super::read_stdout(): ",
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
	if ($Forks::Super::DEBUG) {
	  debug("Forks::Super::read_stdout(): :",
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
    if ($Forks::Super::DEBUG) {
      debug("Forks::Super::read_stderr(): ",
	    "fh closed for $job->{pid}");
    }
    return;
  }
  my $fh = $job->{child_stderr};
  if (not defined $fh) {
    if ($Forks::Super::DEBUG) {
      debug("Forks::Super::read_stderr(): ",
	    "fh unavailable for $job->{pid}");
    }
    $job->{child_stderr_closed}++;
    return;
  }

  undef $!;
  if (wantarray) {
    my @lines = <$fh>;
    if (0 == @lines) {
      if ($job->is_complete && Forks::Super::Time() - $job->{end} > 3) {
	if ($Forks::Super::DEBUG) {
	  debug("Forks::Super::read_stderr(): ",
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
    my $line = <$fh>;
    if (not defined $line) {
      if ($job->is_complete && Forks::Super::Time() - $job->{end} > 3) {
	if ($Forks::Super::DEBUG) {
	  debug("Forks::Super::read_stderr(): ",
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

sub debug {
  my @msg = @_;
  if ($Forks::Super::DEBUG) {
    print Forks::Super::DEBUG Forks::Super::Ctime()," ",@msg,"\n";
  }
  return;
}

1;

#############################################################################

package Forks::Super::Job; # package name subject to change
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

sub mark_reaped {
  my $job = shift;
  $job->{state} = 'REAPED';
  $job->{reaped} = Forks::Super::Time();
  $? = $job->{status};
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
	'start delay requested. launch fail') if $Forks::Super::DEBUG;
  $job->{_on_busy} = 'queue' if not defined $job->{_on_busy};
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
	if $Forks::Super::DEBUG;
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
	if $Forks::Super::DEBUG;
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
  my $job = shift;
  my $max_proc = defined $job->{max_proc}
    ? $job->{max_proc} : $Forks::Super::MAX_PROC;
  my $max_load = defined $job->{max_load}
    ? $job->{max_load} : $Forks::Super::MAX_LOAD;
  my $force = defined $job->{max_load} && $job->{force};

  if ($force) {
    debug('Forks::Super::Job::_can_launch(): force attr set. launch ok')
      if $Forks::Super::DEBUG;
    return 1;
  }

  return 0 if not $job->_can_launch_delayed_start_check;
  return 0 if not $job->_can_launch_dependency_check;

  if ($max_proc > 0) {
    my $num_active = Forks::Super::count_active_processes();
    if ($num_active >= $max_proc) {
      debug('Forks::Super::Job::_can_launch(): ',
	"active jobs $num_active exceeds limit $max_proc. ",
	    'launch fail.') if $Forks::Super::DEBUG;
      return 0;
    }
  }

  if (0 && $max_load > 0) {  # feature disabled
    my $load = Forks::Super::get_cpu_load();
    if ($load > $max_load) {
      debug('Forks::Super::Job::_can_launch(): ',
	"cpu load $load exceeds limit $max_load. launch fail.")
	if $Forks::Super::DEBUG;
      return 0;
    }
  }

  debug('Forks::Super::Job::_can_launch(): system not busy. launch ok.')
    if $Forks::Super::DEBUG;
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







  my $pid = CORE::fork();







  if (not defined $pid) {
    debug('Forks::Super::Job::launch(): CORE::fork() returned undefined!')
      if $Forks::Super::DEBUG;
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
	$job->{state} = 'COMPLETE';
	($job->{end}, $job->{status})
	  = @{delete $Forks::Super::BASTARD_DATA{$pid}};
      }
    }
    $job->{real_pid} = $pid;
    $job->{pid} = $pid unless defined $job->{pid};
    $job->{start} = Forks::Super::Time();

    $job->config_parent;
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
    my $c1 = system( @{$job->{cmd}} );
    Forks::Super::child_exit($c1 >> 8);
  } elsif ($job->{style} eq 'sub') {
    no strict 'refs';
    $job->{sub}->(@{$job->{args}});
    Forks::Super::child_exit(0);
  }
  return 0;
}

sub _launch_from_child {
  my $job = shift;
  if ($Forks::Super::CHILD_FORK_OK == 0) {
    if ($Forks::Super::IMPORT{":test"}) {
      print STDERR "fork() not allowed from child\n";
    } else {
      carp 'Forks::Super::Job::launch(): fork() not allowed ',
	"in child process $$ while \$Forks::Super::CHILD_FORK_OK ",
	"is not set!\n";
    }
    return;
  } elsif ($Forks::Super::CHILD_FORK_OK == -1) {
    if ($Forks::Super::IMPORT{":test"}) {
      print STDERR "fork() not allowed from child. Using CORE::fork()\n";
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
  return $Forks::Super::ALL_JOBS{$id} if defined $Forks::Super::ALL_JOBS{$id};
  my @j = grep { defined $_->{pid}  &&
		   $_->{pid}==$id } @Forks::Super::ALL_JOBS;
  return $j[0] if @j > 0;
  @j = grep { defined $_->{real_pid}  &&
		$_->{real_pid}==$id } @Forks::Super::ALL_JOBS;
  return @j > 0 ? $j[0] : undef;
}

#
# do further initialization of a Forks::Super::Job object,
# mainly setting derived fields
#
sub preconfig {
  #no warnings qw(once);
  my $job = shift;

  $job->preconfig_style;
  $job->preconfig_busy_action;
  $job->preconfig_start_time;
  $job->preconfig_dependencies;
  return;
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
  } elsif (defined $job->{sub}) {
    $job->{style} = "sub";
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

sub preconfig_fh {
  my $job = shift;

  my $config = {};
  if (defined $job->{get_child_fh} or defined $job->{get_child_filehandles}) {
    $config->{get_child_stdin} = 1;
    $config->{get_child_stdout} = 1;
    $config->{get_child_stderr} = 1;
  } else {
    foreach my $key (qw(get_child_stdin get_child_stdout
			get_child_stderr join_child_stderr)) {
      $config->{$key} = $job->{$key} if defined $job->{$key};
    }
  }

  # choose file names
  if ($config->{get_child_stdin}) {
    $config->{f_in} = _choose_fh_filename();
    debug("Using $config->{f_in} as shared file for child STDIN") 
      if $Forks::Super::DEBUG;
  }
  if ($config->{get_child_stdout}) {
    $config->{f_out} = _choose_fh_filename();
    debug("Using $config->{f_out} as shared file for child STDOUT") 
      if $Forks::Super::DEBUG;
  }
  if ($config->{get_child_stderr}) {
    $config->{f_err} = _choose_fh_filename();
    debug("Using $config->{f_err} as shared file for child STDERR") 
      if $Forks::Super::DEBUG;
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
      debug("$file already exists ...");
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
      if $Forks::Super::DEBUG;
  }
  return;
}

sub preconfig_dependencies {
  my $job = shift;

  ##########################
  # assert dependencies are expressed as array refs
  #
  if ((defined $job->{depend_on}) and (ref $job->{depend_on} eq '')) {
    $job->{depend_on} = [ $job->{depend_on} ];
  }
  if ((defined $job->{depend_start}) and (ref $job->{depend_start} eq '')) {
    $job->{depend_start} = [ $job->{depend_start} ];
  }
  return;
}


END {
  $SIG{CHLD} = 'DEFAULT';
  if (defined $Forks::Super::FH_DIR && !$Forks::Super::DONT_CLEANUP) {
    END_cleanup();
  }
}

# if we have created temporary files for 
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
      debug('END block: clean up files in ',
	    "dedicated IPC file dir $Forks::Super::FH_DIR") if $Forks::Super::DEBUG;
    }

    # XXX - cleanup can fail if child processes outlive the parent ... 
    # XXX - what can we do? launch a background process to try and
    #       clean up the directory for up to five minutes ??

    my $clean_up_ok = File::Path::rmtree($Forks::Super::FH_DIR, 0, 1);
    if ($clean_up_ok <= 0) {
      warn "Clean up of $Forks::Super::FH_DIR may not have succeeded.\n";

#      debug("will try to clean up $Forks::Super::FH_DIR in background");
#      if (CORE::fork() == 0) {
#	for (my $i = 0; $i < 5; $i++) {
#	  sleep 60;
#	  if (0 < File::Path::rmtree($Forks::Super::FH_DIR, 0, 1)) {
#	    last;
#	  }
#	}
#	exit 0;
#      }


    }
    if (-d $Forks::Super::FH_DIR) {
      rmdir $Forks::Super::FH_DIR
	or warn "Failed to remove $Forks::Super::FH_DIR/: $!\n";
    }
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
  $job->config_fh_parent;   # XXX - this is only thing to do right now for parent
  $job->{pgid} = getpgrp($job->{pid}) if Forks::Super::CONFIG("getpgrp");
  return;
}

sub config_fh_parent_stdin {
  my $job = shift;
  my $fh_config = $job->{fh_config};

  if ($fh_config->{get_child_stdin} and defined $fh_config->{f_in}) {
    my $fh;
    debug("Opening $fh_config->{f_in} in parent as child STDIN")
      if $Forks::Super::DEBUG;
    if (open ($fh, '>', $fh_config->{f_in})) {
      $job->{child_stdin} = $Forks::Super::CHILD_STDIN{$job->{real_pid}} = $fh;
      $Forks::Super::CHILD_STDIN{$job->{pid}} = $fh;
      $fh->autoflush(1);

      debug("Setting up link to $job->{pid} stdin in $fh_config->{f_in}")
	if $Forks::Super::DEBUG;

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

  if ($fh_config->{get_child_stdout} and defined $fh_config->{f_out}) {
    # creation of $fh_config->{f_out} may be delayed. 
    # don't panic if we can't open it right away.
    my ($try, $fh);
    debug("Opening ", $fh_config->{f_out}, " in parent as child STDOUT")
      if $Forks::Super::DEBUG;
    for ($try=1; $try<=11; $try++) {
      local $! = 0;
      if ($try <= 10 && open($fh, '<', $fh_config->{f_out})) {

	$job->{child_stdout} = $Forks::Super::CHILD_STDOUT{$job->{real_pid}} = $fh;
	$Forks::Super::CHILD_STDOUT{$job->{pid}} = $fh;

	debug("Setting up link to $job->{pid} stdout in $fh_config->{f_out}")
	  if $Forks::Super::DEBUG;

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
  return;
}

sub config_fh_parent_stderr {
  my $job = shift;
  my $fh_config = $job->{fh_config};

  if ($fh_config->{get_child_stderr} and defined $fh_config->{f_err}) {
    delete $fh_config->{join_child_stderr};
    my ($try, $fh);
    debug("Opening ", $fh_config->{f_err}, " in parent as child STDERR")
      if $Forks::Super::DEBUG;
    for ($try=1; $try<=11; $try++) {
      if ($try <= 10 && open($fh, '<', $fh_config->{f_err})) {
	$job->{child_stderr} = $Forks::Super::CHILD_STDERR{$job->{real_pid}} = $fh;
	$Forks::Super::CHILD_STDERR{$job->{pid}} = $fh;

	debug("Setting up link to $job->{pid} stderr in $fh_config->{f_err}")
	  if $Forks::Super::DEBUG;

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
  if ($fh_config->{join_child_stderr}) {
    $job->{child_stderr} = $Forks::Super::CHILD_STDERR{$job->{real_pid}}
      = $Forks::Super::CHILD_STDOUT{$job->{real_pid}};
    $Forks::Super::CHILD_STDERR{$job->{pid}} = $Forks::Super::CHILD_STDOUT{$job->{pid}};
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

  my $fh_config = $job->{fh_config};

  # set up stdin first.
  $job->config_fh_parent_stdin;
  $job->config_fh_parent_stdout;
  $job->config_fh_parent_stderr;

  return;
}

sub config_child {
  my $job = shift;
  $job->config_fh_child;
  $job->config_timeout_child;
  $job->config_os_child;
  return;
}

sub config_fh_child_stdin {
  my $job = shift;
  local $!;
  undef $!;
  my $fh_config = $job->{fh_config};

  if ($fh_config->{get_child_stdin} && $fh_config->{f_in}) {
    # creation of $fh_config->{f_in} may be delayed. 
    # don't panic if we can't open it right away.
    my ($try, $fh);
    debug("Opening ", $fh_config->{f_in}, " in child STDIN") if $Forks::Super::DEBUG;
    for ($try=1; $try<=11; $try++) {
      if ($try <= 10 && open($fh, '<', $fh_config->{f_in})) {
	close STDIN if $^O eq "MSWin32";
	open(STDIN, '<&' . fileno($fh) )
	  or warn "Forks::Super::Job::config_fh_child(): ",
	    "could not attach child STDIN to input filehandle: $!\n";

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

  if ($fh_config->{get_child_stdout} && $fh_config->{f_out}) {
    my $fh;
    debug("Opening up $fh_config->{f_out} for output in the child   $$")
      if $Forks::Super::DEBUG;
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

  if ($fh_config->{get_child_stderr} && $fh_config->{f_err}) {
    my $fh;
    debug("Opening $fh_config->{f_err} as child STDERR")
      if $Forks::Super::DEBUG;
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
  if ($Forks::Super::DEBUG && $job->{undebug}) {
    debug("Disabling debugging in child $$");
    $Forks::Super::DEBUG = 0;
  }
  if ($job->{style} eq 'cmd') {
    $job->config_cmd_fh_child;
    return;
  }

  $job->config_fh_child_stdout;
  $job->config_fh_child_stderr;
  $job->config_fh_child_stdin;
  return;
}

# McCabe score: 24
sub config_cmd_fh_child {
  my $job = shift;
  my $fh_config = $job->{fh_config};
  my @cmd = @{$job->{cmd}};
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
  if ($fh_config->{get_child_stderr} && $fh_config->{f_err}) {
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
    if $Forks::Super::DEBUG;

  $job->{cmd} = [ @cmd ];
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
  $timeout = $job->{timeout} if defined $job->{timeout};
  if (defined $job->{expiration}) {
    if ($job->{expiration} - Forks::Super::Time() < $timeout) {
      $timeout = $job->{expiration} - Forks::Super::Time();
    }
  }
  if ($timeout < 1) {
    if ($Forks::Super::IMPORT{":test"}) {
      die "quick timeout\n";
    } 
    croak "Forks::Super::Job::config_timeout_child(): quick timeout";
  } elsif ($timeout < 9E8) {
    $SIG{ALRM} = sub { die "Timeout\n" };
    if (Forks::Super::CONFIG("alarm")) {
      alarm $timeout;
      debug("Forks::Super::Job::config_timeout_child(): ",
	    "alarm set for ${timeout}s in child process $$")
	if $Forks::Super::DEBUG;
    } else {
      carp "Forks::Super: alarm() not available, ",
	"timeout,expiration options ignored.\n";
    }
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

  $ENV{_FORK_PPID} = $$ if $^O eq "MSWin32";
  if (defined $job->{os_priority}) {
    my $p = $job->{os_priority} + 0;
    my $q = -999;
    my $z = eval "setpriority(0,0,$p); \$q = getpriority(0,0)";
    if ($@) {
      carp "Forks::Super::Job::config_os_child(): ",
	"setpriority() call failed $p ==> $q\n";
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
	  if ($Forks::Super::DEBUG) {
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
      my $z = eval 'BSD::Process::Affinity->get_process_mask()->from_bitmask($n)->update()';
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
      { "GetCurrentThreadId" =>
		Win32::API->new('kernel32','GetCurrentThreadId','','N'),
	"OpenThread" =>
		Win32::API->new('kernel32', 
				q[HANDLE OpenThread(DWORD a,BOOL b,DWORD c)]),
	"SetThreadAffinityMask" =>
		Win32::API->new('kernel32',
				"DWORD SetThreadAffinityMask(HANDLE h,DWORD d)")
      };
    if ($!) {
      $win32_thread_api->{"_error"} = "$! / $^E";
    }
    undef $!;
    $win32_thread_api->{"GetProcessAffinityMask"} =
      Win32::API->new('kernel32', "BOOL GetProcessAffinityMask(HANDLE h,PDWORD a,PDWORD b)");
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
  foreach my $attr (qw(realpid style cmd sub args start end reaped 
		       status closure)) {
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
  Forks::Super::debug(@msg) if $Forks::Super::DEBUG;
  return;
}

1;

__END__

=head1 NAME

Forks::Super - extensions and convenience methods for managing background processes.

=head1 VERSION

Version 0.07

=head1 SYNOPSIS

    use Forks::Super;
    use Forks::Super MAX_PROC => 5, DEBUG => 1;

    # familiar use - parent return PID>0, child returns zero
    $pid = fork();
    die "fork failed" unless defined $pid;
    if ($pid > 0) {
        # parent code
    } else {
        # child code
    }

    # wait for a child process to finish
    $w = wait;                  # blocking wait for any child, $? hold exit status of child
    $w = waitpid $pid, 0;       # blocking wait for specific child
    $w = waitpid $pid, WNOHANG; # non blocking wait, use with POSIX ':sys_wait_h'
    $w = waitpid 0, $flag;      # wait on any process in the current process group
    waitall;                    # block until all children are finished

    # -------------- helpful extensions ---------------------
    # fork directly to a shell command. Child doesn't return.
    $pid = fork { cmd => "./myScript 17 24 $n" };
    $pid = fork { cmd => [ "/bin/prog" , $file, "-x", 13 ] };

    # fork directly to a Perl subroutine. Child doesn't return.
    $pid = fork { 'sub' => $methodNameOrRef , 'args' = [ @methodArguments ] };
    $pid = fork { 'sub' => \&subroutine, 'args' = [ @args ] };
    $pid = fork { 'sub' => sub { "anonymous sub" }, 'args' = [ @args ] );

    # put a time limit on the child process
    $pid = fork { cmd => $command, timeout => 30 };            # kill child if not done in 30s
    $pid = fork { sub => $subRef , expiration => 1260000000 }; # complete by 8AM Dec 5, 2009 UTC

    # obtain standard filehandles for the child process
    $pid = fork { get_child_filehandles => 1 };
    if ($pid == 0) {      # child process
      $x = <STDIN>; # read "Clean your room" command from parent
      print "from the mouth of babes\n";   # same as  print STDOUT ...
      print STDERR "oops, child is crying\n";
      exit 0;
    } elsif ($pid > 0) {  # parent process
      print {$Forks::Super::CHILD_STDIN{$pid}} "Clean your room\n";
      $child_response = < {$Forks::Super::CHILD_STDOUT{$pid}} >;   # read "from the mouth of babes" from child
      $child_response = Forks::Super::read_stdout($pid);    # same as  <{$Forks::Super::CHILD_STDOUT{$pid}}>
      $child_err_msg = < {$Forks::Super::CHILD_STDERR{$pid}} >;    # read "oops, child is crying"
      $child_err_msg = Forks::Super::read_stderr($pid);     # same as  <{$Forks::Super::CHILD_STDERR{$pid}}>
    }

    # ---------- manage jobs and system resources ---------------
    # this runs 100 tasks but the fork call blocks when there are already 5 jobs running
    $Forks::Super::MAX_PROC = 5;
    $Forks::Super::ON_BUSY = 'block';
    for ($i=0; $i<100; $i++) {
      $pid = fork { cmd => $task[$i] };
    }

    # jobs fail (without blocking) if the system is too busy
    $Forks::Super::MAX_PROC = 5;
    $Forks::Super::ON_BUSY = 'fail';
    $pid = fork { cmd => $task };
    if ($pid > 0) { print "'$task' is running\n" }
    elsif ($pid < 0) { print "5 or more jobs running -- didn't start '$task'\n"; }

    # $Forks::Super::MAX_PROC setting can be overridden. This job will start immediately if < 3 jobs running
    $pid = fork { sub => 'MyModule::MyMethod', args => [ @b ], max_proc => 3 };

    # try to fork no matter how busy the system is
    $pid = fork { force => 1 };

    # when system is busy, queue jobs. When system is not busy, some jobs on the queue will start.
    # if job is queue, return value from fork() is a very negative number
    $Forks::Super::ON_BUSY = 'queue';
    $pid = fork { cmd => $command };
    $pid = fork { cmd => $useless_command, queue_priority => -5 };
    $pid = fork { cmd => $important_command, queue_priority => 5 };
    $pid = fork { cmd => $future_job, delay => 20 }   # put this job on queue for at least 20s

    # set up dependency relationships
    $pid1 = fork { cmd => $job1 };
    $pid2 = fork { cmd => $job2, depend_on => $pid1 };            # put on queue until job 1 is complete
    $pid4 = fork { cmd => $job4, depend_start => [$pid2,$pid3] }; # put on queue until jobs 2,3 have started

    # job information
    $state = Forks::Super::state($pid);    # ACTIVE, DEFERRED, COMPLETE, REAPED
    $status = Forks::Super::status($pid);  # exit status for completed jobs

=head1 DESCRIPTION

This package provides new definitions for the Perl functions
C<fork>, C<wait>, and C<waitpid> with richer functionality.
The new features are designed to make it more convenient to
spawn background processes and more convenient to manage them
and to get the most out of your system's resources.

=head1 $pid = fork( \%options )

The new C<fork> call attempts to spawn a new process.
With no arguments, it behaves the same as the Perl system
call C<fork()>:

=over 4

=item * creating a new process running the same program at the same point

=item * returning the process id (PID) of the child process to the parent

On Windows, this is a I<pseudo-process ID> 

=item * returning 0 to the child process

=item * returning C<undef> if the fork call was unsuccessful

=back

=head2 Options for instructing the child process

The C<fork> call supports two options, C<cmd> and C<sub> (or C<sub>/C<args>)
that will instruct the child process to carry out a specific task. Using 
either of these options causes the child process not to return from the 
C<fork> call.

=over 4

=item $child_pid = fork { cmd => $shell_command }

=item $child_pid = fork { cmd => @shell_command }

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

=item $child_pid = fork { sub => $subroutineName [, args => \@args ] }

=item $child_pid = fork { sub => \&subroutineReference [, args => \@args ] }

=item $child_pid = fork { sub => sub { ... subroutine defn ... } [, args => \@args ] }

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

=item fork { timeout => $delay_in_seconds }

=item fork { expiration => $timestamp_in_seconds_since_epoch_time }

Puts a deadline on the child process and causes the child to C<die> 
if it has not completed by the deadline. With the C<timeout> option,
you specify that the child process should not survive longer than the
specified number of seconds. With C<expiration>, you are specifying
an epoch time (like the one returned by the C<time> function) as the
child process's deadline.

If the deadline is some time in the past (if the timeout is
not positive, or the expiration is earlier than the current time),
then the child process will die immediately after it is created.

Note that this feature uses the Perl C<alarm> call with a
handler for C<SIGALRM>. If you use this feature and also specify a
C<sub> to invoke, and that subroutine also tries to use the
C<alarm> feature or set a handler for C<SIGALRM>, the results 
will be undefined.

=item fork { delay => $delay_in_seconds }

=item fork { start_after => $timestamp_in_epoch_time }

Causes the child process to be spawned at some time in the future. 
The return value from a C<fork> call that uses these features
will not be a process id, but it will be a very negative number
called a job ID. See the section on L</"Deferred Processes">
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

=item fork { get_child_filehandles => 1 }

=item fork { get_child_stdin => $bool, get_child_stdout => $bool, get_child_stderr => $bool }

=item fork { get_child_stdout => $bool, join_child_stderr => $bool }

Launches a child process and makes the child process's 
STDIN, STDOUT, and/or STDERR filehandles available to
the parent process in the scalar variables
$Forks::Super::CHILD_STDIN{$pid}, $Forks::Super::CHILD_STDOUT{$pid},
and/or $Forks::Super::CHILD_STDERR{$pid}, where $pid is the PID
return value from the fork call. This feature makes it possible,
even convenient, for a parent process to communicate with a
child, as this contrived example shows.

    $pid = fork { sub => \&pig_latinize, timeout => 10,
                  get_child_filehandles => 1 };

    # in the parent, $Forks::Super::CHILD_STDIN{$pid} is an *output* filehandle
    print {$Forks::Super::CHILD_STDIN{$pid}} "The blue jay flew away in May\n";

    sleep 2; # give child time to do its job

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

The option C<get_child_filehandles> will obtain filehandles for the child's
STDIN, STDOUT, and STDERR filehandles. If C<get_child_filehandles> is omitted,
the fork() call will obtain those filehandles specified with
C<get_child_stdin>, C<get_child_stdout>, and/or C<get_child_stderr> options. If the
C<join_child_stderr> option is specified, then both the child's STDOUT and
STDERR will be returned in the single $Forks::Super::CHILD_STDOUT{$pid} filehandle.

=back

=head2 Options for complicated job management

The C<fork()> call from this module supports options that help to
manage child processes or groups of child processes in ways to better
manage your system's resources. For example, you may have a lot of tasks
to perform in the background, but you don't want to overwhelm your 
(possibly shared) system by running them all at once. There are features
to control how many, how, and when your jobs will run.

=over 4

=item $Forks::Super::MAX_PROC = $max_simultaneous_jobs

Specifies the maximum number of background processes that you want to run.
If a C<fork> call is attempted while there are already the maximum
number of child processes running, then the C<fork()> call will either
block (until some child processes complete), fail (return a negative
value without spawning the child process), or queue the job (returning
a very negative value called a job ID), according to the specified
"on_busy" behavior (see the next item). See the L</"Deferred processes">
section for information about how queued jobs are handled.

On any individual C<fork> call, the maximum number of processes may be
overridden by also specifying C<max_proc> or C<force> options. See below.

Setting $Forks::Super::MAX_PROC to zero or a negative number will disable the
check for too many simultaneous processes.

=item $Forks::Super::ON_BUSY = "block" | "fail" | "queue"

Dictates the behavior of C<fork> in the event that the module is not allowed
to launch the specified job for whatever reason.

=over 4

=item "block"

If the system cannot create a new child process for the specified job,
it will wait and periodically retry to create the child process until
it is successful. Unless a system fork call is attempted and fails,
C<fork> calls that use this behavior will return a positive PID.

=item "fail"

If the system cannot create a new child process for the specified job,
the C<fork> call will immediately return with a small negative
value.

=item "queue"

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

=item fork { force => $bool }

If the C<force> option is set, the C<fork> call will disregard the
usual criteria for deciding whether a job can spawn a child process,
and will always attempt to create the child process.

=item fork { queue_priority => $priority }

In the event that a job cannot immediately create a child process and
is put on the job queue (see L</"Deferred processes">), the C{queue_priority}
specifies the relative priority of the job on the job queue. In general,
eligible jobs with high priority values will be started before jobs
with lower priority values.

=item fork { depend_on => $pid }

=item fork { depend_on => [ $pid_1, $pid_2, ... ] }

=item fork { depend_start => $pid }

=item fork { depend_start => [ $pid_1, $pid_2, ... ] }

Indicates a dependency relationship between the job in this C<fork>
call and one or more other jobs. If a C<fork> call specifies a
C<depend_on> option, then that job will be deferred until
all of the child processes specified by the process or job IDs
have B<completed>. If a C<fork> call specifies a
C<depend_start> option, then that job will be deferred until
all of the child processes specified by the process or job
IDs have B<started>.

Invalid process and job IDs in a C<depend_on> or C<depend_start>
setting will produce a warning message but will not prevent 
a job from starting.

=item fork { can_launch = \&methodName }

=item fork { can_launch = sub { ... anonymous sub ... } }

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

=item fork { os_priority => $priority }

On supported operating systems, and after the successful creation
of the child process, attempt to set the operating system priority
of the child process.

On unsupported systems, this option is ignored.

=item fork { cpu_affinity => $bitmask }

On supported operating systems, and after the successful creation of 
the child process, attempt to set the process's CPU affinity.
Each bit of the bitmask represents one processor. Set a bit to 1
to allow the process to use the corresponding processor, and set it to
0 to disallow the corresponding processor. There may be additional
restrictions on the valid range of values imposed by the operating
system.

As of version 0.07, supported systems are Cygwin, Win32, Linux,
and possibly BSD.

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

=item $reaped_pid = wait

Like the Perl C<wait> system call, blocks until a child process
terminates and returns the PID of the deceased process,
or C<-1> if there are no child processes remaining to reap.
The exit status of the child is returned in $?.

=item $reaped_pid = waitpid $pid, $flags

Waits for a child with a particular PID or a child from
a particular process group to terminate and returns the
PID of the deceased process, or C<-1> if there is no
suitable child process to reap. If the return value contains
a PID, then $? is set to the exit status of that process.

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

A negative $pid that is not recognized as a valid job ID
will be interpreted as a process group ID, and the C<waitpid>
function will return the PID of the first available child 
from the same process group.

On some systems, a $flags value of C<POSIX::WNOHANG>
is supported to perform a non-blocking wait. See the
Perl C<waitpid> documentation.

=item waitall

Blocking wait for all child processes, including deferred
jobs that have not started at the time of the C<waitall>
call.

=item Forks::Super::isValidPid( $pid )

Tests whether the return value of a C<fork> call indicates that
a background process was successfully created or not. On POSIX
systems it is sufficient to check whether C<$pid> is a
positive integer, but C<isValidPid> is a more 

=item Forks::Super::pause($delay)

A B<productive> drop-in replacement for the Perl C<sleep>
system call (or C<Time::HiRes::sleep>, if available). On
systems like Windows that lack a proper method for
handling C<SIGCHLD> events, the C<Forks::Super::pause> method
will occasionally reap child processes that have completed
and attempt to dispatch jobs on the queue. 

On other systems, using C<Forks::Super::pause> is less vulnerable
than C<sleep> to interruptions from this module (See 
L<"BUGS AND LIMITATIONS"> below).

=item Forks::Super::child_exit($code)

The C<child_exit> routine can be used as a drop in replacement of
C<exit> on a child process. Someday I'll think of some child
clean up code to put in there and encourage you to use it.

=item $status = Forks::Super::status($pid)

Returns the exit status of a completed child process
represented by process ID or job ID $pid. Aside from being
a permanent store of the exit status of a job, using this
method might be a more reliable indicator of a job's status
than checking $? after a C<wait> or C<waitpid> call. It is
possible for this module's C<SIGCHLD> handler to temporarily
corrupt the $? value while it is checking for deceased
processes.

=item $line = Forks::Super::read_stdout($pid)

=item @lines = Forks::Super::read_stdout($pid)

=item $line = Forks::Super::read_stderr($pid)

=item @lines = Forks::Super::read_stderr($pid)

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

=item $job = Forks::Super::Job::get($pid)

Returns a C<Forks::Super::Job> object associated with process ID or job ID C<$pid>.
See L<Forks::Super::Job> for information about the methods and attributes of
these objects.

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

=item $Forks::Super::MAX_PROC

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

=item $Forks::Super::ON_BUSY = 'block' | 'fail' | 'queue'

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

=item $Forks::Super::CHILD_FORK_OK = -1 | 0 | +1

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

=item $Forks::Super::DEBUG, Forks::Super::DEBUG

To see the internal workings of the C<Forks> module, set
C<$Forks::Super::DEBUG> to a non-zero value. Information messages
will be written to the C<Forks::Super::DEBUG> filehandle. By default
C<Forks::Super::DEBUG> is aliased to C<STDERR>, but it may be reset
by the module user at any time.

=item %Forks::Super::CHILD_STDIN

=item %Forks::Super::CHILD_STDOUT

=item %Forks::Super::CHILD_STDERR

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

=item @Forks::Super::ALL_JOBS, %Forks::Super::ALL_JOBS

List of all C<Forks::Super::Job> objects that were created from C<fork()> calls,
including deferred and failed jobs. Both process IDs and job IDs
(for jobs that were deferred at one time) can be used to look
up Job objects in the %Forks::Super::ALL_JOBS table.

=back

=head1 DIAGNOSTICS

=over 4

=item C<fork() not allowed in child process ...>

=item C<Forks::Super::fork() call not allowed in child process ...>

When the package variable C<$Forks::Super::CHILD_FORK_OK> is zero, this package does not
allow the C<fork()> method to be called from a child process. 
Set C<$Forks::Super::CHILD_FORK_OK> to change this behavior.

=item C<quick timeout>

A job was configured with a timeout/expiration time such that the 
deadline for the job occurred before the job was even launched. The job
was killed immediately after it was spawned.

=item C<Job start/Job dependency E<lt>nnnE<gt> for job E<lt>nnnE<gt> is invalid. Ignoring.>

A process id or job id that was specified as a C<depend_on> or C<depend_start>
option did not correspond to a known job.

=item C<Job E<lt>nnnE<gt> reaped before parent initialization.>

A child process finished quickly and was reaped by the parent process SIGCHLD
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

=back

=head1 INCOMPATIBILITIES

If a C<fork> call ever results in a task being deferred,
then this module will install a C<SIGUSR1> handler as
well, and become incompatible with modules that require
their own C<SIGUSR1> handler.

Some features use the C<alarm> function and custom
C<SIGALRM> handlers in the child processes. Using other
modules that employ this functionality may cause
undefined behavior. Systems and versions that do not
implement the C<alarm> function (like MSWin32 prior to
Perl v5.7) will not be able to use these features.

=head1 DEPENDENCIES

There are no hard module dependencies in this module
on anything that is not distributed with core Perl.
This module is capable of making use of other modules,
if available:

    Time::HiRes

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
improved with version 5.6, and the problems caused by
such interruptions are much more tractable than they
used to be.

The system implementation of fork'ing and wait'ing varies
from platform to platform. It is possible that this module
or certain features will not work as advertised. Please
report any problems you encounter to E<lt>mob@cpan.orgE<gt>
and I'll see what I can do about it.

=head1 AUTHOR

Marty O'Brien, E<lt>mob@cpan.orgE<gt>

=head1 LICENSE AND COPYRIGHT

Copyright (c) 2009, Marty O'Brien.

This library is free software; you can redistribute it and/or modify
it under the same terms as Perl itself, either Perl version 5.8.8 or,
at your option, any later version of Perl 5 you may have available.

=cut


TODO in future releases:

support 

Possible TODOs:

         wait     timeout
         waitpid  timeout

		wait calls that block for only a limited time
         
         fork { stdin => \@STDIN }

		pass standard input to the child in a list at fork time.
                This seems more satisfactory for a  cmd  style fork that
                possibly can't wait for the parent to write to 
                Forks::Super::CHILD_STDIN{$pid}.

         fork { stdout => \@output, stderr => \@error }

                when the child process completes, collect its stdout and stderr
                output into the specified arrays. This will conserve filehandles
                in the parent.

         fork { input_fh => [ 'X', 'Y', 'Z' ], output_fh => [ 'STDOUT', 'A' ] }

		open input and output filehandles in the child with the given names,
		accessible in the parent at something like $Forks::Super::filehandles{$pid}{X}

         incorporate CPU load into system business calc (see Parallel::ForkControl)

         fork { callback => \&method }

                subroutine to call in the parent process when the child finishes

         facilities to suspend jobs when the system gets to busy
         and to resume them when the system gets less busy.
         I bet this will be hard to do with Win32.

         fork { debug => $boolean }

                override $Forks::Super::DEBUG for this job

         Forks::Super::Win32 as Win32 implementation of as much of this module
         as I can manage.

         Currently USR1 is used to signal the program to analyze the queue.
         Make the signal configurable.
