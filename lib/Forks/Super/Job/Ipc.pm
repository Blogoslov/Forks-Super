package Forks::Super::Job::Ipc;
use Forks::Super::Config;
use Forks::Super::Debug qw(:all);
use Carp;
use Exporter;
use base 'Exporter';
use strict;
use warnings;

our @EXPORT = qw(preconfig_fh config_fh_parent 
		 config_fh_child config_cmd_fh_child);

our (%FILENO, %SIG_OLD, $FH_COUNT, $FH_DIR_DEDICATED, @FH_FILES);
our $SIGNALS_TRAPPED = 0;
our $MAIN_PID = $$;

# use $Forks::Super::FH_DIR instead of package scoped var --
# make it easy for Forks::Super user to manually set this var.

sub preconfig_fh {
  my $job = shift;

  my $config = {};
  if (defined $job->{child_fh}) {
    my $fh_spec = $job->{child_fh};
    if (ref $fh_spec eq "ARRAY") {
      $fh_spec = join ":", @$fh_spec;
    }
    if ($fh_spec =~ /all/i) {
      foreach my $attr (qw(in out err all)) {
	$config->{$attr} = 1;
      }
    } else {
      if ($fh_spec =~ /(?<!jo)in/i) {
	$config->{in} = 1;
      }
      if ($fh_spec =~ /out/i) {
	$config->{out} = 1;
      }
      if ($fh_spec =~ /err/i) {
	$config->{err} = 1;
      }
      if ($fh_spec =~ /join/i) {
	$config->{join} = 1;
	$config->{out} = 1;
	$config->{err} = 1;
      }
      if ($fh_spec =~ /sock/i) {
	$config->{sockets} = 1;
      }
    }
  }
  if (defined $job->{stdin}) {
    $config->{in} = 1;
    if (ref $job->{stdin} eq "ARRAY") {
      $config->{stdin} = join'', @{$job->{stdin}};
    } elsif (ref $job->{stdin} eq "SCALAR") {
      $config->{stdin} = ${$job->{stdin}};
    } else {
      $config->{stdin} = $job->{stdin};
    }
  }

  if (defined $job->{stdout}) {
    if (ref $job->{stdout} ne "SCALAR") {
      carp "Forks::Super::preconfig_fh: 'stdout' option must be a SCALAR ref\n";
    } else {
      $config->{stdout} = $job->{stdout};
      $config->{out} = 1;
      $job->{"_callback_collect"} = \&Forks::Super::Job::Ipc::collect_output;
    }
  }
  if (defined $job->{stderr}) {
    if (ref $job->{stderr} ne "SCALAR") {
      carp "Forks::Super::preconfig_fh: 'stderr' option must be a SCALAR ref\n";
    } else {
      $config->{stderr} = $job->{stderr};
      $config->{err} = 1;
      $job->{"_callback_collect"} = \&Forks::Super::Job::Ipc::collect_output;
    }
  }

  # choose file names -- if sockets are used and successfully set up,
  # the files will not be created.
  if ($config->{in}) {
    if (defined $config->{stdin} && $job->{style} ne "cmd" && $job->{style} ne "exec") {
      $config->{f_in} = '__scalar__';
    } else {
      $config->{f_in} = _choose_fh_filename();
      debug("Using $config->{f_in} as shared file for child STDIN") 
	if $job->{debug};
    }
  }
  if ($config->{out}) {
    $config->{f_out} = _choose_fh_filename();
    debug("Using $config->{f_out} as shared file for child STDOUT") 
      if $job->{debug};
  }
  if ($config->{err}) {
    $config->{f_err} = _choose_fh_filename();
    debug("Using $config->{f_err} as shared file for child STDERR") 
      if $job->{debug};
  }

  if ($config->{sockets}) {
    preconfig_fh_sockets($job,$config);
  }

  if (0 < scalar keys %$config) {
    if (!Forks::Super::Config::CONFIG("filehandles")) {
      warn "Forks::Super::Job: interprocess filehandles not available!\n";
      return;  # filehandle feature not available
    }
    $job->{fh_config} = $config;
  }
  return;
}

