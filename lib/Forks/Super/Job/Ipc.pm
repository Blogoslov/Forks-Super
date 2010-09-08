#
# Forks::Super::Job::Ipc -- manage temporary files, sockets, pipes
#   that facilitate communication between
#   parent and child processes
# implementation of
#     fork { child_fh => ... }
#     fork { stdin =>   $input | \$input | \@input }
#     fork { stdout => \$output }
#     fork { stderr => \$error }
#
#

package Forks::Super::Job::Ipc;
use Forks::Super::Config;
use Forks::Super::Debug qw(:all);
use Forks::Super::Util qw(IS_WIN32 is_socket);
use Symbol qw(gensym);
use IO::Handle;
use File::Path;
use Time::HiRes;
use Carp;
use Exporter;
use base 'Exporter';
use strict;
use warnings;

our @EXPORT = qw(close_fh);
our $VERSION = $Forks::Super::Util::VERSION;

our (%FILENO, %SIG_OLD, $FH_COUNT, $FH_DIR_DEDICATED, @FH_FILES, %FH_FILES);
our ($SIGNALS_TRAPPED, $_CLEANUP, $_SIGNAL_TRAPPED_SO_SUPPRESS_INFO) = (0,0,0);
our $MAIN_PID = $$;
our $__OPEN_FH = 0; # for debugging, monitoring filehandle usage. Not ready.
our $__MAX_OPEN_FH = do {
  no warnings 'once';
  $Forks::Super::SysInfo::MAX_OPEN_FH;
};



# use $Forks::Super::FH_DIR instead of package scoped var --
# make it easy for Forks::Super user to manually set this var.




# open a filehandle with (a little) protection
# against "Too many open filehandles" error
sub _safeopen (*$$;$) {
  my ($fh, $mode, $expr, $robust) = @_;
  my ($open2, $open3);
  if ($mode =~ /&/) {
    my $fileno = CORE::fileno($expr);
    $open2 = $mode . $fileno;
  } else {
    ($open2, $open3) = ($mode, $expr);
  }

  my $result;
  if (!defined $fh) {
    $fh = gensym();
  }
  for (my $try = 1; $try <= 10; $try++) {

    if ($try == 10) {
      carp "Failed to open $mode $expr after 10 tries. Giving up.\n";
      #$open3 ||= '';
      #Carp::cluck "Failed to open [$mode $expr] [$open2 $open3] ",
      #	  "after 10 tries. Giving up. $!\n";
      return 0;
    }

    if (defined $open3) {
      $result = open ($fh, $open2, $open3);
      $_[0] = $fh;
    } else {
      $result = open ($fh, $open2);
      $_[0] = $fh;
    }

    if ($result) {
      $__OPEN_FH++;

      # dereferenced file handles are just symbol tables, and we
      # can store arbitrary data in them [so long as they are
      # not assigned to the symbol tables for *main or *Forks::Super::xxx ]
      # -- there are a lot of ways we can make good use of this data.

      my ($pkg,$file,$line) = caller;
      $$fh->{opened} = Time::HiRes::gettimeofday();
      $$fh->{caller} = "$pkg;$file:$line";
      $$fh->{is_regular} = 1;
      $$fh->{is_socket} = 0;
      $$fh->{is_pipe} = 0;
      $$fh->{mode} = $mode;
      $$fh->{glob} = "" . *$fh;
      my $fileno = $$fh->{fileno} = CORE::fileno($_[0]);
      $FILENO{$_[0]} = $fileno;
      if ($mode =~ />/) {
	$_[0]->autoflush(1);
      }

      #       if $mode =~ /&/ and the underlying handle is a socket
      #       or pipe, then shouldn't this handle also be a socket?
      if ($mode =~ /&/) {

	$$fh->{dup_glob} = "" . *$expr;
	$$fh->{dup} = $$expr;
	$$expr->{duped_by} .= " " . *$fh;
	$$fh->{is_regular} = $$expr->{is_regular};
	$$fh->{is_socket} = $$expr->{is_socket};
	$$fh->{is_pipe} = $$expr->{is_pipe};
      }

      last;
    }

    if ($! =~ /too many open filehandles/i) {
      carp "$! while opening $mode $expr. ",
	"[openfh=$__OPEN_FH/$__MAX_OPEN_FH] Retrying ...\n";
      Forks::Super::pause(0.1 * $try);
    } elsif ($robust && $! =~ /no such file or directory/i) {
      if ($DEBUG || (ref $robust eq 'Forks::Super::Job' && $robust->{debug})) {
	debug("$! while opening $mode $expr in $$. Retrying ...");
      }
      Forks::Super::Util::pause(0.1 * $try);
    } else {
      carp_once [$!], "$! while opening $mode $expr in $$ ",
	"[openfh=$__OPEN_FH/$__MAX_OPEN_FH]. Retrying ...\n";
    }
  }
  return $result;
}

sub Forks::Super::Job::_preconfig_fh {
  my $job = shift;
  
  my $config = {};
  if (defined $job->{child_fh}) {
    my $fh_spec = $job->{child_fh};
    if (ref $fh_spec eq 'ARRAY') {
      $fh_spec = join q/:/, @$fh_spec;
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
    }

    if (!$Forks::Super::Config::CONFIG{'filehandles'}
	&& $fh_spec !~ /pipe/i) {
      $fh_spec .= ",socket";

    }

    if (&IS_WIN32) {
      if (!$ENV{WIN32_PIPE_OK}) {
	$fh_spec =~ s/pipe/socket/i;
      }

      if ($] < 5.007) {
	if ($fh_spec =~ s/socke?t?//i + $fh_spec =~ s/pipe//i) {
	  carp_once "Forks::Super::_preconfig_fh: ",
	    "socket/pipe not allowed on Win32 v<5.7\n";
	}
      }
    }

    if (($job->{style} ne 'cmd' && $job->{style} ne 'exec') 
	|| !&IS_WIN32) {

      # sockets,pipes not supported for cmd/exec style forks.
      # we could support cmd-style with IPC::Open3-like framework ...
      if ($fh_spec =~ /sock/i) {
	$config->{sockets} = 1;
      } elsif ($fh_spec =~ /pipe/i) {
	$config->{pipes} = 1;
      }
    }
  }
  if (defined $job->{stdin}) {
    $config->{in} = 1;
    if (ref $job->{stdin} eq 'ARRAY') {
      $config->{stdin} = join'', @{$job->{stdin}};
    } elsif (ref $job->{stdin} eq 'SCALAR') {
      $config->{stdin} = ${$job->{stdin}};
    } else {
      $config->{stdin} = $job->{stdin};
    }
  }

  if (defined $job->{stdout}) {
    if (ref $job->{stdout} ne 'SCALAR') {
      carp "Forks::Super::_preconfig_fh: ",
	"'stdout' option must be a SCALAR ref\n";
    } else {
      $config->{stdout} = $job->{stdout};
      $config->{out} = 1;
      $job->{'_callback_collect'} = \&Forks::Super::Job::Ipc::collect_output;
    }
  }
  if (defined $job->{stderr}) {
    if (ref $job->{stderr} ne 'SCALAR') {
      carp "Forks::Super::_preconfig_fh: ",
	"'stderr' option must be a SCALAR ref\n";
    } else {
      $config->{stderr} = $job->{stderr};
      $config->{err} = 1;
      $job->{'_callback_collect'} = \&Forks::Super::Job::Ipc::collect_output;
    }
  }
  
  # choose file names -- if sockets or pipes are used and successfully set up,
  # the files will never actually be created.
  if ($config->{in}) {
    $config->{f_in} = _choose_fh_filename('', purpose => 'STDIN',
					  job => $job);
    debug("Using $config->{f_in} as shared file for child STDIN")
      if $job->{debug} && $config->{f_in};
    if ($config->{stdin}) {
      if (_safeopen my $fh, '>', $config->{f_in}) {
	print $fh $config->{stdin};
	_close($fh);
      } else {
	carp "Forks::Super::Job::_preconfig_fh: ",
	  "scalar standard input not available in child: $!\n";
      }
    }
  }
  
  if ($config->{out}) {
    $config->{f_out} = _choose_fh_filename('', purpose => 'STDOUT', 
					   job => $job);
    debug("Using $config->{f_out} as shared file for child STDOUT")
      if $job->{debug} && $config->{f_out};
  }
  if ($config->{err}) {
    $config->{f_err} = _choose_fh_filename('',
					   purpose => 'STDERR', job => $job);
    debug("Using $config->{f_err} as shared file for child STDERR")
      if $job->{debug} && $config->{f_err};
  }
  
  if ($config->{sockets}) {
    _preconfig_fh_sockets($job,$config);
  }
  if ($config->{pipes}) {
    _preconfig_fh_pipes($job,$config);
  }
  
  if (0 < scalar keys %$config) {
    if (!Forks::Super::Config::CONFIG('filehandles')) {
      #warn "Forks::Super::Job: interprocess filehandles not available!\n";
      #return;  # filehandle feature not available
    }
    $job->{fh_config} = $config;
  }
  return;
}

