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
use Symbol qw(gensym);
use IO::Handle;
use File::Path;
use Carp;
use Exporter;
use base 'Exporter';
use strict;
use warnings;

our @EXPORT = qw(close_fh preconfig_fh config_fh_parent
		 config_fh_child config_cmd_fh_child);
our $VERSION = $Forks::Super::Debug::VERSION;
our (%FILENO, %SIG_OLD, $FH_COUNT, $FH_DIR_DEDICATED, @FH_FILES, %FH_FILES);
our $SIGNALS_TRAPPED = 0;
our $MAIN_PID = $$;
our $__OPEN_FH = 0; # for debugging, monitoring filehandle usage. Not ready.
our $__MAX_OPEN_FH = do {
  no warnings 'once';
  $Forks::Super::SysInfo::MAX_OPEN_FH;
};

# use Tie::Trace;
# Tie::Trace::watch $__OPEN_FH;


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
  if (!defined $_[0]) {
    $_[0] = gensym();
  }
  for (my $try = 1; $try <= 10; $try++) {
    $result = defined $open3 
      ? open($_[0], $open2, $open3) : open($_[0], $open2);
    if ($result) {
      $__OPEN_FH++;
      $FILENO{$_[0]} = CORE::fileno($_[0]);
      if ($mode =~ />/) {
	$_[0]->autoflush(1);
      }
      last;
    }

    if ($try == 10) {
      carp "Failed to open $mode $expr after 10 tries. Giving up.\n";
      return 0;
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

sub preconfig_fh {
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

    if ($^O eq 'MSWin32') {
      if (!$ENV{WIN32_PIPE_OK}) {
	$fh_spec =~ s/pipe/socket/i;
      }
    }
    
    #   if ($job->{style} ne 'cmd' && $job->{style} ne 'exec') {
    if (($job->{style} ne 'cmd' && $job->{style} ne 'exec') 
	|| $^O ne 'MSWin32') {
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
      carp "Forks::Super::preconfig_fh: ",
	"'stdout' option must be a SCALAR ref\n";
    } else {
      $config->{stdout} = $job->{stdout};
      $config->{out} = 1;
      $job->{'_callback_collect'} = \&Forks::Super::Job::Ipc::collect_output;
    }
  }
  if (defined $job->{stderr}) {
    if (ref $job->{stderr} ne 'SCALAR') {
      carp "Forks::Super::preconfig_fh: ",
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
      if $job->{debug};
    if ($config->{stdin}) {
      if (_safeopen my $fh, '>', $config->{f_in}) {
	print $fh $config->{stdin};
	close $fh;
      } else {
	carp "Forks::Super::Job::preconfig_fh: ",
	  "scalar standard input not available in child: $!\n";
      }
    }
  }
  
  if ($config->{out}) {
    $config->{f_out} = _choose_fh_filename('', purpose => 'STDOUT', 
					   job => $job);
    debug("Using $config->{f_out} as shared file for child STDOUT")
      if $job->{debug};
  }
  if ($config->{err}) {
    $config->{f_err} = _choose_fh_filename('',
					   purpose => 'STDERR', job => $job);
    debug("Using $config->{f_err} as shared file for child STDERR")
      if $job->{debug};
  }
  
  if ($config->{sockets}) {
    preconfig_fh_sockets($job,$config);
  }
  if ($config->{pipes}) {
    preconfig_fh_pipes($job,$config);
  }
  
  if (0 < scalar keys %$config) {
    if (!Forks::Super::Config::CONFIG('filehandles')) {
      warn "Forks::Super::Job: interprocess filehandles not available!\n";
      return;  # filehandle feature not available
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
	close $fh;
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
	close $fh;
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
  $job->close_fh;
  return;
}

sub preconfig_fh_sockets {
  my ($job,$config) = @_;
  if (!Forks::Super::Config::CONFIG('Socket')) {
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

sub preconfig_fh_pipes {
  my ($job,$config) = @_;
  if (!Forks::Super::Config::CONFIG('pipe')) {
    carp "Forks::Super::Job::preconfig_fh_pipes(): ",
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
  $s_child->blocking(not $^O ne 'MSWin32');
  $s_parent->blocking(not $^O ne 'MSWin32');
  $FILENO{$s_child} = CORE::fileno($s_child);
  $FILENO{$s_parent} = CORE::fileno($s_parent);
  return ($s_child,$s_parent);
}

sub fileno {
  my $fh = shift;
  return $FILENO{$fh};
}

sub _create_pipe_pair {
  if (!Forks::Super::Config::CONFIG('pipe')) {
    croak "Forks::Super::Job::_create_pipe_pair(): no pipe\n";
  }

  my ($p_read, $p_write);
  local $! = undef;

  pipe $p_read, $p_write;
  $p_write->autoflush(1);

  $FILENO{$p_read} = CORE::fileno($p_read);
  $FILENO{$p_write} = CORE::fileno($p_write);
  return ($p_read, $p_write);
}

sub _choose_fh_filename {
  my ($suffix, @debug_info) = @_;
  my $basename = ".fh_";
  if (not defined $Forks::Super::FH_DIR) {
    _identify_shared_fh_dir();
  }
  if (Forks::Super::Config::CONFIG('filehandles')) {
    $FH_COUNT++;
    my $file = sprintf ("%s/%s%03d", $Forks::Super::FH_DIR,
			$basename, $FH_COUNT);
    if (defined $suffix) {
      $file .= $suffix;
    }

    if ($^O eq 'MSWin32') {
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
}

#
# choose a writeable but discrete location for files to
# handle interprocess communication.
#
sub _identify_shared_fh_dir {
  return if defined $Forks::Super::FH_DIR;
  Forks::Super::Config::unconfig('filehandles');

  # what are the good candidates ???
  # Any:       .
  # Windows:   C:/Temp C:/Windows/Temp %HOME%
  # Other:     /tmp $HOME /var/tmp
  my @search_dirs = ($ENV{'HOME'}, $ENV{'PWD'});
  if ($^O =~ /Win32/) {
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
    _set_fh_dir($dir);
    Forks::Super::Config::config('filehandles');
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

END {
  if ($$ == ($Forks::Super::MAIN_PID || $MAIN_PID)) { # FSJ::Ipc END {}
    no warnings 'once';
    if (defined $Forks::Super::FH_DIR
	&& 0 >= ($Forks::Super::DONT_CLEANUP || 0)) {
      if ($^O eq 'MSWin32') {
	END_cleanup_MSWin32();
      } else {
	END_cleanup();
      }
    }
  }
}

#
# if cleanup is desired, trap signals that would normally terminate
# the program.
#
sub _trap_signals {
  return if $SIGNALS_TRAPPED++;
  # return if $^O eq 'MSWin32';
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
  }
  if ($^O eq 'MSWin32') {
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
our $_CLEANUP = 0;
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
    $job->close_fh();
  }
  foreach my $fh (values %Forks::Super::CHILD_STDIN,
		  values %Forks::Super::CHILD_STDOUT,
		  values %Forks::Super::CHILD_STDERR) {
    $__OPEN_FH -= close $fh;
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
	&& 0 < scalar glob("$Forks::Super::FH_DIR/.nfs*")) {

      # Observed these files on Linux running from NSF mounted filesystem
      # .nfsXXX files are usually temporary (~30s) but hard to kill
      for (my $i=0; $i<10; $i++) {
	sleep 5;
	last if glob("$Forks::Super::FH_DIR/.nfs*") <= 0;
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
	    print STDERR "\t$gg ==> ";
	    my %gg = @{$G{$gg}};
	    foreach my $key (keys %gg) {
	      if ($key eq 'job') {
		print STDERR "\t\t",$gg{$key}->toString(),"\n";
	      } else {
		print STDERR "\t\t$key => ", $gg{$key}, "\n";
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

  $_->close_fh foreach @Forks::Super::ALL_JOBS;
  $__OPEN_FH -= close $_ for (values %Forks::Super::CHILD_STDIN, 
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

sub config_fh_parent_stdin {
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
  return;
}

sub config_fh_parent_stdout {
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

sub config_fh_parent_stderr {
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
    my $s1 = $job->{fh_config}->{csock};
    my $s2 = $job->{fh_config}->{csock2};
    if (defined $s1) {
      $__OPEN_FH -= close $s1;
    } 
    if (defined $s2) {
      $__OPEN_FH -= close $s2;
    }
  }
  if ($job->{fh_config}->{pipes}) {
    foreach my $pipeattr (qw(p_in p_to_out p_to_err)) {
      if (defined $job->{fh_config}->{$pipeattr}) {
	$__OPEN_FH -= close $job->{fh_config}->{$pipeattr};
	delete $job->{fh_config}->{$pipeattr};
      }
    }
  }

  return;
}

sub config_fh_child_stdin {
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
      carp "Forks::Super::Job::Ipc::config_fh_child_stdin(): ",
	"Error initializing scalar STDIN in child $$: $!\n";
    } elsif (!(_safeopen(*STDIN, '<&', $fh))) {
      carp "Forks::Super::Job::Ipc::config_fh_child_stdin(): ",
	"Error initializing scalar STDIN in child $$: $!\n";
    }

  } elsif ($fh_config->{sockets} && !defined $fh_config->{stdin}) {
    close STDIN;
    if (!(_safeopen( *STDIN, '<&', $fh_config->{csock}))) {
      warn "Forks::Super::Job::config_fh_child_stdin(): ",
	"could not attach child STDIN to input sockethandle: $!\n";
    }
    debug("Opening ",*STDIN,"/",CORE::fileno(STDIN), " in child STDIN")
      if $job->{debug};
  } elsif ($fh_config->{pipes} && !defined $fh_config->{stdin}) {
    close STDIN;
    if (!(_safeopen(*STDIN, '<&', $fh_config->{p_in}))) {
      warn "Forks::Super::Job::config_fh_child_stdin(): ",
	"could not attach child STDIN to input pipe: $!\n";
    }
    debug("Opening ",*STDIN,"/",CORE::fileno(STDIN), " in child STDIN")
      if $job->{debug};
  } elsif ($fh_config->{f_in}) {
    # creation of $fh_config->{f_in} may be delayed.
    # don't panic if we can't open it right away.
    my $fh;
    debug("Opening ", $fh_config->{f_in}, " in child STDIN") if $job->{debug};

    if (_safeopen($fh, '<', $fh_config->{f_in}, $job||1)) {

      close STDIN if $^O eq 'MSWin32';
      _safeopen(*STDIN, '<&', $fh)
	  or warn "Forks::Super::Job::config_fh_child(): ",
	    "could not attach child STDIN to input filehandle: $!\n";
      debug("Reopened STDIN in child") if $job->{debug};

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

sub config_fh_child_stdout {
  my $job = shift;
  local $! = undef;
  my $fh_config = $job->{fh_config};
  return unless $fh_config->{out};

  if ($fh_config->{sockets}) {
    close STDOUT;
    _safeopen(*STDOUT, '>&', $fh_config->{csock})
      or warn "Forks::Super::Job::config_fh_child_stdout(): ",
	"could not attach child STDOUT to output sockethandle: $!\n";

    debug("Opening ",*STDOUT,"/",CORE::fileno(STDOUT)," in child STDOUT")
      if $job->{debug};

    if ($fh_config->{join}) {
      delete $fh_config->{err};
      close STDERR;
      _safeopen(*STDERR, ">&", $fh_config->{csock})
        or warn "Forks::Super::Job::config_fh_child_stdout(): ",
          "could not join child STDERR to STDOUT sockethandle: $!\n";

      debug("Joining ",*STDERR,"/",CORE::fileno(STDERR),
	    " STDERR to child STDOUT") if $job->{debug};
    }

  } elsif ($fh_config->{pipes}) {
    close STDOUT;
    _safeopen(*STDOUT, ">&", $fh_config->{p_to_out})
      or warn "Forks::Super::Job::config_fh_child_stdout(): ",
	"could not attach child STDOUT to output pipe: $!\n";
    select STDOUT;
    debug("Opening ",*STDOUT,"/",CORE::fileno(STDOUT)," in child STDOUT")
      if $job->{debug};

    if ($fh_config->{join}) {
      delete $fh_config->{err};
      close STDERR;
      _safeopen(*STDERR, ">&", $fh_config->{p_to_out})
	or warn "Forks::Super::Job::config_fh_child_stdout(): ",
	  "could not join child STDERR to STDOUT sockethandle: $!\n";
    }

  } elsif ($fh_config->{f_out}) {
    my $fh;
    debug("Opening up $fh_config->{f_out} for output in the child   $$")
      if $job->{debug};
    if (_safeopen($fh,'>',$fh_config->{f_out})) {
      close STDOUT if $^O eq 'MSWin32';
      if (_safeopen(*STDOUT, ">&", $fh)) {
	if ($fh_config->{join}) {
	  delete $fh_config->{err};
	  close STDERR if $^O eq 'MSWin32';
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

sub config_fh_child_stderr {
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
      warn "Forks::Super::Job::config_fh_child_stderr(): ",
	"could not attach STDERR to child error sockethandle: $!\n";
    }
  } elsif ($fh_config->{pipes}) {
    close STDERR;
    if (_safeopen(*STDERR, ">&", $fh_config->{p_to_err})) {
      debug("Opening ",*STDERR,"/",CORE::fileno(STDERR),
	    " in child STDERR") if $job->{debug};
    } else {
      warn "Forks::Super::Job::config_fh_child_stderr(): ",
	"could not attach STDERR to child error pipe: $!\n";
    }
  } elsif ($fh_config->{f_err}) {
    my $fh;
    debug("Opening $fh_config->{f_err} as child STDERR")
      if $job->{debug};
    if (_safeopen($fh, '>', $fh_config->{f_err})) {
      close STDERR if $^O eq 'MSWin32';
      _safeopen(*STDERR, '>&', $fh)
	or warn "Forks::Super::Job::config_fh_child_stderr(): ",
	  "could not attach STDERR to child error filehandle: $!\n";
    } else {
      warn "Forks::Super::Job::config_fh_child_stderr(): ",
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
sub config_fh_child {
  my $job = shift;
  return if not defined $job->{fh_config};
  if ($job->{style} eq 'cmd' || $job->{style} eq 'exec') {
    if ($^O eq 'MSWin32') {
      return config_cmd_fh_child($job);
    }
  }

  config_fh_child_stdout($job);
  config_fh_child_stderr($job);
  config_fh_child_stdin($job);
  if ($job->{fh_config} && $job->{fh_config}->{sockets}) {
    my $s1 = $job->{fh_config}->{psock};
    my $s2 = $job->{fh_config}->{psock2};
    if (defined $s1) {
      $__OPEN_FH -= close $s1;
    }
    if (defined $s2) {
      $__OPEN_FH -= close $s2;
    }
  }
  if ($job->{fh_config} && $job->{fh_config}->{pipes}) {
    foreach my $pipeattr (qw(p_to_in p_out p_err)) {
      if (defined $job->{fh_config}->{$pipeattr}) {
	$__OPEN_FH -= close $job->{fh_config}->{$pipeattr};
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
    } elsif ($cmd !~ /\'/ && $^O ne 'MSWin32') {
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
sub config_cmd_fh_child {
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
	close $fhx;
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
  if (defined getsockname($handle)) {
    my $z = shutdown($handle,2) + close $handle;
    $__OPEN_FH-- if $z;
    return $z;
  } else {
    my $z = close $handle;
    $__OPEN_FH-- if $z;
    return $z;
  }
}

sub close_fh {
  my $job = shift;
  if (defined $job->{child_stdin} && !defined $job->{child_stdin_closed}) {
    if (_close $job->{child_stdin}) {
      $__OPEN_FH -= $job->{child_stdin_closed} = 1;
      debug("closed child stdin for $job->{pid}") if $job->{debug};
    }
  }
  if (defined $job->{child_stdout} && !defined $job->{child_stdout_closed}) {
    if (_close $job->{child_stdout}) {
      $__OPEN_FH -= $job->{child_stdout_closed} = 1;
      debug("closed child stdout for $job->{pid}") if $job->{debug};
    }
    if ($job->{fh_config}->{join}) {
      if (_close($job->{child_stderr}) || $job->{child_stdout_closed}) {
	$__OPEN_FH -= $job->{child_stderr_closed} = 1;
	debug("closed joined child stderr for $job->{pid}") if $job->{debug};
      }
    }
  }
  if (defined $job->{child_stderr} && !defined $job->{child_stderr_closed}) {
    if (_close $job->{child_stderr}) {
      $__OPEN_FH -= $job->{child_stderr_closed} = 1;
      debug("closed child stderr for $job->{pid}") if $job->{debug};
    }
  }
  foreach my $p ($job->{real_pid}, $job->{pid}, $job->{name}) {
    next if !defined $p;
    if (defined $Forks::Super::CHILD_STDIN{$p}) {
      delete $Forks::Super::CHILD_STDIN{$p}
    }
    if (defined $Forks::Super::CHILD_STDOUT{$p}) {
      delete $Forks::Super::CHILD_STDOUT{$p}
    }
    if (defined $Forks::Super::CHILD_STDERR{$p}) {
      delete $Forks::Super::CHILD_STDERR{$p}
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