sub collect_output {
  my ($job,$pid) = @_;
  my $fh_config = $job->{fh_config};
  if (!defined $fh_config) {
    return;
  }
  my $stdout = $fh_config->{stdout};
  if (defined $stdout) {
    if ($fh_config->{f_out} && $fh_config->{f_out} ne "__socket__") {
      local $/ = undef;
      open(my $fh, "<", $fh_config->{f_out});
      ($$stdout) = <$fh>;
      close $fh;
    } else {
      $$stdout = join'', Forks::Super::read_stdout($pid); # XXX prefer <{$job->{child_stdout}}>
    }
    if ($job->{debug}) { 
      debug("Job $pid loaded ", length($$stdout), " bytes from stdout into $stdout");
    }
  }
  my $stderr = $fh_config->{stderr};
  if (defined $stderr) {
    if ($fh_config->{f_err} && $fh_config->{f_err} ne "__socket__") {
      local $/ = undef;
      open(my $fh, "<", $fh_config->{f_err});
      ($$stderr) = <$fh>;
      close $fh;
    } else {
      $$stderr = join'', Forks::Super::read_stderr($pid); # XXX prefer <{$job->{child_stderr}}>
    }
    if ($job->{debug}) { 
      debug("Job $pid loaded ", length($$stderr), " bytes from stderr into $stderr");
    }
  }
}

sub preconfig_fh_sockets {
  my ($job,$config) = @_;
  if (!Forks::Super::Config::CONFIG("Socket")) {
    carp "Forks::Super::Job::preconfig_fh_sockets(): ",
      "Socket unavailable. ",
	"Will try to use regular filehandles for child ipc.\n";
    delete $config->{sockets};
    return;
  }
  if ($config->{in} || $config->{out} || $config->{err}) {
    ($config->{csock},$config->{psock}) = _create_socket_pair();

    if (not defined $config->{csock}) {
      delete $config->{sockets};
      return;
    } elsif ($job->{debug}) {
      debug("created socket pair/$config->{csock}:", CORE::fileno($config->{csock}),
	    "/$config->{psock}:",CORE::fileno($config->{psock}));
    }
    if ($config->{out} && $config->{err} && !$config->{join}) {
      ($config->{csock2},$config->{psock2}) = _create_socket_pair();
      if (not defined $config->{csock2}) {
	delete $config->{sockets};
	return;
      } elsif ($job->{debug}) {
	debug("created socket pair/$config->{csock2}:", CORE::fileno($config->{csock2}),
	      "/$config->{psock2}:",CORE::fileno($config->{psock2}));
      }
    }
  }
}

sub _create_socket_pair {
  if (!Forks::Super::Config::CONFIG("Socket")) {
    croak "Forks::Super::Job::_create_socket_pair(): no Socket\n";
  }
  my ($s_child, $s_parent);
  local $!;
  undef $!;
  if (Forks::Super::Config::CONFIG("IO::Socket")) {
    ($s_child, $s_parent) = IO::Socket->socketpair(Socket::AF_UNIX(), Socket::SOCK_STREAM(), Socket::PF_UNSPEC());
    if (!(defined $s_child && defined $s_parent)) {
      warn "Forks::Super::_create_socket_pair: ",
	"IO::Socket->socketpair(AF_UNIX) failed. Trying AF_INET\n";
      ($s_child, $s_parent) = IO::Socket->socketpair(Socket::AF_INET(), Socket::SOCK_STREAM(), Socket::PF_UNSPEC());
    } 
  } else {
    my $z = socketpair($s_child, $s_parent, Socket::AF_UNIX(), Socket::SOCK_STREAM(), Socket::PF_UNSPEC());
    if ($z == 0) {
      warn "Forks::Super::_create_socket_pair: ",
	"socketpair(AF_UNIX) failed. Trying AF_INET\n";
      $z = socketpair($s_child, $s_parent, Socket::AF_INET(), Socket::SOCK_STREAM(), Socket::PF_UNSPEC());
      if ($z == 0) {
	undef $s_child;
	undef $s_parent;
      }
    }
  }
  if (!(defined $s_child && defined $s_parent)) {
    carp "Forks::Super::Job::_create_socket_pair(): ",
      "socketpair failed $! $^E!\n";
    return;
  }
  $s_child->autoflush(1);
  $s_parent->autoflush(1);
  $s_child->blocking(not $^O ne "MSWin32");
  $s_parent->blocking(not $^O ne "MSWin32");
  $FILENO{$s_child} = CORE::fileno($s_child);
  $FILENO{$s_parent} = CORE::fileno($s_parent);
  return ($s_child,$s_parent);
}

sub fileno {
  my $fh = shift;
  return $FILENO{$fh};
}