# read output from children into scalar reference variables in the parent
sub collect_output {
  my ($job,$pid) = @_;
  my $fh_config = $job->{fh_config};
  if (!defined $fh_config) {
    return;
  }
  my $stdout = $fh_config->{stdout};
  if (defined $stdout) {
    if ($fh_config->{f_out} 
	&& $fh_config->{f_out} ne '__socket__'
        && $fh_config->{f_out} ne '__pipe__') {
      local $/ = undef;
      if (_safeopen my $fh, '<', $fh_config->{f_out}) {
	($$stdout) = <$fh>;
	_close($fh);
      } else {
	carp "Forks::Super::Job::Ipc::collect_output(): ",
	  "Failed to retrieve stdout from child $pid: $!\n";
      }
    } else {
      $$stdout = join'', Forks::Super::read_stdout($pid);
    }
    if ($job->{debug}) {
      debug("Job $pid loaded ", length($$stdout),
	    " bytes from stdout into $stdout");
    }
  }
  my $stderr = $fh_config->{stderr};
  if (defined $stderr) {
    if ($fh_config->{f_err} 
	&& $fh_config->{f_err} ne '__socket__'
        && $fh_config->{f_err} ne '__pipe__') {
      local $/ = undef;
      if (_safeopen(my $fh, '<', $fh_config->{f_err})) {
	$$stderr = '' . <$fh>;
	_close($fh);
      } else {
	carp "Forks::Super::Job::Ipc::collect_output(): ",
	  "Failed to retrieve stderr from child $pid: $!\n";
      }
    } else {
      $$stderr = join('', Forks::Super::read_stderr($pid));
    }
    if ($job->{debug}) {
      debug("Job $pid loaded ", length($$stderr),
	    " bytes from stderr into $stderr");
    }
  }
  $job->close_fh('all');
  return;
}

sub _preconfig_fh_sockets {
  my ($job,$config) = @_;
  if (!Forks::Super::Config::CONFIG('Socket')) {
    carp "Forks::Super::Job::_preconfig_fh_sockets(): ",
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
      debug("created socket pair/$config->{csock}:",
	    CORE::fileno($config->{csock}),
	    "/$config->{psock}:",CORE::fileno($config->{psock}));
    }
    if ($config->{out} && $config->{err} && !$config->{join}) {
      ($config->{csock2},$config->{psock2}) = _create_socket_pair();
      if (not defined $config->{csock2}) {
	delete $config->{sockets};
	return;
      } elsif ($job->{debug}) {
	debug("created socket pair/$config->{csock2}:",
	      CORE::fileno($config->{csock2}),
	      "/$config->{psock2}:",CORE::fileno($config->{psock2}));
      }
    }
  }
}

sub _preconfig_fh_pipes {
  my ($job,$config) = @_;
  if (!Forks::Super::Config::CONFIG('pipe')) {
    carp "Forks::Super::Job::_preconfig_fh_pipes(): ",
      "Pipes unavailable. ",
	"Will try to use regular filehandles for child ipc.\n";
    delete $config->{pipes};
    return;
  }

  if ($config->{in}) {
    ($config->{p_in}, $config->{p_to_in}) = _create_pipe_pair();
  }
  if ($config->{out}) {
    ($config->{p_out},$config->{p_to_out}) = _create_pipe_pair();
  }
  if ($config->{err} && !$config->{join}) {
    ($config->{p_err},$config->{p_to_err}) = _create_pipe_pair();
  }

  if ($job->{debug}) {
    debug("created pipe pairs for $job");
  }
}

