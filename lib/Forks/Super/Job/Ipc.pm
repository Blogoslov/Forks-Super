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
use Forks::Super::Sighandler;
use IO::Handle;
use File::Path;
# use Time::HiRes;  not installed on ActiveState 5.6 :-(
use Carp;
use strict;
use warnings;

$| = 1;

use Exporter;
our @ISA = qw(Exporter);

our @EXPORT = qw(close_fh);
our $VERSION = $Forks::Super::Util::VERSION;

our (%FILENO, %SIG_OLD, $IPC_COUNT, $IPC_DIR_DEDICATED, 
     @IPC_FILES, %IPC_FILES);
our ($SIGNALS_TRAPPED, $_CLEANUP, $_SIGNAL_TRAPPED_SO_SUPPRESS_INFO) = (0,0,0);
our $MAIN_PID = $$;
our $__OPEN_FH = 0; # for debugging, monitoring filehandle usage. Not ready.
our $__MAX_OPEN_FH = do {
  no warnings 'once';
  $Forks::Super::SysInfo::MAX_OPEN_FH;
};

our @PARENT_FH_CLOSE = ();     # track handles to close on cleanup
our @SAFEOPENED = ();


our $_IPC_DIR;
{

  package Forks::Super::Job::Ipc::Tie;

  # special behavior for $Forks::Super::IPC_DIR ==>
  # when this value is set, we should call set_ipc_dir.

  sub TIESCALAR {
    return bless {}, __PACKAGE__;
  }
  sub FETCH {
    my $self = shift;
    return $_IPC_DIR;
  }
  sub STORE {
    my ($self, $value) = @_;
    my $old = $_IPC_DIR;
    Forks::Super::Job::Ipc::set_ipc_dir($value, 1);
    return $old;
  }
  sub DEFINED {
    my $self = shift;
    return defined $_IPC_DIR;
  }
}

{
  # independent implementation of Symbol::gensym -- 

  # IO handles from this package will follow certain conventions
  #   1. created with _safeopen, _create_socket_pair, or _create_pipe
  #   2. attributes are set in the handle's namespace (glob, is_socket, 
  #      opened, etc.)
  #   3. fileno() stored in %Forks::Super::Job::Ipc::FILENO
  #
  # Another one of these conventions will be that all such handles will
  # be registered in the same namespace, so we can tell whether
  # an arbitrary handle was created by this module.

  my $pkg = "Forks::Super::IOHandles::";
  my $seq = 1000;

  sub _gensym () {
    no strict 'refs';
    my $name = "IO" . $$ . "_" . $seq++;
    my $ref = \*{$pkg . $name};
    delete $$pkg{$name};
    $ref;
  }
}