sub _choose_fh_filename {
  if (not defined $Forks::Super::FH_DIR) {
    _identify_shared_fh_dir();
  }
  if (Forks::Super::Config::CONFIG("filehandles")) {
    $FH_COUNT++;
    my $file = sprintf ("%s/.fh_%03d", $Forks::Super::FH_DIR, $FH_COUNT);

    if ($^O eq "MSWin32") {
      $file =~ s!/!\\!g;
    }

    push @FH_FILES, $file;

    if (!$FH_DIR_DEDICATED && -f $file) {
      carp "Forks::Super::Job::_choose_fh_filename: ",
	"IPC file $file already exists!\n";
      debug("$file already exists ...") if $DEBUG;
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
  Forks::Super::Config::unconfig("filehandles");

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
    debug("Considering $dir as shared filehandle dir ...") if $DEBUG;
    next unless -d $dir;
    next unless -r $dir && -w $dir && -x $dir;
    _set_fh_dir($dir);
    Forks::Super::Config::config("filehandles");
    debug("Selected $Forks::Super::FH_DIR as shared filehandle dir ...")
      if $DEBUG;
    last;
  }
  return;
}

sub _set_fh_dir {
  my ($dir) = @_;
  $Forks::Super::FH_DIR = $dir;
  $FH_DIR_DEDICATED = 0;

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
      $FH_DIR_DEDICATED = 1;
      debug("dedicated fh dir: $Forks::Super::FH_DIR") if $DEBUG;
    } elsif ($DEBUG) {
      debug("failed to make dedicated fh dir: $dir/.fhfork$$-$n");
    }
  } else {
    if (mkdir "$dir/.fhfork$$"
	and -r "$dir/.fhfork$$"
	and -w "$dir/.fhfork$$"
	and -x "$dir/.fhfork$$") {
      $Forks::Super::FH_DIR = "$dir/.fhfork$$";
      $FH_DIR_DEDICATED = 1;
      if ($DEBUG) {
	debug("dedicated fh dir: $Forks::Super::FH_DIR");
      }
    } elsif ($DEBUG) {
      debug("Failed to make dedicated fh dir: $dir/.fhfork$$");
    }
  }
  return;
}

END {
  if ($$ == ($Forks::Super::MAIN_PID || $MAIN_PID)) {
    $SIG{CHLD} = 'DEFAULT';
    if (defined $Forks::Super::FH_DIR && 0 >= ($Forks::Super::DONT_CLEANUP || 0)) {
      END_cleanup();
    }
    _untrap_signals();
  }
}

#
# if cleanup is desired, trap signals that would normally terminate
# the program.
#
sub _trap_signals {
  return if $SIGNALS_TRAPPED++;
  return if $^O eq "MSWin32";
  if ($DEBUG) {
    debug("trapping INT/TERM/HUP/QUIT signals");
  }
  foreach my $sig (qw(INT TERM HUP QUIT PIPE ALRM)) {
    $SIG_OLD{$sig} = $SIG{$sig};
    $SIG{$sig} = sub { 
      my $SIG=shift;
      if ($DEBUG) {
	debug("trapping: $SIG");
      }
      _untrap_signals();
      exit 1;
    }
  }
}

sub _untrap_signals {
  foreach my $sig (keys %SIG_OLD) {
    $SIG{$sig} = defined $SIG_OLD{$sig} ? $SIG_OLD{$sig} : 'DEFAULT';
  }
}

# if we have created temporary files for IPC, clean them up.
# clean them up even if the children are still alive -- these files
# are exclusively for IPC, and IPC isn't needed after the parent
# process is done.
sub END_cleanup {

  if ($$ == ($Forks::Super::MAIN_PID || $MAIN_PID)) {
    foreach my $fh (values %Forks::Super::CHILD_STDIN,
		    values %Forks::Super::CHILD_STDOUT,
		    values %Forks::Super::CHILD_STDERR) {
      close $fh;
    }
  }

  if (defined $FH_DIR_DEDICATED) {
    if ($DEBUG) {
      debug('END block: clean up files in ',
	    "dedicated IPC file dir $Forks::Super::FH_DIR");
    }

    my $clean_up_ok = File::Path::rmtree($Forks::Super::FH_DIR, 0, 1);
    if ($clean_up_ok <= 0) {
      warn "Forks::Super END:",
	"Clean up of $Forks::Super::FH_DIR may not have succeeded.\n";
      if ($Forks::Super::DONT_CLEANUP < 0) {
	return;
      }
    }

    # There are two unusual features of MSWin32 to note here:
    # 1. If child processes are still alive and still have the
    #    IPC files open, the parent process will be unable to delete them.
    # 2. The parent process will not be able to exit until the
    #    child processes have completed.

    if (-d $Forks::Super::FH_DIR) {
      if (0 == rmdir $Forks::Super::FH_DIR && 0 <= ($Forks::Super::DONT_CLEANUP || 0)) {
	if ($^O eq "MSWin32") {
	  warn "Forks::Super END: ",
	    "Must wait for all children to finish before ",
	    "removing $Forks::Super::FH_DIR\n";
	  1 while -1 != CORE::wait;
	  File::Path::rmtree($Forks::Super::FH_DIR, 0, 1);
	  rmdir $Forks::Super::FH_DIR;
	} else {
	  warn "Forks::Super END: ",
	    "Failed to remove $Forks::Super::FH_DIR/: $!\n";
	  _launch_bg_directory_cleaner($Forks::Super::FH_DIR);
	}
      }   # endif  rmdir
    }     # endif  -d $Forks::Super::FH_DIR
  } elsif (defined $Forks::Super::FH_DIR) {
    if (defined @FH_FILES) {
      foreach my $fh_file (@FH_FILES) {
	unless (unlink $fh_file) {
	  warn "Forks::Super END: possible issue removing temp file $fh_file: $!\n";
	}
      }
    }
  }
  return;
}