sub _create_socket_pair {
  if (!Forks::Super::Config::CONFIG('Socket')) {
    croak "Forks::Super::Job::_create_socket_pair(): no Socket\n";
  }
  my ($s_child, $s_parent);
  local $! = undef;
  if (Forks::Super::Config::CONFIG('IO::Socket')) {
    ($s_child, $s_parent) = IO::Socket->socketpair(Socket::AF_UNIX(),
			      Socket::SOCK_STREAM(), Socket::PF_UNSPEC());
    if (!(defined $s_child && defined $s_parent)) {
      warn "Forks::Super::_create_socket_pair: ",
	"IO::Socket->socketpair(AF_UNIX) failed. Trying AF_INET\n";
      ($s_child, $s_parent) = IO::Socket->socketpair(Socket::AF_INET(),
				Socket::SOCK_STREAM(), Socket::PF_UNSPEC());
    }
  } else {
    my $z = socketpair($s_child, $s_parent, Socket::AF_UNIX(),
		       Socket::SOCK_STREAM(), Socket::PF_UNSPEC());
    if ($z == 0) {
      warn "Forks::Super::_create_socket_pair: ",
	"socketpair(AF_UNIX) failed. Trying AF_INET\n";
      $z = socketpair($s_child, $s_parent, Socket::AF_INET(),
		      Socket::SOCK_STREAM(), Socket::PF_UNSPEC());
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
  $s_child->blocking(!!&IS_WIN32);
  $s_parent->blocking(!!&IS_WIN32);
  $$s_child->{fileno} = $FILENO{$s_child} = CORE::fileno($s_child);
  $$s_parent->{fileno} = $FILENO{$s_parent} = CORE::fileno($s_parent);

  $$s_child->{glob}       = "" . *$s_child;
  $$s_parent->{glob}      = "" . *$s_parent;
  $$s_child->{is_socket}  = $$s_parent->{is_socket}  = 1;
  $$s_child->{is_pipe}    = $$s_parent->{is_pipe}    = 0;
  $$s_child->{is_regular} = $$s_parent->{is_regular} = 0;
  $$s_child->{is_child}   = $$s_parent->{is_parent}  = 1;
  $$s_child->{is_parent}  = $$s_parent->{is_child}   = 0;
  $$s_child->{opened}     = $$s_parent->{opened}     = Time::HiRes::gettimeofday();
  my ($pkg,$file,$line)   = caller(2);
  $$s_child->{caller}     = $$s_parent->{caller}     = "$pkg;$file:$line";

  return ($s_child,$s_parent);
}

sub ___fileno {
  my $fh = shift;
  return $FILENO{$fh};
}

sub _create_pipe_pair {
  if (!Forks::Super::Config::CONFIG('pipe')) {
    croak "Forks::Super::Job::_create_pipe_pair(): no pipe\n";
  }

  my ($p_read, $p_write) = (gensym(), gensym());
  local $! = undef;

  pipe $p_read, $p_write or croak "Forks::Super::Job: create pipe failed $!\n";
  $p_write->autoflush(1);

  $$p_read->{fileno} = $FILENO{$p_read} = CORE::fileno($p_read);
  $$p_write->{fileno} = $FILENO{$p_write} = CORE::fileno($p_write);

  $$p_read->{is_pipe} = $$p_write->{is_pipe} = 1;
  $$p_read->{is_socket} = $$p_write->{is_socket} = 0;
  $$p_read->{is_regular} = $$p_write->{is_regular} = 0;
  $$p_read->{is_read} = $$p_write->{is_write} = 1;
  $$p_read->{is_write} = $$p_write->{is_read} = 1;
  $$p_read->{opened} = $$p_write->{opened} = Time::HiRes::gettimeofday();

  my ($pkg,$file,$line) = caller(2);
  $$p_read->{caller} = $$p_write->{caller} = "$pkg;$file:$line";

  return ($p_read, $p_write);
}

sub _choose_fh_filename {
  my ($suffix, @debug_info) = @_;
  my $basename = ".fh_";
  if (!Forks::Super::Config::CONFIG('filehandles')) {
    return;
  }
  if (not defined $Forks::Super::FH_DIR) {
    _identify_shared_fh_dir();
  }

  $FH_COUNT++;
  my $file = sprintf ("%s/%s%03d", $Forks::Super::FH_DIR,
		      $basename, $FH_COUNT);
  if (defined $suffix) {
    $file .= $suffix;
  }

  if (&IS_WIN32) {
    $file =~ s!/!\\!g;
  }

  push @FH_FILES, $file;
  $FH_FILES{$file} = [ @debug_info ];

  if (!$FH_DIR_DEDICATED && -f $file) {
    carp "Forks::Super::Job::_choose_fh_filename: ",
      "IPC file $file already exists!\n";
    debug("$file already exists ...") if $DEBUG;
  }
  return $file;
}

#
# choose a writeable but discrete location for files to
# handle interprocess communication.
#
sub _identify_shared_fh_dir {
  return if defined $Forks::Super::FH_DIR;
  #Forks::Super::Config::unconfig('filehandles');

  # what are the good candidates ???
  # Any:       .
  # Windows:   C:/Temp C:/Windows/Temp %HOME%
  # Other:     /tmp $HOME /var/tmp
  my @search_dirs = ($ENV{'HOME'}, $ENV{'PWD'});
  if (&IS_WIN32) {
    push @search_dirs, 'C:/Temp', $ENV{'TEMP'}, 'C:/Windows/Temp',
      'C:/Winnt/Temp', 'D:/Windows/Temp', 'D:/Winnt/Temp',
      'E:/Windows/Temp', 'E:/Winnt/Temp', '.';
  } else {
    unshift @search_dirs, '.';
    push @search_dirs, '/tmp', '/var/tmp';
  }
  if ($ENV{FH_DIR}) {
    unshift @search_dirs, $ENV{FH_DIR};
  }

  foreach my $dir (@search_dirs) {

    next unless defined $dir && $dir =~ /\S/;
    debug("Considering $dir as shared filehandle dir ...") if $DEBUG;
    next unless -d $dir;
    next unless -r $dir && -w $dir && -x $dir;
    if (Forks::Super::Config::configif('filehandles')) {
      _set_fh_dir($dir);
      debug("Selected $Forks::Super::FH_DIR as shared filehandle dir ...")
	if $DEBUG;
    }
    last;
  }
  return;
}

sub _set_fh_dir {
  my ($dir) = @_;
  $Forks::Super::FH_DIR = $dir;
  $FH_DIR_DEDICATED = 0;

  my $dirname = ".fhfork$$";

  if (-e "$dir/$dirname") {
    my $n = 0;
    while (-e "$dir/$dirname-$n") {
      $n++;
    }
    if (mkdir "$dir/$dirname-$n"
	and -r "$dir/$dirname-$n"
	and -w "$dir/$dirname-$n"
	and -x "$dir/$dirname-$n") {
      $Forks::Super::FH_DIR = "$dir/$dirname-$n";
      $FH_DIR_DEDICATED = 1;
      debug("dedicated fh dir: $Forks::Super::FH_DIR") if $DEBUG;

      my $readme = "$Forks::Super::FH_DIR/README.txt";
      open my $readme_fh, '>', $readme;
      my $localtime = scalar localtime;
      print $readme_fh <<"____;";
This directory was created by process $$ at $localtime
running $0 @ARGV. 

It should be/have been cleaned up when the process completes/completed.
If that didn't happen for some reason, it is safe to delete
this directory.

____;
      close $readme_fh; # ';
      push @FH_FILES, $readme;
      $FH_FILES{$readme} = [ purpose => 'README' ];

    } elsif ($DEBUG) {
      debug("failed to make dedicated fh dir: $dir/$dirname-$n");
    }
  } else {
    if (mkdir "$dir/$dirname"
	and -r "$dir/$dirname"
	and -w "$dir/$dirname"
	and -x "$dir/$dirname") {
      $Forks::Super::FH_DIR = "$dir/$dirname";
      $FH_DIR_DEDICATED = 1;
      my $readme = "$Forks::Super::FH_DIR/README.txt";
      open my $readme_fh, '>', $readme;
      my $localtime = scalar localtime;
      print $readme_fh <<"____;";
This directory was created by process $$ at $localtime
running $0 @ARGV. 

It should be/have been cleaned up when the process completes/completed.
If that didn't happen for some reason, it is safe to delete
this directory.

____;
      close $readme_fh; # ';
      push @FH_FILES, $readme;
      $FH_FILES{$readme} = [ purpose => 'README' ];

      if ($DEBUG) {
	debug("dedicated fh dir: $Forks::Super::FH_DIR");
      }
    } elsif ($DEBUG) {
      debug("Failed to make dedicated fh dir: $dir/$dirname");
    }
  }
  return;
}

sub _cleanup {
  no warnings 'once';
  if (defined $Forks::Super::FH_DIR
      && 0 >= ($Forks::Super::DONT_CLEANUP || 0)) {
    if (&IS_WIN32) {
      END_cleanup_MSWin32();
    } else {
      END_cleanup();
    }
  }
}

#
# if cleanup is desired, trap signals that would normally terminate
# the program.
#
sub _trap_signals {
  return if $SIGNALS_TRAPPED++;
  # return if &IS_WIN32;
  foreach my $sig (qw(INT TERM HUP QUIT PIPE ALRM)) {

    # don't trap if it looks like a signal handler is already installed.
    next if defined $SIG{$sig};
    next if !exists $SIG{$sig};

    $SIG_OLD{$sig} = $SIG{$sig};
    $SIG{$sig} = \&Forks::Super::Job::Ipc::__cleanup__;
  }
}

sub __cleanup__ {
  my $SIG = shift;
  if ($DEBUG) {
    debug("trapping: $SIG");
  }
  _untrap_signals();
  if ($DEBUG) {
    print STDERR "$$ received $SIG -- cleaning up\n";
  } else {
    $_SIGNAL_TRAPPED_SO_SUPPRESS_INFO = 1;
  }
  if (&IS_WIN32) {
    END_cleanup_MSWin32();
  }
  exit 1;
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

  if ($$ != ($Forks::Super::MAIN_PID || $MAIN_PID)) {
    return;
  }
  return if $_CLEANUP++;
  if ($INC{'Devel/Trace.pm'}) {
    no warnings 'once';
    $Devel::Trace::TRACE = 0;
  }

  foreach my $job (@Forks::Super::ALL_JOBS) {
    $job->close_fh('all');
  }
  foreach my $fh (values %Forks::Super::CHILD_STDIN,
		  values %Forks::Super::CHILD_STDOUT,
		  values %Forks::Super::CHILD_STDERR) {
    _close($fh);
    # $__OPEN_FH -= close $fh;
  }

  # daemonize is there is anything to clean up
  my @unused_files = grep { ! -e $_ } keys %FH_FILES;
  delete $FH_FILES{$_} for @unused_files;

  if (0 == scalar keys %FH_FILES) {
    if (!defined $FH_DIR_DEDICATED
	|| ! -d $Forks::Super::FH_DIR
	|| rmdir $Forks::Super::FH_DIR) {
      return;
    }
  }

  # daemonize
  return if CORE::fork();
  exit 0 if CORE::fork();
  $0 = "cleanup:$0";
  sleep 3;

  # removing all the files we created during IPC
  # doesn't always go smoothly. We'll give a
  # 3/4-assed effort to remove the files but
  # nothing more heroic than that.

  my %G = ();
  foreach my $ipc_file (keys %FH_FILES) {
    if (! -e $ipc_file) {
      $G{$ipc_file} = delete $FH_FILES{$ipc_file};
    } else {
      local $! = undef;
      if ($DEBUG) {
	print STDERR "Deleting $ipc_file ... ";
      }
      my $z = unlink $ipc_file;
      if ($z && ! -e $ipc_file) {
	print STDERR "Delete $ipc_file ok\n" if $DEBUG;
	$G{$ipc_file} = delete $FH_FILES{$ipc_file};
      } else {
	print STDERR "Delete $ipc_file not ok: $!\n" if $DEBUG;
	warn "Forks::Super::END_cleanup: ",
	  "error disposing of ipc file $ipc_file: $z/$!\n";
      }
    }
  }

  if (0 == scalar keys %FH_FILES && defined $FH_DIR_DEDICATED) {

    my $zz = rmdir($Forks::Super::FH_DIR) || 0;
    if ($zz) {
      return;
    }


    sleep 2;
    exit 0 if CORE::fork();

    # long sleep here for maximum portability.
    sleep 10;
    my $z = rmdir($Forks::Super::FH_DIR) || 0;
    if (!$z) {
      unlink glob("$Forks::Super::FH_DIR/*");
      sleep 5;
      $z = rmdir($Forks::Super::FH_DIR) || 0;
    }
    if (!$z
	&& -d $Forks::Super::FH_DIR
	&& 0 < glob("$Forks::Super::FH_DIR/.nfs*")) {

      # Observed these files on Linux running from NSF mounted filesystem
      # .nfsXXX files are usually temporary (~30s) but hard to kill
      for (my $i=0; $i<10; $i++) {
	sleep 5;
	if (glob("$Forks::Super::FH_DIR/.nfs*") <= 0) {
	  if ($DEBUG) {
	    print STDERR "Temporary .nfsXXX files are gone.\n";
	  }
	  last;
	}
      }
      $z = rmdir($Forks::Super::FH_DIR) || 0;
    }

    if (!$z && -d $Forks::Super::FH_DIR) {
      warn "Forks::Super::END_cleanup: ",
	"rmdir $Forks::Super::FH_DIR failed. $!\n";

      if(1){
	opendir(_Z, $Forks::Super::FH_DIR);
	my @g = grep { !/^\.nfs/ } readdir(_Z);
        closedir _Z;
        foreach my $g (@g) {
	  my $gg = "$Forks::Super::FH_DIR/$g";
	  if (defined $G{$gg} && $G{$gg}) {
	    my %gg = @{$G{$gg}};
	    unless ($_SIGNAL_TRAPPED_SO_SUPPRESS_INFO) {
	      print STDERR "\t$gg ==> ";
	      foreach my $key (keys %gg) {
		if ($key eq 'job') {
		  print STDERR "\t\t",$gg{$key}->toString(),"\n";
		} else {
		  print STDERR "\t\t$key => ", $gg{$key}, "\n";
		}
	      }
	    }
	  }
	}
	if (@g) { print STDERR join "\t", @g, "\n"; }
      }
    }
  }
  return;
}

sub END_cleanup_MSWin32 {
# $Devel::Trace::TRACE = 0;
  return if $$ != ($Forks::Super::MAIN_PID || $MAIN_PID);
  return if $_CLEANUP++;
  $0 = "cleanup:$0";

  $_->close_fh('all') foreach @Forks::Super::ALL_JOBS;
  #$__OPEN_FH -= close $_ for (values %Forks::Super::CHILD_STDIN, 
  _close($_) for (values %Forks::Super::CHILD_STDIN, 
		  values %Forks::Super::CHILD_STDOUT,
		  values %Forks::Super::CHILD_STDERR);

  my @G = grep { -e $_ } keys %FH_FILES;
  FILE_TRY: for my $try (1 .. 3) {
      if (@G == 0) {
	last FILE_TRY;
      }
      foreach my $G (@G) {
	local $! = undef;
	if (!unlink $G) {
	  undef $!;
	  sleep 1;
	  $G =~ s!/!\\!;
	  my $c1 = system("CMD /C DEL /Q \"$G\" 2> NUL");
	}
      }
    } continue {
      # sleep 1;
      @G = grep { -e $_ } keys %FH_FILES;
    }

  if (@G != 0) {
    warn "Forks::Super: failed to clean up ", scalar @G, " temp files.\n";
    return;
  }

  if (defined $FH_DIR_DEDICATED) {
    local $! = undef;
    my $z = rmdir $Forks::Super::FH_DIR;
    if (!$z) {
      warn "Forks::Super: failed to remove dedicated temp file directory ",
	"$Forks::Super::FH_DIR: $!\n";
    }
  }
  return;
}

sub _config_fh_parent_stdin {
  my $job = shift;
  my $fh_config = $job->{fh_config};
  return if defined $fh_config->{stdin}; # took care of this in preconfig_fh

  if ($fh_config->{in} 
      && $fh_config->{sockets} 
      && !defined $fh_config->{stdin}) {

    $fh_config->{s_in} = $fh_config->{psock};
    $job->{child_stdin} 
      = $Forks::Super::CHILD_STDIN{$job->{real_pid}}
      = $Forks::Super::CHILD_STDIN{$job->{pid}} 
      = $fh_config->{s_in};
    $fh_config->{f_in} = '__socket__';
    debug("Setting up socket to $job->{pid} stdin $fh_config->{s_in} ",
	  CORE::fileno($fh_config->{s_in})) if $job->{debug};

  } elsif ($fh_config->{in}
	   && $fh_config->{pipes}
	   && !defined $fh_config->{stdin}) {

    $job->{child_stdin} 
      = $Forks::Super::CHILD_STDIN{$job->{real_pid}}
      = $Forks::Super::CHILD_STDIN{$job->{pid}} 
      = $fh_config->{p_to_in};
    $fh_config->{f_in} = '__pipe__';
    debug("Setting up pipe to $job->{pid} stdin $fh_config->{p_to_in} ",
	  CORE::fileno($fh_config->{p_to_in})) if $job->{debug};

  } elsif ($fh_config->{in} and defined $fh_config->{stdin}) {
    debug("Passing STDIN from parent to child in scalar variable")
      if $job->{debug};
  } elsif ($fh_config->{in} and defined $fh_config->{f_in}) {
    my $fh = gensym();
    local $! = 0;
    if (_safeopen $fh, '>', $fh_config->{f_in}) {

      debug("Opening $fh_config->{f_in} in parent as child STDIN")
	if $job->{debug};
      $job->{child_stdin} = $Forks::Super::CHILD_STDIN{$job->{real_pid}} = $fh;
      $Forks::Super::CHILD_STDIN{$job->{pid}} = $fh;
      $fh->autoflush(1);

      debug("Setting up link to $job->{pid} stdin in $fh_config->{f_in}")
	if $job->{debug};

    } else {
      warn "Forks::Super::Job::config_fh_parent(): ",
	"could not open filehandle to write child STDIN (to ",
	  $fh_config->{f_in}, "): $!\n";
    }
  }
  if (defined $job->{child_stdin}) {
    my $fh = $job->{child_stdin};
    $$fh->{job} = $job;
    $$fh->{purpose} = 'parent write to child stdin';
  }
  return;
}

sub _config_fh_parent_stdout {
  my $job = shift;
  my $fh_config = $job->{fh_config};

  if ($fh_config->{out} && $fh_config->{sockets}) {

    $fh_config->{s_out} = $fh_config->{psock};
    $job->{child_stdout} = $Forks::Super::CHILD_STDOUT{$job->{real_pid}}
      = $Forks::Super::CHILD_STDOUT{$job->{pid}} = $fh_config->{s_out};
    $fh_config->{f_out} = '__socket__';
    debug("Setting up socket to $job->{pid} stdout $fh_config->{s_out} ",
	  CORE::fileno($fh_config->{s_out})) if $job->{debug};

  } elsif ($fh_config->{out} && $fh_config->{pipes}) {

    $job->{child_stdout}
      = $Forks::Super::CHILD_STDOUT{$job->{real_pid}}
      = $Forks::Super::CHILD_STDOUT{$job->{pid}}
      = $fh_config->{p_out};
    $fh_config->{f_out} = '__pipe__';
    debug("Setting up pipe to $job->{pid} stdout $fh_config->{p_out} ",
	  CORE::fileno($fh_config->{p_out})) if $job->{debug};

  } elsif ($fh_config->{out} and defined $fh_config->{f_out}) {
    # creation of $fh_config->{f_out} may be delayed.
    # don't panic if we can't open it right away.
    my $fh;
    debug("Opening ", $fh_config->{f_out}, " in parent as child STDOUT")
      if $job->{debug};
    local $! = 0;

    if (_safeopen($fh, '<', $fh_config->{f_out}, $job||1)) {

      debug("Opened child STDOUT in parent") if $job->{debug};
      $job->{child_stdout} = $Forks::Super::CHILD_STDOUT{$job->{real_pid}}
	= $Forks::Super::CHILD_STDOUT{$job->{pid}} = $fh;

      debug("Setting up link to $job->{pid} stdout in $fh_config->{f_out}")
	if $job->{debug};

    } else {
      my $_msg = sprintf "%d: %s Failed to open f_out=%s: %s\n",
	$$, Forks::Super::Util::Ctime(), $fh_config->{f_out}, $!;

      if ($DEBUG) {
	Carp::cluck "Forks::Super::Job::config_fh_parent(): \n    ",
	    "could not open filehandle to read child STDOUT from ",
	      $fh_config->{f_out}, "\n     for ",
		$job->toString(),
		  ": $!\n$_msg\n";
      } else {
	warn "Forks::Super::Job::config_fh_parent(): ",
	  "could not open filehandle to read child STDOUT (from ",
	  $fh_config->{f_out}, "): $!\n";
      }
    }
  }
  if (defined $job->{child_stdout}) {
    my $fh = $job->{child_stdout};
    $$fh->{job} = $job;
    $$fh->{purpose} = 'parent read from child stdout';
  }
  if ($fh_config->{join}) {
    delete $fh_config->{err};
    $job->{child_stderr} 
      = $Forks::Super::CHILD_STDERR{$job->{real_pid}}
      = $Forks::Super::CHILD_STDERR{$job->{pid}} 
      = $job->{child_stdout};
    $fh_config->{f_err} = $fh_config->{f_out};
    debug("Joining stderr to stdout for $job->{pid}") if $job->{debug};
  }
  return;
}

sub _config_fh_parent_stderr {
  my $job = shift;
  my $fh_config = $job->{fh_config};

  if ($fh_config->{err} && $fh_config->{sockets}) {

    $fh_config->{s_err} = defined $fh_config->{psock2}
      ? $fh_config->{psock2} : $fh_config->{psock};

    $job->{child_stderr}
      = $Forks::Super::CHILD_STDERR{$job->{real_pid}}
      = $Forks::Super::CHILD_STDERR{$job->{pid}}
      = $fh_config->{s_err};
    $fh_config->{f_err} = '__socket__';
    debug("Setting up socket to $job->{pid} stderr $fh_config->{s_err} ",
	  CORE::fileno($fh_config->{s_err})) if $job->{debug};

  } elsif ($fh_config->{err} && $fh_config->{pipes}) {

    $job->{child_stderr}
      = $Forks::Super::CHILD_STDERR{$job->{real_pid}}
      = $Forks::Super::CHILD_STDERR{$job->{pid}}
      = $fh_config->{p_err};
    $fh_config->{f_err} = '__pipe__';
    debug("Setting up pipe to $job->{pid} stderr ",
	  CORE::fileno($fh_config->{p_err})) if $job->{debug};

  } elsif ($fh_config->{err} and defined $fh_config->{f_err}) {

    delete $fh_config->{join};
    my $fh;
    debug("Opening ", $fh_config->{f_err}, " in parent as child STDERR")
      if $job->{debug};
    local $! = 0;
    if (_safeopen($fh, '<', $fh_config->{f_err}, $job||1)) {

      debug("Opened child STDERR in parent") if $job->{debug};
      $job->{child_stderr} 
	  = $Forks::Super::CHILD_STDERR{$job->{real_pid}}
	  = $Forks::Super::CHILD_STDERR{$job->{pid}} 
	  = $fh;

      debug("Setting up link to $job->{pid} stderr in $fh_config->{f_err}")
	if $job->{debug};

    } else {
      my $_msg = sprintf "%d: %s Failed to open f_err=%s: %s\n",
	  $$, Forks::Super::Util::Ctime(), $fh_config->{f_err}, $!;
      if ($DEBUG) {
	Carp::cluck "Forks::Super::Job::config_fh_parent(): \n    ",
	    "could not open filehandle to read child STDERR from ",
	      $fh_config->{f_err}, "\n    for ",
		$job->toString(),
		  ": $!\n";
      } else {
	warn "Forks::Super::Job::config_fh_parent(): ",
	  "could not open filehandle to read child STDERR (from ",
	    $fh_config->{f_err}, "): $!\n";
      }
    }
  }
  if (defined $job->{child_stderr}) {
    my $fh = $job->{child_stderr};
    $$fh->{job} = $job;
    $$fh->{purpose} = 'parent read from child stderr';
  }
  return;
}

#
# open filehandles to the STDIN, STDOUT, STDERR processes of the job
# to be used by the parent. Presumably the child process is opening
# the same files at about the same time.
#
sub Forks::Super::Job::_config_fh_parent {
  my $job = shift;
  return if not defined $job->{fh_config};

  _trap_signals();
  my $fh_config = $job->{fh_config};

  # set up stdin first.
  _config_fh_parent_stdin($job);
  _config_fh_parent_stdout($job);
  _config_fh_parent_stderr($job);
  if ($job->{fh_config}->{sockets}) {

    # is it helpful or necessary for the parent to close the
    # "child" sockets? Yes, apparently, for MSWin32.

    my $s1 = $job->{fh_config}->{csock};
    my $s2 = $job->{fh_config}->{csock2};
    _close($s1,1);
    _close($s2,1);

  }
  if ($job->{fh_config}->{pipes}) {
    foreach my $pipeattr (qw(p_in p_to_out p_to_err)) {
      if (defined $job->{fh_config}->{$pipeattr}) {
	_close( $job->{fh_config}->{$pipeattr} );
	# $__OPEN_FH -= close $job->{fh_config}->{$pipeattr};
	delete $job->{fh_config}->{$pipeattr};
      }
    }
  }

  return;
}

sub _config_fh_child_stdin {
  my $job = shift;
  local $! = undef;
  my $fh_config = $job->{fh_config};
  unless ($fh_config->{in}) {
    close STDIN;
    return;
  }

  if (defined $fh_config->{stdin}) {

    my $fh;
    if (!(_safeopen($fh, '<', $fh_config->{f_in}))) {
      carp "Forks::Super::Job::Ipc::_config_fh_child_stdin(): ",
	"Error initializing scalar STDIN in child $$: $!\n";
    } elsif (!(_safeopen(*STDIN, '<&', $fh))) {
      carp "Forks::Super::Job::Ipc::_config_fh_child_stdin(): ",
	"Error initializing scalar STDIN in child $$: $!\n";
    }

  } elsif ($fh_config->{sockets} && !defined $fh_config->{stdin}) {
    close STDIN;
    if (!(_safeopen( *STDIN, '<&', $fh_config->{csock}))) {
      warn "Forks::Super::Job::_config_fh_child_stdin(): ",
	"could not attach child STDIN to input sockethandle: $!\n";
    }
    debug("Opening socket ",*STDIN,"/",CORE::fileno(STDIN), " in child STDIN")
      if $job->{debug};
  } elsif ($fh_config->{pipes} && !defined $fh_config->{stdin}) {
    close STDIN;
    if (!(_safeopen(*STDIN, '<&', $fh_config->{p_in}))) {
      warn "Forks::Super::Job::_config_fh_child_stdin(): ",
	"could not attach child STDIN to input pipe: $!\n";
    }
    debug("Opening pipe ",*STDIN,"/",CORE::fileno(STDIN), " in child STDIN")
      if $job->{debug};
  } elsif ($fh_config->{f_in}) {
    # creation of $fh_config->{f_in} may be delayed.
    # don't panic if we can't open it right away.
    my $fh;
    debug("Opening ", $fh_config->{f_in}, " in child STDIN") if $job->{debug};

    if (_safeopen($fh, '<', $fh_config->{f_in}, $job||1)) {

      close STDIN if &IS_WIN32;
      _safeopen(*STDIN, '<&', $fh)
	  or warn "Forks::Super::Job::config_fh_child(): ",
	    "could not attach child STDIN to input filehandle: $!\n";
      debug("Reopened STDIN in child") if $job->{debug};
      ${*STDIN}->{dup} = $fh_config->{f_in};

      # XXX - Unfortunately, if redirecting STDIN fails (and it might
      # if the parent is late in opening up the file), we have probably
      # already redirected STDERR and we won't get to see the above
      # warning message
    } else {
      warn "Forks::Super::Job::config_fh_child(): ",
	"could not open filehandle to provide child STDIN: $!\n";
    }
  } else {
    carp "Forks::Super::Job::Ipc: failed to configure child STDIN: ",
      "fh_config = ", join(' ', %{$job->{fh_config}});
  }
  return;
}

sub _config_fh_child_stdout {
  my $job = shift;
  local $! = undef;
  my $fh_config = $job->{fh_config};
  return unless $fh_config->{out};

  if ($fh_config->{sockets}) {
    close STDOUT;
    _safeopen(*STDOUT, '>&', $fh_config->{csock})
      or warn "Forks::Super::Job::_config_fh_child_stdout(): ",
	"could not attach child STDOUT to output sockethandle: $!\n";

    debug("Opening ",*STDOUT,"/",CORE::fileno(STDOUT)," in child STDOUT")
      if $job->{debug};

    if ($fh_config->{join}) {
      delete $fh_config->{err};
      close STDERR;
      _safeopen(*STDERR, ">&", $fh_config->{csock})
        or warn "Forks::Super::Job::_config_fh_child_stdout(): ",
          "could not join child STDERR to STDOUT sockethandle: $!\n";

      debug("Joining ",*STDERR,"/",CORE::fileno(STDERR),
	    " STDERR to child STDOUT") if $job->{debug};
    }

  } elsif ($fh_config->{pipes}) {
    close STDOUT;
    _safeopen(*STDOUT, ">&", $fh_config->{p_to_out})
      or warn "Forks::Super::Job::_config_fh_child_stdout(): ",
	"could not attach child STDOUT to output pipe: $!\n";
    select STDOUT;
    debug("Opening ",*STDOUT,"/",CORE::fileno(STDOUT)," in child STDOUT")
      if $job->{debug};

    if ($fh_config->{join}) {
      delete $fh_config->{err};
      close STDERR;
      _safeopen(*STDERR, ">&", $fh_config->{p_to_out})
	or warn "Forks::Super::Job::_config_fh_child_stdout(): ",
	  "could not join child STDERR to STDOUT sockethandle: $!\n";
    }

  } elsif ($fh_config->{f_out}) {
    my $fh;
    debug("Opening up $fh_config->{f_out} for output in the child   $$")
      if $job->{debug};
    if (_safeopen($fh,'>',$fh_config->{f_out})) {
      close STDOUT if &IS_WIN32;
      if (_safeopen(*STDOUT, ">&", $fh)) {
	if ($fh_config->{join}) {
	  delete $fh_config->{err};
	  close STDERR if &IS_WIN32;
	  _safeopen(*STDERR, '>&', $fh)
	    or warn "Forks::Super::Job::config_fh_child(): ",
	      "could not attach STDERR to child output filehandle: $!\n";
	}
      } else {
	warn "Forks::Super::Job::config_fh_child(): ",
	  "could not attach STDOUT to child output filehandle: $!\n";
      }
    } else {
      warn "Forks::Super::Job::config_fh_child(): ",
	"could not open filehandle to provide child STDOUT: $!\n";
    }
  } else {
    carp "Forks::Super::Job::Ipc: failed to configure child STDOUT: ",
      "fh_config = ", join(' ', %{$job->{fh_config}});
  }
  return;
}

sub _config_fh_child_stderr {
  my $job = shift;
  my $fh_config = $job->{fh_config};
  return unless $fh_config->{err};

  if ($fh_config->{sockets}) {
    close STDERR;
    my $fileno_arg = $fh_config->{out} ? 'csock2' : 'csock';
    if (_safeopen(*STDERR, ">&", $fh_config->{$fileno_arg})) {
      debug("Opening ",*STDERR,"/",CORE::fileno(STDERR),
	    " in child STDERR") if $job->{debug};
    } else {
      warn "Forks::Super::Job::_config_fh_child_stderr(): ",
	"could not attach STDERR to child error sockethandle: $!\n";
    }
  } elsif ($fh_config->{pipes}) {
    close STDERR;
    if (_safeopen(*STDERR, ">&", $fh_config->{p_to_err})) {
      debug("Opening ",*STDERR,"/",CORE::fileno(STDERR),
	    " in child STDERR") if $job->{debug};
    } else {
      warn "Forks::Super::Job::_config_fh_child_stderr(): ",
	"could not attach STDERR to child error pipe: $!\n";
    }
  } elsif ($fh_config->{f_err}) {
    my $fh;
    debug("Opening $fh_config->{f_err} as child STDERR")
      if $job->{debug};
    if (_safeopen($fh, '>', $fh_config->{f_err})) {
      close STDERR if &IS_WIN32;
      _safeopen(*STDERR, '>&', $fh)
	or warn "Forks::Super::Job::_config_fh_child_stderr(): ",
	  "could not attach STDERR to child error filehandle: $!\n";
    } else {
      warn "Forks::Super::Job::_config_fh_child_stderr(): ",
	"could not open filehandle to provide child STDERR: $!\n";
    }
  } else {
    carp "Forks::Super::Job::Ipc: failed to configure child STDERR: ",
      "fh_config = ", join(' ', %{$job->{fh_config}});
  }
  return;
}

#
# open handles to the files that the parent process will
# have access to, and assign them to the local STDIN, STDOUT,
# and STDERR filehandles.
#
sub Forks::Super::Job::_config_fh_child {
  my $job = shift;
  return if not defined $job->{fh_config};
  if ($job->{style} eq 'cmd' || $job->{style} eq 'exec') {
    if (&IS_WIN32) {
      return _config_cmd_fh_child($job);
    }
  }

  _config_fh_child_stdout($job);
  _config_fh_child_stderr($job);
  _config_fh_child_stdin($job);
  if ($job->{fh_config} && $job->{fh_config}->{sockets}) {
    my $s1 = $job->{fh_config}->{psock};
    my $s2 = $job->{fh_config}->{psock2};
    if (defined $s1) {
      _close($s1);
      # $__OPEN_FH -= close $s1;
    }
    if (defined $s2) {
      _close($s2);
      # $__OPEN_FH -= close $s2;
    }
  }
  if ($job->{fh_config} && $job->{fh_config}->{pipes}) {
    foreach my $pipeattr (qw(p_to_in p_out p_err)) {
      if (defined $job->{fh_config}->{$pipeattr}) {
	_close( $job->{fh_config}->{$pipeattr} );
	# $__OPEN_FH -= close $job->{fh_config}->{$pipeattr};
      }
    }
  }
  return;
}

sub _collapse_command {
  my @cmd = @_;
  if (@cmd <= 1) {
    return @cmd;
  }
  my @new_cmd = ();
  foreach my $cmd (@cmd) {
    if ($cmd !~ /[\s\'\"\[\]\;\(\)\<\>\t\|\?\&]/x) {
      push @new_cmd, $cmd;
    } elsif ($cmd !~ /\"/) {
      push @new_cmd, "\"$cmd\"";
    } elsif ($cmd !~ /\'/ && !&IS_WIN32) {
      push @new_cmd, "'$cmd'";
    } else {
      my $cmd2 = $cmd;
      $cmd2 =~ s/([\s\'\"\\\[\]\;\(\)\<\>\t\|\?\&])/\\$1/gx;
      push @new_cmd, "\"$cmd2\"";
    }
  }
  @cmd = ();
  push @cmd, (join " ", @new_cmd);
  return @cmd;
}

# MSWin32 has trouble using the open '>&' and open '<&' syntax.
sub _config_cmd_fh_child {
  my $job = shift;
  my $fh_config = $job->{fh_config};
  my $cmd_or_exec = $job->{exec} ? 'exec' : 'cmd';
  my @cmd = @{$job->{$cmd_or_exec}};
  if (@cmd > 1) {
    @cmd = _collapse_command(@cmd);
  }

  # XXX - not idiot proof. FH dir could have a metacharacter.
  if ($fh_config->{out} && $fh_config->{f_out}) {
    $cmd[0] .= " >\"$fh_config->{f_out}\"";
    if ($fh_config->{join}) {
      $cmd[0] .= " 2>&1";
    }
  }
  if ($fh_config->{err} && $fh_config->{f_err} && !$fh_config->{join}) {
    $cmd[0] .= " 2>\"$fh_config->{f_err}\"";
  }
  if (!$fh_config->{in}) {
    close STDIN;
  } elsif ($fh_config->{in} && $fh_config->{f_in}) {

    # standard input must be specified before the first pipe char,
    # if any (XXX - How do you distinguish pipes that are
    # for shell piping, and pipes that are part of some command
    # or command line argument? The shell can do it, obviously,
    # but there is probably lots and lots of code to do it right.
    # And probably regex != doing it right).

    $cmd[0] =~ s/(\s?\||$)/ <"$fh_config->{f_in}" $1/;

    if (0 && $fh_config->{stdin}) {  # should be done in preconfig_fh
      my $fhx;
      if (_safeopen($fhx, '>', $fh_config->{f_in})) {
	print $fhx $fh_config->{stdin};
	_close($fhx);
	if ($job->{debug}) {
	  debug("Wrote ", length($fh_config->{stdin}), " bytes to ",
		$fh_config->{f_in}, " as standard input to new job");
	}
      } else {
	carp "Forks::Super::Job::Ipc::config_cmd_fh_child: ",
	  "Can't initialize child stdin ...\n";
      }
    }

    # external command must not launch until the input file has been created

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

sub _close {
  my $handle = shift;
  no warnings;
  return 0 if !defined $handle;
  return 0 if $$handle->{closed};
  if (!defined $$handle->{opened}) {
    if (1 || $DEBUG) {
      Carp::cluck "Forks::Super::Job::Ipc::_close ",
	  "called on unrecognized filehandle $handle\n";
    }
  }

  if (is_socket($handle)) {
    return _close_socket($handle,0) + _close_socket($handle,1);
    #my $z = close $handle;
    #$__OPEN_FH-- if $z;
    #return $z;
  }
  $$handle->{closed} ||= Time::HiRes::gettimeofday();
  $$handle->{elapsed} ||= $$handle->{closed} - $$handle->{opened};
  my $z = close $handle;
  if ($z) {
    $__OPEN_FH--;
    if ($DEBUG) {
      debug("$$ closing IPC handle $$handle->{glob}");
    }
  }
  return $z;
}

# close down one-half of a socket. If the other half is already closed,
# then call close on the socket.
sub _close_socket {
  my ($handle, $is_write) = @_;
  no warnings;
  return 0 if !defined $handle;
  return 0 if $$handle->{closed};
  return 0 if $$handle->{shutdown} >= 3;

  $is_write++;    #  0 => 1, 1 => 2, 2 => 3
  if (0 == ($$handle->{shutdown} & $is_write)) {
    my $z = $$handle->{shutdown} |= $is_write;
    if ($$handle->{shutdown} >= 3) {
      $$handle->{closed} ||= Time::HiRes::gettimeofday();
      $$handle->{elapsed} ||= $$handle->{closed} - $$handle->{opened};
      $z = close $handle;
      $__OPEN_FH--;
      if ($DEBUG) {
	debug("$$ Closing IPC socket $$handle->{glob}");
      }
    }
    return $z;
  }
}

sub _close_fh_stdin {
  my $job = shift;
  if (defined $job->{child_stdin} && !defined $job->{child_stdin_closed}) {
    if (is_socket($job->{child_stdin})) {
      if (_close_socket($job->{child_stdin}, 1)) {
	$job->{child_stdin_closed} = 1;
	debug("closed child stdin for $job->{pid}") if $job->{debug};
      }
    } elsif (_close($job->{child_stdin})) {
      $job->{child_stdin_closed} = 1;
      debug("closed child stdin for $job->{pid}") if $job->{debug};
    }
  }
  foreach my $p ($job->{real_pid}, $job->{pid}, $job->{name}) {
    next if !defined $p;
    if (defined $Forks::Super::CHILD_STDIN{$p}) {
      delete $Forks::Super::CHILD_STDIN{$p}
    }
  }
}

sub _close_fh_stdout {
  my $job = shift;
  if (defined $job->{child_stdout} && !defined $job->{child_stdout_closed}) {
    if (is_socket($job->{child_stdout})) {
      if (_close_socket($job->{child_stdout}, 0)) {
	$job->{child_stdout_closed} = 1;
	debug("closed child stdout for $job->{pid}") if $job->{debug};
      }
    } elsif (_close($job->{child_stdout})) {
      $job->{child_stdout_closed} = 1;
      debug("closed child stdout for $job->{pid}") if $job->{debug};
    }
    if ($job->{fh_config}->{join}) {
      $job->{child_stderr_closed} = $job->{child_stdout_closed};
      debug("closed joined child stderr for $job->{pid}") if $job->{debug};
    }
  }
  foreach my $p ($job->{real_pid}, $job->{pid}, $job->{name}) {
    next if !defined $p;
    if (defined $Forks::Super::CHILD_STDOUT{$p}) {
      delete $Forks::Super::CHILD_STDOUT{$p};
      if ($job->{fh_config}->{join} &&
	      defined $Forks::Super::CHILD_STDERR{$p}) {
	delete $Forks::Super::CHILD_STDERR{$p};
      }
    }
  }
}

sub _close_fh_stderr {
  my $job = shift;
  if (defined $job->{child_stderr} && !defined $job->{child_stderr_closed}) {
    if (is_socket($job->{child_stderr})) {
      if (_close_socket($job->{child_stderr}, 0)) {
	$job->{child_stderr_closed} = 1;
	debug("closed child stderr for $job->{pid}") if $job->{debug};
      }
    } elsif (_close($job->{child_stderr})) {
      $job->{child_stderr_closed} = 1;
      debug("closed child stderr for $job->{pid}") if $job->{debug};
    }
  }
  foreach my $p ($job->{real_pid}, $job->{pid}, $job->{name}) {
    next if !defined $p;
    if (defined $Forks::Super::CHILD_STDERR{$p}) {
      delete $Forks::Super::CHILD_STDERR{$p}
    }
  }
}

sub close_fh {
  my ($job,@modes) = @_;
  local $" = " ";
  my $modes = "@modes" || "all";
  $modes =~ s/all/stdin stdout stderr/i;

  _close_fh_stdin($job) if $modes =~ /stdin/i;
  _close_fh_stdout($job) if $modes =~ /stdout/i;
  _close_fh_stderr($job) if $modes =~ /stderr/i;
  return;
}

sub Forks::Super::Job::write_stdin {
  my ($job, @msg) = @_;
  Forks::Super::Job::_resolve($job);
  my $fh = $job->{child_stdin};
  if (defined $fh) {
    if ($job->{child_stdin_closed}) {
      carp "Forks::Super::Job::write_stdin: ",
	"write on closed stdin handle for job $job->{pid}\n";
    } else {
      local $!;
      my $z = print $fh @msg;
      if ($!) {
	carp "Forks::Super::Job::write_stdin: ",
	  "warning on write to job $job->{pid} stdin: $!\n";
      }
      return $z;
    }
  } else {
    carp "Forks::Super::Job::write_stdin: ",
      "stdin handle for job $job->{pid} was not configured\n";
  }
}

sub _read_socket {
  my ($sh, $job, $wantarray, %options) = @_;

  if (!defined $sh) {
    if (!defined($options{"warn"}) || $options{"warn"}) {
      carp "Forks::Super::_read_socket: ",
	"read on undefined handle for ",$job->toString(),"\n";
    }
    return;
  }

  # is socket is blocking, then we need to test whether
  # there is input to be read before we read on the socket

  my $blocking_desired = defined($options{"block"}) && $options{"block"} != 0;
  my $blocking_not_desired = defined($options{"block"}) && $options{"block"} == 0;

  while ($sh->blocking() || &IS_WIN32 || $blocking_desired) {
    my $fileno = fileno($sh);
    if (not defined $fileno) {
      $fileno = Forks::Super::Job::Ipc::fileno($sh);
      Carp::cluck "Cannot determine FILENO for socket handle $sh!";
    }

    my ($rin,$rout,$ein,$eout);
    my $timeout = $Forks::Super::SOCKET_READ_TIMEOUT || 1.0;

    $rin = '';
    vec($rin, $fileno, 1) = 1;
    $ein = $rin;

    # perldoc select: warns against mixing select4
    # (unbuffered input) with readline (buffered input).
    # Do I have to do my own buffering? That would be weak.
    # Or can we declare the socket as unbuffered when
    # we create it?

    local $! = undef;
    my ($nfound,$timeleft) = select $rout=$rin,undef,$eout=$ein, $timeout;
    if (!$nfound) {
      if ($DEBUG) {
	debug("no input found on $sh/$fileno");
      }
      return if !$blocking_desired;
    }
    if ($rin ne $rout) {
      if ($DEBUG) {
	debug("No input found on $sh/$fileno");
      }
      return if !$blocking_desired;
    }

    if ($nfound == -1) {
      warn "Forks::Super:_read_socket: ",
	"Error in select4(): $! $^E. \$eout=$eout; \$ein=$ein\n";
    }
    last if $nfound != 0;
    return if $blocking_not_desired;
  }
  return readline($sh);
}

sub _read_pipe {
  my ($sh, $job, $wantarray, %options) = @_;

  if (!defined $sh) {
    if (!defined($options{"warn"}) || $options{"warn"}) {
      carp "Forks::Super::_read_pipe: ",
	"read on undefined handle for ",$job->toString(),"\n";
    }
  }

  my $fileno = fileno($sh);
  if (not defined $fileno) {
    $fileno = Forks::Super::Job::Ipc::fileno($sh);
    Carp::cluck "Cannot determine FILENO for pipe $sh!";
  }

  my $blocking_desired = defined($options{"block"}) && $options{"block"} != 0;
  my $blocking_not_desired = defined($options{"block"}) && $options{"block"} == 0;

  # pipes are blocking by default.
  if ($blocking_desired) {
    if ($wantarray) {
      return readline($sh);
    } else {
      return scalar readline($sh);
    }
  } else {
    my ($rin,$rout,$ein,$eout);
    my $timeout = $Forks::Super::SOCKET_READ_TIMEOUT || 1.0;
    $rin = '';
    vec($rin, $fileno, 1) = 1;
    local $! = undef;
    my ($nfound, $timeleft) = select $rout=$rin, undef, undef, $timeout;

    if ($nfound == 0) {
      if ($DEBUG) {
	debug("no input found on $sh/$fileno");
      }
      return () if $wantarray;
      return;
    }
    if ($nfound < 0) {
      # warn "Forks::Super::_read_pipe: error in select4(): $! $^E\n";
      return () if $wantarray;
      return;
    }

    # perldoc select: warns against mixing select4
    # (unbuffered input) with readline (buffered input).
    # Do I have to do my own buffering? Don't look.

    if ($wantarray) {
      my $input = '';

      while ($nfound) {
	my $buffer = '';
	last if 0 == sysread $sh, $buffer, 1;
	$input .= $buffer;
	($nfound,$timeleft) = select $rout=$rin, undef, undef, 0.0;
      }

      my @return = ();
      while ($input =~ m!$/!) {  # XXX - what if $/ is "" or undef ?
	push @return, substr $input, 0, $+[0];
	substr($input, 0, $+[0]) = "";
      }
      return @return;
    } else {
      my $input = '';
      while ($nfound) {
	my $buffer = '';
	last unless sysread $sh, $buffer, 1;  # or $buffer = getc($sh) ??
	$input .= $buffer;
	last if length($/) > 0 && substr($input,-length($/)) eq $/;
	($nfound,$timeleft) = select $rout=$rin, undef, undef, 0.0;
      }
      return $input;
    }
  }
}

sub Forks::Super::Job::read_stdout {
  my ($job, %options) = @_;  # my ($job, @options) = @_;
  Forks::Super::Job::_resolve($job);
  return _readline($job->{child_stdout}, $job, wantarray, %options);
}

sub Forks::Super::Job::read_stderr {
  my ($job, %options) = @_;  # my ($job, @options) = @_;
  Forks::Super::Job::_resolve($job);
  return _readline($job->{child_stderr}, $job, wantarray, %options);
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
sub _readline {
  my ($fh,$job,$wantarray,%options) = @_;
  if (!defined $fh) {
    if ($job->{debug} && (!defined($options{"warn"}) || $options{"warn"})) {
      carp "Forks::Super::_readline(): ",
	"read on unconfigured handle for job $job->{pid}\n";
    }
    return;
  }
  if ($$fh->{closed}) {
    if (!defined($options{"warn"}) || $options{"warn"}) {
      carp_once "Forks::Super::_readline(): ",
	"read on closed handle for job $job->{pid}\n";
    }
    return;
  }

  if ($$fh->{is_socket}) {
    return _read_socket(@_);
  } elsif ($$fh->{is_pipe}) {
    return _read_pipe(@_);
  }

  # WARNING: blocking read on a filehandle can lead to deadlock
  my $blocking_desired = defined($options{"block"}) && $options{"block"} != 0;
  my $blocking_not_desired = defined($options{"block"}) && $options{"block"} == 0;

  local $! = undef;
  if ($wantarray) {
    my @lines;
    while (@lines == 0) {
      @lines = readline($fh);
      if (@lines > 0) {
	return @lines;
      }

      if ($job->is_complete && Time::HiRes::gettimeofday() - $job->{end} > 3) {
	if ($job->{debug}) {
	  debug("Forks::Super::_readline(): ",
		"job $job->{pid} is complete. Closing $fh");
	}
	if (defined($job->{child_stdout}) && $fh eq $job->{child_stdout}) {
	  $job->close_fh('stdout');
	}
	if (defined($job->{child_stderr}) && $fh eq $job->{child_stderr}) {
	  $job->close_fh('stderr');
	}
      } else {
	seek $fh, 0, 1;
	Forks::Super::pause();
      }
      if (!$blocking_desired) {
	return ();
      }
    }
    return @lines;
  } else {   # !$wantarray
    my $line;
    while (!defined $line) {
      $line = readline($fh);
      if (defined $line) {
	return $line;
      }

      if ($job->is_complete && Time::HiRes::gettimeofday() - $job->{end} > 3) {
	if ($job->{debug}) {
	  debug("Forks::Super::_readline(): ",
	      "job $job->{pid} is complete. Closing $fh");
	}
	if ($fh eq $job->{child_stdout}) {
	  $job->close_fh('stdout');
	}
	if ($fh eq $job->{child_stderr}) {
	  $job->close_fh('stderr');
	}
	return;
      } else {
	seek $fh, 0, 1;
	Forks::Super::pause();
      }
      if (!$blocking_desired) {
	return '';
      }
    }
  }
}



sub init_child {
  $FH_DIR_DEDICATED = 0;
  %FH_FILES = @FH_FILES = ();
  # untie $__OPEN_FH;
  %SIG_OLD = ();
  return;
}

sub deinit_child {
  if (@FH_FILES > 0) { 
    Carp::cluck("Child $$ had temp files! @FH_FILES\n");
    unlink @FH_FILES;
    @FH_FILES = ();
  }
}

1;