# open a filehandle with (a little) protection
# against "Too many open filehandles" error
sub _safeopen (*$$;$) {
  my ($fh, $mode, $expr, $robust) = @_;
  my ($open2, $open3);
  if ($mode =~ /&/) {
    my $fileno = CORE::fileno($expr);
    if (!defined $fileno) {
      carp "_safeopen: no fileno available for $expr!\n";
    } elsif ($fileno >= 0) {
      $open2 = $mode . $fileno;
    } else {
      ($open2, $open3) = ($mode, $expr);
    }
  } else {
    ($open2, $open3) = ($mode, $expr);
  }

  my $result;
  if (!defined $fh) {
    $fh = _gensym();
  }
  for (my $try = 1; $try <= 10; $try++) {
    if ($try == 10) {
      carp "Failed to open $mode $expr after 10 tries. Giving up.\n";
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
      push @SAFEOPENED, $fh;
      $__OPEN_FH++;

      # dereferenced file handles are just symbol tables, and we
      # can store arbitrary data in them [so long as they are
      # not assigned to the symbol tables for *main or *Forks::Super::xxx ]
      # -- there are a lot of ways we can make good use of this data.

      my ($pkg,$file,$line) = caller;
      $$fh->{opened} = Time::HiRes::time();
      $$fh->{caller} = "$pkg;$file:$line";
      $$fh->{is_regular} = 1;
      $$fh->{is_socket} = 0;
      $$fh->{is_pipe} = 0;
      $$fh->{mode} = $mode;
      $$fh->{expr} = $expr;
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

    # XXX - $! regex works in English locale only. This bit us
    # XXX - on http://www.cpantesters.org/cpan/report/8376777

    if ($! =~ /too many open filehandles/i
	|| $! == $Forks::Super::SysInfo::TOO_MANY_FH_ERRNO) {
      carp "$! while opening $open2 $expr. ",
	"[openfh=$__OPEN_FH/$__MAX_OPEN_FH] Retrying ...\n";
      Forks::Super::pause(0.1 * $try);
    } elsif (defined($robust) 
	     && ($! =~ /no such file or directory/i
		 || $! == $Forks::Super::SysInfo::FILE_NOT_FOUND_ERRNO)) {
      if ($DEBUG || (ref $robust eq 'Forks::Super::Job' && $robust->{debug})) {
	debug("$! while opening $open2 $expr in $$. Retrying ...");
      }
      Forks::Super::Util::pause(0.1 * $try);
    } else {
      $expr ||= '""';
      carp_once [$!], "$! while opening $open2 $expr in $$ ",
	"[openfh=$__OPEN_FH/$__MAX_OPEN_FH]. Retrying ...\n";
      Forks::Super::Util::pause(0.1 * $try);
    }
  }
  return $result;
}

sub Forks::Super::Job::_preconfig_fh {
  my $job = shift;
  
  my $config = {};
  if (defined $job->{child_fh}) {
    my $fh_spec = $job->{child_fh} || "";
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

    if ($fh_spec =~ /block/i) {
      $config->{block} = 1;
    }

    if (($job->{style} ne 'cmd' && $job->{style} ne 'exec') || !&IS_WIN32) {
      # sockets,pipes not supported for cmd/exec style forks on MSWin32
      # we could support cmd-style with IPC::Open3-like framework ...
      if ($fh_spec =~ /sock/i) {
	$config->{sockets} = 1;
      } elsif ($fh_spec =~ /pipe/i) {
	$config->{pipes} = 1;
      }
    } elsif (!Forks::Super::Config::CONFIG('filehandles')) {

      carp "Forks::Super::Job::_preconfig_fh: ",
	"Requested cmd/exec-style fork on MSWin32 with\n",
	"socket based IPC. This is not going to end well.\n";

      $config->{sockets} = 1;
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

  if (&IS_WIN32 && !$ENV{WIN32_PIPE_OK} && $config->{pipes}) {
    $config->{sockets} = 1;
    $config->{pipes} = 0;
  }

  # choose file names -- if sockets or pipes are used and successfully set up,
  # the files will never actually be created.
  if (Forks::Super::Config::CONFIG('filehandles')) {
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
  } elsif ($config->{sockets} || !$config->{pipes}) {
    $config->{sockets} ||= 7;
    if ($config->{in}) { $config->{f_in} = '__socket__'; }
    if ($config->{out}) { $config->{f_out} = '__socket__'; }
    if ($config->{err}) { $config->{f_err} = '__socket__'; }
  } elsif ($config->{pipes}) {
    if ($config->{in}) { $config->{f_in} = '__pipe__'; }
    if ($config->{out}) { $config->{f_out} = '__pipe__'; }
    if ($config->{err}) { $config->{f_err} = '__pipe__'; }
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
      # this is probably too late to fail ...
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
  if (!$Forks::Super::SysInfo::CONFIG{'pipe'}) {
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
  if (Forks::Super::Config::CONFIG('IO::Socket') && 0) {
    ($s_child, $s_parent) = IO::Socket->socketpair(Socket::AF_UNIX(),
			      Socket::SOCK_STREAM(), Socket::PF_UNSPEC());
    if (!(defined $s_child && defined $s_parent)) {
      warn "Forks::Super::_create_socket_pair: ",
	"IO::Socket->socketpair(AF_UNIX) failed. Trying AF_INET\n";
      ($s_child, $s_parent) = IO::Socket->socketpair(Socket::AF_INET(),
				Socket::SOCK_STREAM(), Socket::PF_UNSPEC());
    }
  } else {

    # socketpair not supported on MSWin32 5.6
    $s_child = _gensym();
    $s_parent = _gensym();

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
  $$s_child->{opened}     = $$s_parent->{opened}     = Time::HiRes::time();
  my ($pkg,$file,$line)   = caller(2);
  $$s_child->{caller}     = $$s_parent->{caller}     = "$pkg;$file:$line";

  return ($s_child,$s_parent);
}

sub ___fileno {
  my $fh = shift;
  return $FILENO{$fh};
}

sub _create_pipe_pair {
  if (!$Forks::Super::SysInfo::CONFIG{'pipe'}) {
    croak "Forks::Super::Job::_create_pipe_pair(): no pipe\n";
  }

  my ($p_read, $p_write) = (_gensym(), _gensym());
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
  $$p_read->{opened} = $$p_write->{opened} = Time::HiRes::time();

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
  if (not defined $_IPC_DIR) {
    _identify_shared_fh_dir();
  }

  $IPC_COUNT++;
  my $file = sprintf ("%s/%s%03d", $_IPC_DIR, $basename, $IPC_COUNT);
  if (defined $suffix) {
    $file .= $suffix;
  }

  if (&IS_WIN32) {
    $file =~ s!/!\\!g;
  }

  push @IPC_FILES, $file;
  $IPC_FILES{$file} = [ @debug_info ];

  if (!$IPC_DIR_DEDICATED && -f $file) {
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
  return if defined $_IPC_DIR;
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

  foreach my $dir (@search_dirs) {
    next unless defined $dir && $dir =~ /\S/;
    debug("Considering $dir as shared filehandle dir ...") if $DEBUG;
    if (Forks::Super::Config::configif('filehandles')) {
      if (set_ipc_dir($dir,0)) {
	debug("Selected $_IPC_DIR as shared filehandle dir ...")
	  if $DEBUG;
	return $_IPC_DIR;
      }
    }
  }
  return;
}

# attempt to set $_IPC_DIR / $Forks::Super::IPC_DIR. Will fail if
# input is not a good directory name.
our $_CLEANSE_MODE = 0;
sub set_ipc_dir {
  my ($dir, $carp) = @_;
  return if !defined($dir) || $dir !~ /\S/;

  if ($dir eq 'undef') {
    # don't use IPC.
    $Forks::Super::Config::CONFIG{"filehandles"} = 0;
    $_IPC_DIR = undef;
    return;
  }

  if (-e $dir && ! -d $dir) {
    carp "Forks::Super::set_ipc_dir: \"$dir\" is not a directory\n" if $carp;
    return;
  }
  if (! -d $dir) {
    if ($_CLEANSE_MODE) {
      return;
    }
    if (mkdir($dir,0777)) {
      if ($carp) {
        carp "Forks::Super::set_ipc_dir: Created IPC directory \"$dir\"\n";
      }
    } else {
      carp "Forks::Super::set_ipc_dir: ",
        "IPC directory \"$dir\" does not exist and could not be created: $!\n"
          if $carp;
      return;
    }
  }
  if ((! -r $dir) || (! -w $dir) || (! -x $dir)) {
    carp "Forks::Super::set_ipc_dir: ",
      "Insufficient permission on IPC directory \"$dir\"\n" if $carp;
    return;
  }

  my $dedicated_dirname = ".fhfork$$";
  my $n = 0;
  while (-e "$dir/$dedicated_dirname") {
    $dedicated_dirname = ".fhfork$$-$n";
    $n++;
    if ($n > 10000) {
      carp "Forks::Super::set_ipc_dir: ",
        "Failed to created new dedicated IPC directory under \"$dir\"\n"
          if $carp;
      return;
    }
  }

  if (!$_CLEANSE_MODE) {
    unless (mkdir("$dir/$dedicated_dirname", 0777) # taint warning
	    && -r "$dir/$dedicated_dirname"
	    && -w "$dir/$dedicated_dirname"
	    && -x "$dir/$dedicated_dirname") {

      carp "Forks::Super::set_ipc_dir: ",
	"Could not created dedicated IPC directory ",
	"\"$dir/$dedicated_dirname\"",
	"under \"$dir\": $!\n" if $carp;
      return;
    }
  }

  # success.
  $Forks::Super::FH_DIR = "$dir/$dedicated_dirname";   # deprecated

  $_IPC_DIR = "$dir/$dedicated_dirname"; 
  # $Forks::Super::IPC_DIR is tied to this variable

  $IPC_DIR_DEDICATED = 1;
  debug("dedicated IPC directory: $_IPC_DIR") if $DEBUG;

  # create README
  unless ($Forks::Super::Job::Ipc::NO_README
	 || $_CLEANSE_MODE) {
    my $readme = "$_IPC_DIR/README.txt";
    open my $readme_fh, '>', $readme;
    my $localtime = scalar localtime;
    print $readme_fh <<"____";
This directory was created by process $$ at $localtime
running $0 @ARGV.

It should be/have been cleaned up when the process completes/completed.
If that didn't happen for some reason, it is safe to delete
this directory.

____
    close $readme_fh; # ';
    push @IPC_FILES, $readme;
    $IPC_FILES{$readme} = [ purpose => 'README' ];
  }
  return 1;
}

sub _cleanup {
  no warnings 'once';
  if (defined $_IPC_DIR
      && 0 >= ($Forks::Super::DONT_CLEANUP || 0)) {

    #foreach my $fh (@PARENT_FH_CLOSE, @SAFEOPENED) {
    #  my $msg = "Closing $fh in parent:\n";
    #  foreach my $key (sort keys %$$fh) {
    #  	$msg .= "  $key  $$fh->{$key}\n";
    #  }
    #  my $result = close $fh ? 1 : 0;
    #  $msg .= "result: $result\n";

    #  warn $msg;
    #}

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

  my $cleanup = \&Forks::Super::Job::Ipc::__cleanup__;
  foreach my $sig (qw(INT TERM HUP QUIT PIPE)) {
    register_signal_handler($sig, 4, $cleanup);
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

# maintenance routine to erase all directories that look like
# temporary IPC directories.
#
# can invoke with
#
#    $ perl -MForks::Super=cleanse
#    $ perl -MForks::Super=cleanse,<directory>
#
sub cleanse {

  $_CLEANUP = 1;
  my $dir = shift;
  if (!defined $dir) {
    _identify_shared_fh_dir();
    $dir = $_IPC_DIR;
  }
  $dir =~ s![\\/]\.fhfork[^\\/]*$!!;
  if (! -e $dir) {
    print "No Forks::Super ipc files found under directory \"$dir\"\n";
    return;
  }
  print "Cleansing ipc directories under $dir\n";
  chdir $dir
    or croak "Forks::Super::Job::Ipc::cleanse: Can't move to $_IPC_DIR\n";
  opendir(D, ".");
  my $errors = 0;
  foreach my $ipc_dir (grep { -d $_ && /^\.fhfork/ } readdir (D)) {
    my $errors = _cleanse_dir($ipc_dir);
    if ($errors > 0) {
      no Carp;

      # on MSWin32, errors often mean that an existing process
      # is hanging on to these files?
      if ($^O eq 'MSWin32') {
	warn "Encountered $errors errors cleaning up $ipc_dir:\n    $^E\n";
      } else {
	warn "Encounted $errors errors cleaning up $ipc_dir\n";
      }
    }
  }
  closedir D;
}

sub _cleanse_dir {
  my $dir = shift;
  my $dh;
  opendir $dh, $dir;
  my $errors = 0;
  while (my $f = readdir($dh)) {
    next if $f eq '.' || $f eq '..';
    if (-d "$dir/$f") {
      $errors += _cleanse_dir("$dir/$f");
    } else {
      unlink "$dir/$f" or $errors++;
    }
  }
  closedir $dh;
  unless ($errors) {
    rmdir $dir and print "Removed $dir\n";
  }
  return $errors;
}

sub _untrap_signals {
  foreach my $sig (qw(INT TERM HUP QUIT PIPE)) {
    register_signal_handler($sig, 4, undef);
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
  my @unused_files = grep { ! -e $_ } keys %IPC_FILES;
  delete $IPC_FILES{$_} for @unused_files;

  if (0 == scalar keys %IPC_FILES) {
    if (!defined $IPC_DIR_DEDICATED
	|| ! -d $_IPC_DIR
	|| rmdir $_IPC_DIR) {
      return;
    }
  }

  # daemonize
  return if CORE::fork();
  exit 0 if CORE::fork();

  # rename process, if supported by the OS, to note that we are cleaning up
  # not everyone will like this "feature"
  $0 = "cleanup:$0";
  sleep 3;

  # removing all the files we created during IPC
  # doesn't always go smoothly. We'll give a
  # 3/4-assed effort to remove the files but
  # nothing more heroic than that.

  my %G = ();
  foreach my $ipc_file (keys %IPC_FILES) {
    if (! -e $ipc_file) {
      $G{$ipc_file} = delete $IPC_FILES{$ipc_file};
    } else {
      local $! = undef;
      if ($DEBUG) {
	print STDERR "Deleting $ipc_file ... ";
      }
      my $z = unlink $ipc_file;
      if ($z && ! -e $ipc_file) {
	print STDERR "Delete $ipc_file ok\n" if $DEBUG;
	$G{$ipc_file} = delete $IPC_FILES{$ipc_file};
      } else {
	print STDERR "Delete $ipc_file not ok: $!\n" if $DEBUG;
	warn "Forks::Super::END_cleanup: ",
	  "error disposing of ipc file $ipc_file: $z/$!\n";
      }
    }
  }

  if (0 == scalar keys %IPC_FILES && defined $IPC_DIR_DEDICATED) {

    my $zz = rmdir($_IPC_DIR) || 0;
    if ($zz) {
      return;
    }


    sleep 2;
    exit 0 if CORE::fork();

    # long sleep here for maximum portability.
    sleep 10;
    my $z = rmdir($_IPC_DIR) || 0;
    if (!$z) {
      unlink glob("$_IPC_DIR/*");
      sleep 5;
      $z = rmdir($_IPC_DIR) || 0;
    }
    if (!$z
	&& -d $_IPC_DIR
	&& 0 < glob("$_IPC_DIR/.nfs*")) {

      # Observed these files on Linux running from NSF mounted filesystem
      # .nfsXXX files are usually temporary (~30s) but hard to kill
      for (my $i=0; $i<10; $i++) {
	sleep 5;
	if (glob("$_IPC_DIR/.nfs*") <= 0) {
	  if ($DEBUG) {
	    print STDERR "Temporary .nfsXXX files are gone.\n";
	  }
	  last;
	}
      }
      $z = rmdir($_IPC_DIR) || 0;
    }

    if (!$z && -d $_IPC_DIR) {
      warn "Forks::Super::END_cleanup: ",
	"rmdir $_IPC_DIR failed. $!\n";

      opendir(_Z, $_IPC_DIR);
      my @g = grep { !/^\.nfs/ } readdir(_Z);
      closedir _Z;

      foreach my $g (@g) {
	my $gg = "$_IPC_DIR/$g";
	if (defined $G{$gg} && $G{$gg}) {
	  my %gg = @{$G{$gg}};
	  if ($Forks::Super::DEBUG) {
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
      if (@g) { 
	print STDERR join "\t", @g, "\n"; 
      }
    }
  }
  return;
}

sub END_cleanup_MSWin32 {
  return if $$ != ($Forks::Super::MAIN_PID || $MAIN_PID);
  return if $_CLEANUP++;
  $0 = "cleanup:$0";

  # Use brute force to close all open handles. Leave STDERR open for warns.
  # XXX - is this ok? what if perl script is communicating with a socket?
  use POSIX ();
  for (0,1,3..999) {
    POSIX::close($_);
  }

  Forks::Super::Job::dispose(@Forks::Super::ALL_JOBS);

  my @G = grep { -e $_ } keys %IPC_FILES;
  FILE_TRY: for my $try (1 .. 3) {
      if (@G == 0) {
	last FILE_TRY;
      }
      foreach my $G (@G) {
	local $! = undef;
	if (!unlink $G) {
	  undef $!;
	  $G =~ s!/!\\!;
	  my $c1 = system("CMD /C DEL /Q \"$G\" 2> NUL");
	}
      }
    } continue {
      sleep 1;
      @G = grep { -e $_ } keys %IPC_FILES;
    }

  if (@G != 0) {
    # in Windows, remaining files might be "being used by another process".
    my $dir = $_IPC_DIR;
    $dir =~ s!\\!/!g;
    $dir =~ s!/[^/]+$!!;
    warn "Forks::Super: failed to clean up ", scalar @G, " temp files.\n",
      "Run  $^X -MForks::Super=cleanse,$dir  ",
      "after this program has ended.\n";
    return;
  }

  if (defined $IPC_DIR_DEDICATED) {
    local $! = undef;
    my $z = rmdir $_IPC_DIR;
    if (!$z) {
      warn "Forks::Super: failed to remove dedicated temp file directory ",
	"$_IPC_DIR: $!\n";
    }
  }
  return;
}

sub _config_fh_parent_stdin {
  my $job = shift;
  my $fh_config = $job->{fh_config};
  # return if defined $fh_config->{stdin}; # took care of this in preconfig_fh

  if ($fh_config->{in}) {
    # intiailize $fh_config->{child_stdin}

    if ($fh_config->{sockets} && !defined $fh_config->{stdin}) {

      $fh_config->{s_in} = $fh_config->{psock};
      $job->{child_stdin} 
	= $Forks::Super::CHILD_STDIN{$job->{real_pid}}
	= $Forks::Super::CHILD_STDIN{$job->{pid}} 
	= $fh_config->{s_in};
      $fh_config->{f_in} = '__socket__';
      debug("Setting up socket to $job->{pid} stdin $fh_config->{s_in} ",
	    CORE::fileno($fh_config->{s_in})) if $job->{debug};
      push @PARENT_FH_CLOSE, $fh_config->{s_in};

    } elsif ($fh_config->{pipes} && !defined $fh_config->{stdin}) {

      $job->{child_stdin} 
	= $Forks::Super::CHILD_STDIN{$job->{real_pid}}
	= $Forks::Super::CHILD_STDIN{$job->{pid}} 
	= $fh_config->{p_to_in};
      $fh_config->{f_in} = '__pipe__';
      debug("Setting up pipe to $job->{pid} stdin $fh_config->{p_to_in} ",
	    CORE::fileno($fh_config->{p_to_in})) if $job->{debug};
      push @PARENT_FH_CLOSE, $fh_config->{p_to_in};

    } elsif (defined $fh_config->{stdin}) {
      debug("Passing STDIN from parent to child in scalar variable")
	if $job->{debug};
    } elsif (defined $fh_config->{f_in}) {
      my $fh = _gensym();
      local $! = 0;
      if (_safeopen $fh, '>', $fh_config->{f_in}) {

	debug("Opening $fh_config->{f_in} in parent as child STDIN")
	  if $job->{debug};
	$job->{child_stdin} 
	  = $Forks::Super::CHILD_STDIN{$job->{real_pid}} 
	  = $fh;
	$Forks::Super::CHILD_STDIN{$job->{pid}} = $fh;
	$fh->autoflush(1);
	push @PARENT_FH_CLOSE, $fh;

	debug("Setting up link to $job->{pid} stdin in $fh_config->{f_in}")
	  if $job->{debug};

      } else {
	warn "Forks::Super::Job::config_fh_parent(): ",
	  "could not open filehandle to write child STDIN (to ",
	  $fh_config->{f_in}, "): $!\n";
      }
    } else {

      # I hope we don't / can't get here.
      Carp::cluck "fh_config->{in} is specified for ", $job->toFullString(),
	"but we did not configure it in _config_fh_parent_stdin.\n";

    }
  }
  if (defined $job->{child_stdin}) {
    my $fh = $job->{child_stdin};
    $$fh->{job} = $job;
    $$fh->{purpose} = 'parent write to child stdin';
    push @PARENT_FH_CLOSE, $fh;
  }
  return;
}

sub __ipc_debug {   # XXXXXX this is hacky
  my $job = shift;
  print STDERR "OPEN_FH => $__OPEN_FH / $__MAX_OPEN_FH\n";
  print STDERR "IPC_COUNT => $IPC_COUNT\n";
  print STDERR "IPC_FILES => ", scalar @IPC_FILES, "\n";
  print STDERR "FILENO map:\n";
  # print STDERR map "\t$_ => " . $FILENO{$_} . "\n", keys %FILENO;
  Carp::confess "Child failed, wstatus = 139" if $job->{status} == 139;
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
    push @PARENT_FH_CLOSE, $fh_config->{s_out};

  } elsif ($fh_config->{out} && $fh_config->{pipes}) {

    $job->{child_stdout}
      = $Forks::Super::CHILD_STDOUT{$job->{real_pid}}
      = $Forks::Super::CHILD_STDOUT{$job->{pid}}
      = $fh_config->{p_out};
    push @PARENT_FH_CLOSE, $fh_config->{p_out};
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

    if (_safeopen($fh, '<', $fh_config->{f_out}, $job)) {

      debug("Opened child STDOUT in parent") if $job->{debug};
      $job->{child_stdout} = $Forks::Super::CHILD_STDOUT{$job->{real_pid}}
	= $Forks::Super::CHILD_STDOUT{$job->{pid}} = $fh;

      debug("Setting up link to $job->{pid} stdout in $fh_config->{f_out}")
	if $job->{debug};
      push @PARENT_FH_CLOSE, $fh;

    } else {
      my $_msg = sprintf "%d: %s Failed to open f_out=%s: %s\n",
	$$, Forks::Super::Util::Ctime(), $fh_config->{f_out}, $!;

      if ($DEBUG || $ENV{IPC_DEBUG}) {
	Forks::Super::Sigchld::handle_CHLD(-1);
	Carp::cluck "\n\n\n\nForks::Super::Job::config_fh_parent(): \n    ",
	    "could not open filehandle to read child STDOUT from ",
	      $fh_config->{f_out}, "\n     for ",
		$job->toString(),
		  ": $!\n$_msg\n";
	__ipc_debug($job);


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
  if ($fh_config->{block}) {
    ${$job->{child_stdout}}->{emulate_blocking} = 1;
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
    push @PARENT_FH_CLOSE, $fh_config->{s_err};
    $fh_config->{f_err} = '__socket__';
    debug("Setting up socket to $job->{pid} stderr $fh_config->{s_err} ",
	  CORE::fileno($fh_config->{s_err})) if $job->{debug};

  } elsif ($fh_config->{err} && $fh_config->{pipes}) {

    $job->{child_stderr}
      = $Forks::Super::CHILD_STDERR{$job->{real_pid}}
      = $Forks::Super::CHILD_STDERR{$job->{pid}}
      = $fh_config->{p_err};
    push @PARENT_FH_CLOSE, $fh_config->{p_err};
    $fh_config->{f_err} = '__pipe__';
    debug("Setting up pipe to $job->{pid} stderr ",
	  CORE::fileno($fh_config->{p_err})) if $job->{debug};

  } elsif ($fh_config->{err} and defined $fh_config->{f_err}) {

    delete $fh_config->{join};
    my $fh;
    debug("Opening ", $fh_config->{f_err}, " in parent as child STDERR")
      if $job->{debug};
    local $! = 0;
    if (_safeopen($fh, '<', $fh_config->{f_err}, $job)) {

      debug("Opened child STDERR in parent") if $job->{debug};
      $job->{child_stderr} 
	  = $Forks::Super::CHILD_STDERR{$job->{real_pid}}
	  = $Forks::Super::CHILD_STDERR{$job->{pid}} 
	  = $fh;
      push @PARENT_FH_CLOSE, $fh;

      debug("Setting up link to $job->{pid} stderr in $fh_config->{f_err}")
	if $job->{debug};

    } else {
      my $_msg = sprintf "%d: %s Failed to open f_err=%s: %s\n",
	  $$, Forks::Super::Util::Ctime(), $fh_config->{f_err}, $!;
      if ($DEBUG || $ENV{IPC_DEBUG}) {
	Forks::Super::Sigchld::handle_CHLD(-1);
	Carp::cluck "Forks::Super::Job::config_fh_parent(): \n    ",
	    "could not open filehandle to read child STDERR from ",
	      $fh_config->{f_err}, "\n    for ",
		$job->toString(),
		  ": $!\n";
	__ipc_debug($job);
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
  if ($fh_config->{block}) {
    ${$job->{child_stdout}}->{emulate_blocking} = 1;
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
    if ($fh_config->{sockets} || $fh_config->{pipes}) {

      # warn "\n\n\n\nTrying to open scalar STDIN: $fh_config->{stdin}\n\n\n\n";

      if (_safeopen($fh, '<', \$fh_config->{stdin})) {
	close STDIN;
	if (_safeopen(*STDIN, '<&', $fh)) {
	  push @{$job->{child_fh_close}}, $fh, *STDIN;
	  debug("Reopened STDIN in child") if $job->{debug};
	  ${*STDIN}->{dup} = "ref \"" . $fh_config->{stdin} . "\"";
	} else {
	  close $fh;
	  carp "Forks::Super::Job::Ipc::_config_fh_child_stdin: ",
	    "Error initializing scalar STDIN in child $$: $!\n";
	}
      } else {
	carp "Forks::Super::Job::Ipc::_config_fh_child_stdin: ",
	  "Error initializing scalar STDIN in child $$: $!\n";
      }

    } elsif (!(_safeopen($fh, '<', $fh_config->{f_in}))) {
      carp "Forks::Super::Job::Ipc::_config_fh_child_stdin(): ",
	"Error initializing scalar STDIN in child $$: $!\n";
    } elsif (!(_safeopen(*STDIN, '<&', $fh))) {
      push @{$job->{child_fh_close}}, $fh;
      carp "Forks::Super::Job::Ipc::_config_fh_child_stdin(): ",
	"Error initializing scalar STDIN in child $$: $!\n";
    } else {
      push @{$job->{child_fh_close}}, $fh;
    }

  } elsif ($fh_config->{sockets}) {
    close STDIN;
    push @{$job->{child_fh_close}}, $fh_config->{csock};
    if (!(_safeopen( *STDIN, '<&', $fh_config->{csock}))) {
      warn "Forks::Super::Job::_config_fh_child_stdin(): ",
	"could not attach child STDIN to input sockethandle: $!\n";
    }
    debug("Opening socket ",*STDIN,"/",CORE::fileno(STDIN), " in child STDIN")
      if $job->{debug};
  } elsif ($fh_config->{pipes}) {
    push @{$job->{child_fh_close}}, $fh_config->{p_in};
    close STDIN;
    if (!(_safeopen(*STDIN, '<&', $fh_config->{p_in}))) {
      warn "Forks::Super::Job::_config_fh_child_stdin(): ",
	"could not attach child STDIN to input pipe: $!\n";
    } else {
      push @{$job->{child_fh_close}}, *STDIN;
    }
    debug("Opening pipe ",*STDIN,"/",CORE::fileno(STDIN), " in child STDIN")
      if $job->{debug};
  } elsif ($fh_config->{f_in}) {
    # creation of $fh_config->{f_in} may be delayed.
    # don't panic if we can't open it right away.
    my $fh;
    debug("Opening ", $fh_config->{f_in}, " in child STDIN") if $job->{debug};

    # $job||1 idiom was failure point in v5.6.2
    if (_safeopen($fh, '<', $fh_config->{f_in}, $job)) {
      push @{$job->{child_fh_close}}, $fh;
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
  if (defined($fh_config->{block}) && $fh_config->{block}) {
    ${*STDIN}->{emulate_blocking} = 1;
  }
  return;
}

sub _config_fh_child_stdout {
  my $job = shift;
  local $! = undef;
  my $fh_config = $job->{fh_config};
  return unless $fh_config->{out};

  if ($fh_config->{sockets}) {
    push @{$job->{child_fh_close}}, $fh_config->{csock};
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
    push @{$job->{child_fh_close}}, $fh_config->{p_to_out}, *STDOUT;

    if ($fh_config->{join}) {
      delete $fh_config->{err};
      close STDERR;
      _safeopen(*STDERR, ">&", $fh_config->{p_to_out})
	or warn "Forks::Super::Job::_config_fh_child_stdout(): ",
	  "could not join child STDERR to STDOUT sockethandle: $!\n";
      push @{$job->{child_fh_close}}, *STDERR;
    }

  } elsif ($fh_config->{f_out}) {
    my $fh;
    debug("Opening up $fh_config->{f_out} for output in the child   $$")
      if $job->{debug};
    if (_safeopen($fh,'>',$fh_config->{f_out})) {
      push @{$job->{child_fh_close}}, $fh;
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
    push @{$job->{child_fh_close}}, $fh_config->{$fileno_arg};
    if (_safeopen(*STDERR, ">&", $fh_config->{$fileno_arg})) {
      debug("Opening ",*STDERR,"/",CORE::fileno(STDERR),
	    " in child STDERR") if $job->{debug};
    } else {
      warn "Forks::Super::Job::_config_fh_child_stderr(): ",
	"could not attach STDERR to child error sockethandle: $!\n";
    }
  } elsif ($fh_config->{pipes}) {
    push @{$job->{child_fh_close}}, $fh_config->{p_to_err};
    close STDERR;
    if (_safeopen(*STDERR, ">&", $fh_config->{p_to_err})) {
      debug("Opening ",*STDERR,"/",CORE::fileno(STDERR),
	    " in child STDERR") if $job->{debug};
      push @{$job->{child_fh_close}}, *STDERR;
    } else {
      warn "Forks::Super::Job::_config_fh_child_stderr(): ",
	"could not attach STDERR to child error pipe: $!\n";
    }
  } elsif ($fh_config->{f_err}) {
    my $fh;
    debug("Opening $fh_config->{f_err} as child STDERR")
      if $job->{debug};
    if (_safeopen($fh, '>', $fh_config->{f_err})) {
      push @{$job->{child_fh_close}}, $fh;
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

  # "a tie in the parent should not be allowed to cause problems"
  # according to IPC::Open3
  untie *STDIN;
  untie *STDOUT;
  untie *STDERR;

  if ($job->{style} eq 'cmd' || $job->{style} eq 'exec') {
  # if (&IS_WIN32) {
    if (&IS_WIN32 && Forks::Super::Config::CONFIG('filehandles')) {
      return _config_cmd_fh_child($job);
    }
  }

  # track handles to close when the child exits
  $job->{child_fh_close} = [];

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
    #
    # e.g., want to be able to handle:
    #    $^X -F/\\\|/ -alne '$_=$F[3]-$F[1]-$F[2]' | ./another_program
    # and have input inserted after the SECOND |
    # To solve this we need to parse the command as well as the
    # shell does ...

    {
      # a crude parser that looks for the first unescaped
      # pipe char that is not inside single or double quotes, 
      # or inside a () [] {} expression.

      # XXX good enough to pass t/42h but I wonder what edge cases it misses.

      my @chars = split //, $cmd[0];
      my $result = "";
      my $insert = 0;
      my @group = ("");

      while (@chars) {
	my $char = shift @chars;
	$result .= $char;

	if ($char eq "\\") {
	  $result .= shift @chars;
	} elsif ($char eq '"') {
	  if ($group[-1] eq '"') {
	    pop @group;
	  } elsif ($group[-1] ne "'") {
	    push @group, '"';
	  }
	} elsif ($char eq "'") {
	  if ($group[-1] eq "'") {
	    pop @group;
	  } elsif ($group[-1] ne '"') {
	    push @group, "'";
	  }
	} elsif ($char eq "(" || $char eq "[" || $char eq "{") {
	  push @group, $char;
	} elsif ($char eq ")" && $group[-1] eq "(") {
	  pop @group;
	} elsif ($char eq "]" && $group[-1] eq "[") {
	  pop @group;
	} elsif ($char eq "}" && $group[-1] eq "{") {
	  pop @group;
	} elsif ($char eq "|" && @group <= 1) {
	  chop $result;
	  $result .= ' <"' . $fh_config->{f_in} . '" | ';
	  $result .= join'', @chars;
	  @chars = ();
	  $insert = 1;
	}
      }
      if (!$insert) {
	$result .= ' <"' . $fh_config->{f_in} . '"';
      }
      $cmd[0] = $result;
    }

    # $cmd[0] =~ s/(\s?\||$)/ <"$fh_config->{f_in}" $1/;

    # external command must not launch until the input file has been created

    my $try;
    for ($try = 0; $try <= 10; $try++) {
      if (-r $fh_config->{f_in}) {
	$try = 0;
	last;
      }
      Forks::Super::pause(0.25 * $try);
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
  $$handle->{closed} ||= Time::HiRes::time();
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
      $$handle->{closed} ||= Time::HiRes::time();
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
  # delete $Forks::Super::CHILD_STDIN{...} for this job? No.
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
  # delete $Forks::Super::CHILD_STDOUT{...} ? No.
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
  # delete $Forks::Super::CHILD_STDERR{...}? No.
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

  if ($$sh->{closed} || !$sh->opened) {
    carp "Forks::Super::_read_socket: read on closed socket $sh ",
      $job->toString(), "\n";
    return;
  }

  # is socket is blocking, then we need to test whether
  # there is input to be read before we read on the socket

  my $blocking_desired = $$sh->{emulate_blocking} || 0;
  if (defined $options{"block"}) {
    $blocking_desired = $options{"block"};
  }
  #my $blocking_desired = defined($options{"block"}) && $options{"block"} != 0;
  my $expire = 0;
  if (defined($options{'timeout'}) && $options{'timeout'} > 0) {
    $expire = Time::HiRes::time() + $options{'timeout'};
    $blocking_desired = 1;
  }

  while ($sh->blocking() || &IS_WIN32 || $blocking_desired) {
    my $fileno = fileno($sh);
    if (not defined $fileno) {
      $fileno = Forks::Super::Job::Ipc::fileno($sh);
      Carp::cluck "Cannot determine FILENO for socket handle $sh!";
    }

    my ($rin,$rout,$ein,$eout);
    my $timeout = $Forks::Super::SOCKET_READ_TIMEOUT || 1.0;
    if ($expire && Time::HiRes::time() + $timeout > $expire) {
      $timeout = $expire - Time::HiRes::time();
      if ($timeout < 0) {
	$timeout = 0.0;
	$blocking_desired = 0;
      }
    }

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
    return if !$blocking_desired;
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

  my $blocking_desired = $$sh->{emulate_blocking} || 0;
  if (defined $options{'block'}) {
    $blocking_desired = $options{'block'};
  }

  # pipes are blocking by default.
  if ($blocking_desired) {
    return $wantarray ? readline($sh) : scalar readline($sh);
  }

  my ($rin,$rout,$ein,$eout);
  $rin = '';
  vec($rin, $fileno, 1) = 1;

  my $timeout = $Forks::Super::SOCKET_READ_TIMEOUT || 1.0;
  if (defined($options{'timeout'}) && $options{'timeout'} >= 0) {
    $timeout = $options{'timeout'};
  }

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
    return; # return ''?
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
  my $expire = 0;
  my $blocking_desired = $$fh->{emulate_blocking};
  if (defined $options{'block'}) {
    $blocking_desired = $options{'block'};
  }
  if (defined($options{'timeout'}) && $options{'timeout'} > 0) {
    $expire = Time::HiRes::time() + $options{'timeout'};
    $blocking_desired = 1;
  }
  #my $blocking_desired = defined($options{"block"}) && $options{"block"} != 0;

  local $! = undef;
  if ($wantarray) {
    my @lines;
    while (@lines == 0) {
      @lines = readline($fh);
      if (@lines > 0) {
	return @lines;
      }

      if ($job->is_complete && Time::HiRes::time() - $job->{end} > 3) {
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
	if ($blocking_desired) {
	  Forks::Super::pause();
	  if ($expire > 0 && Time::HiRes::time() >= $expire) {
	    $blocking_desired = 0;
	  }
	}
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

      if ($job->is_complete && Time::HiRes::time() - $job->{end} > 3) {
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
	if ($blocking_desired) {
	  Forks::Super::pause();
	  if ($expire > 0 && Time::HiRes::time() >= $expire) {
	    $blocking_desired = 0;
	  }
	}
      }
      if (!$blocking_desired) {
	return '';
      }
    }
  }
}



sub init_child {
  $IPC_DIR_DEDICATED = 0;
  %IPC_FILES = @IPC_FILES = ();
  %SIG_OLD = ();
  return;
}

sub deinit_child {
  if (@IPC_FILES > 0) { 
    Carp::cluck("Child $$ had temp files! @IPC_FILES\n");
    unlink @IPC_FILES;
    @IPC_FILES = ();
  }

  my %closed = ();
  foreach my $fh (@{$Forks::Super::Job::self->{child_fh_close}}, @SAFEOPENED) {
    next if $closed{$fh}++;
    close $fh;
  }
}

1;