# XXX - move to Forks::Super::Util ?
sub _launch_bg_directory_cleaner {
  my $dir = shift;
  my $pid = CORE::fork();
  return if $pid;

  warn "Forks::Super: will try to clean up IPC directory $dir in background\n";

  for (my $i=0; $i<300; $i+=10) {
    sleep 10;
    my $clean_up_ok = File::Path::rmtree($dir, 0, 1);
    if ($clean_up_ok >= 0) {
      if (-d $dir) {
	if (rmdir $dir) {
	  print STDERR "Clean up of $dir complete.\n";
	  exit 0;
	}
      } else {
	print STDERR "Clean up of $dir complete.\n";
	exit 0;
      }
    } # else try again in 10 seconds for up to 5 minutes
  }
}

sub config_fh_parent_stdin {
  my $job = shift;
  my $fh_config = $job->{fh_config};

  if ($fh_config->{in} && $fh_config->{sockets} 
      && !defined $fh_config->{stdin}) {
    $fh_config->{s_in} = $fh_config->{psock};
    $job->{child_stdin} = $Forks::Super::CHILD_STDIN{$job->{real_pid}}
      = $Forks::Super::CHILD_STDIN{$job->{pid}} = $fh_config->{s_in};
    $fh_config->{f_in} = "__socket__";
    debug("Setting up socket to $job->{pid} stdin $fh_config->{s_in} ",
	  CORE::fileno($fh_config->{s_in})) if $job->{debug};
  } elsif ($fh_config->{in} and defined $fh_config->{stdin}) {
    debug("Passing STDIN from parent to child in scalar variable") if $job->{debug};
  } elsif ($fh_config->{in} and defined $fh_config->{f_in}) {
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
    debug("Setting up socket to $job->{pid} stdout $fh_config->{s_out} ",CORE::fileno($fh_config->{s_out})) if $job->{debug};

  } elsif ($fh_config->{out} and defined $fh_config->{f_out}) {
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
  if ($fh_config->{join}) {
    delete $fh_config->{err};
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
    debug("Setting up socket to $job->{pid} stderr $fh_config->{s_err} ",CORE::fileno($fh_config->{s_err})) if $job->{debug};

  } elsif ($fh_config->{err} and defined $fh_config->{f_err}) {
    delete $fh_config->{join};
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
  config_fh_parent_stdin($job);
  config_fh_parent_stdout($job);
  config_fh_parent_stderr($job);
  if ($job->{fh_config}->{sockets}) {
    close $job->{fh_config}->{csock};
    close $job->{fh_config}->{csock2} if defined $job->{fh_config}->{csock2};
  }

  return;
}

sub config_fh_child_stdin {
  my $job = shift;
  local $!;
  undef $!;
  my $fh_config = $job->{fh_config};

  if ($fh_config->{in} && $fh_config->{sockets}) {
    close STDIN;
    if (open(STDIN, '<&' . CORE::fileno($fh_config->{csock}))) {
      *STDIN->autoflush(1);
      $FILENO{*STDIN} = CORE::fileno(STDIN);
    } else {
      warn "Forks::Super::Job::config_fh_child_stdin(): ",
	"could not attach child STDIN to input sockethandle: $!\n";
    }
    debug("Opening ",*STDIN,"/",CORE::fileno(STDIN), " in child STDIN") if $job->{debug};
  } elsif ($fh_config->{in} && defined $fh_config->{stdin}) {
    close STDIN;
    if (!open STDIN, '<', \$fh_config->{stdin}) {
      carp "Forks::Super::Job::config_fh_child: ",
	"Could not open scalar value as child STDIN: $!\n";
    } else {
      debug("Opening scalar value as child STDIN") if $job->{debug};
    }
  } elsif ($fh_config->{in} && $fh_config->{f_in}) {
    # creation of $fh_config->{f_in} may be delayed. 
    # don't panic if we can't open it right away.
    my ($try, $fh);
    debug("Opening ", $fh_config->{f_in}, " in child STDIN") if $job->{debug};
    for ($try=1; $try<=11; $try++) {
      if ($try <= 10 && open($fh, '<', $fh_config->{f_in})) {
	close STDIN if $^O eq "MSWin32";
	open(STDIN, "<&" . CORE::fileno($fh) )
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
    if (open(STDOUT, '>&' . CORE::fileno($fh_config->{csock}))) {
      *STDOUT->autoflush(1);
      select STDOUT;
    } else {
      warn "Forks::Super::Job::config_fh_child_stdout(): ",
	"could not attach child STDOUT to output sockethandle: $!\n";
    }
    debug("Opening ",*STDOUT,"/",CORE::fileno(STDOUT)," in child STDOUT") if $job->{debug};

    if ($fh_config->{join}) {
      delete $fh_config->{err};
      close STDERR;
      if (open(STDERR, ">&" . CORE::fileno($fh_config->{csock}))) {
        *STDERR->autoflush(1);
	debug("Joining ",*STDERR,"/",CORE::fileno(STDERR)," STDERR to child STDOUT") if $job->{debug};
      } else {
        warn "Forks::Super::Job::config_fh_child_stdout(): ",
          "could not join child STDERR to STDOUT sockethandle: $!\n";
      }
    }

  } elsif ($fh_config->{out} && $fh_config->{f_out}) {
    my $fh;
    debug("Opening up $fh_config->{f_out} for output in the child   $$")
      if $job->{debug};
    if (open($fh, '>', $fh_config->{f_out})) {
      $fh->autoflush(1);
      close STDOUT if $^O eq "MSWin32";
      if (open(STDOUT, '>&' . CORE::fileno($fh))) {  # v5.6 compatibility
	*STDOUT->autoflush(1);

	if ($fh_config->{join}) {
	  delete $fh_config->{err};
	  close STDERR if $^O eq "MSWin32";
	  if (open(STDERR, '>&' . CORE::fileno($fh))) {
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
    if (open(STDERR, ">&" . CORE::fileno($fh_config->{$fh_config->{out} ? "csock2" : "csock"}))) {
      *STDERR->autoflush(1);
      debug("Opening ",*STDERR,"/",CORE::fileno(STDERR)," in child STDERR") if $job->{debug};      
    } else {
      warn "Forks::Super::Job::config_fh_child_stderr(): ",
	"could not attach STDERR to child error sockethandle: $!\n";
    }
  } elsif ($fh_config->{err} && $fh_config->{f_err}) {
    my $fh;
    debug("Opening $fh_config->{f_err} as child STDERR")
      if $job->{debug};
    if (open($fh, '>', $fh_config->{f_err})) {
      close STDERR if $^O eq "MSWin32";
      if (open(STDERR, '>&' . CORE::fileno($fh))) {
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

  config_fh_child_stdout($job);
  config_fh_child_stderr($job);
  config_fh_child_stdin($job);
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
  if ($fh_config->{out} && $fh_config->{f_out}) {
    if ($^O eq "MSWin32") {
      $cmd[0] .= " >\"$fh_config->{f_out}\"";
    } else {
      $cmd[0] .= " >'$fh_config->{f_out}'";
    }
    if ($fh_config->{join}) {
      $cmd[0] .= " 2>&1";
    }
  }
  if ($fh_config->{err} && $fh_config->{f_err}
      && !$fh_config->{join}) {
    if ($^O eq "MSWin32") {
      $cmd[0] .= " 2>\"$fh_config->{f_err}\"";
    } else {
      $cmd[0] .= " 2>'$fh_config->{f_err}'";
    }
  }
  if ($fh_config->{in} && $fh_config->{f_in}) {
    if ($^O eq "MSWin32") {
      $cmd[0] .= " <\"$fh_config->{f_in}\"";
    } else {
      $cmd[0] .= " <'$fh_config->{f_in}'";
    }
    if ($fh_config->{stdin}) {
      open my $fhx, ">", $fh_config->{f_in};
      print $fhx $fh_config->{stdin};
      close $fhx;
      if ($job->{debug}) {
	debug("Wrote ", length($fh_config->{stdin}), " bytes to ",
	      $fh_config->{f_in}, " as standard input to new job");
      }
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

sub init_child {
  undef $Forks::Super::FH_DIR;
  undef $FH_DIR_DEDICATED;
  %SIG_OLD = ();

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

1;
