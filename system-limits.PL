use lib q(lib);
use strict;
use warnings;

###############################################################
#
# probe the limitations of this system including the maximum
# number of simultaneous child processes and the maximum number
# of open filehandles.
#
# this information is used in t/32-stress-test.t
#
###############################################################
#
# Cygwin note: this script can trigger a five-minute delay
# followed by a "WFSO timed out after longjmp" error message.
# When the parent runs out of resources, it will fail to copy
# its data (heap, stack, etc.) to the new child process, and
# fail to signal the child process to wake up. The child will
# wake up by itself in five minutes, but without valid data it
# will trigger the above WFSO error. I don't think this 
# affects the testing of the module except to create a few
# zombie processes for a few minutes.
#
###############################################################

if ($^O eq 'cygwin') {
  print STDERR<<'';
*************************************************
* On Cygwin systems, if you see error messages  *
* that say "WFSO timed out after longjmp" five  *
* minutes from now, they came from this script  *
*              and they are normal.             *
*************************************************

}

my $limits_file = $ARGV[0] || "t/out/limits.$^O.$]";

if (fork()) {
  wait;
  for (my $i = 0; $i < 5; $i++) {
    if (! -r $limits_file) {
      sleep 1;
    }
  }
  print STDERR "\n\n";
  if (! -r $limits_file) {
    warn "System limitations file $limits_file still not found.\n ";
  }
  print STDERR <<'';
"make" complete.
You may now run "make test" to run the unit tests in series
or "make fasttest" to run them in parallel.

  exit;
}

# for best results, only one process should be testing limits at a time
open(LOCK, ">>", "t/out/.lock-flim");
flock LOCK, 2;

my %LIMITS = ();
$LIMITS{file} = $ARGV[0] || "t/out/limits.$^O.$]";
$LIMITS{system} = $^O;
$LIMITS{version} = $];

&count_number_of_cpus;
&find_max_open_filehandles;
&find_max_open_sockets;
&find_max_fork;  # run last because it might crash the system
print "Created system limitations file in: $limits_file\n";

close LOCK;

#############################################################################

sub write_limits {
  my (%new_data) = @_;
  $LIMITS{$_}=$new_data{$_} for keys %new_data;

  open(my $lhf, '>', $LIMITS{file});
  foreach my $key (keys %LIMITS) {
    print $lhf "$key:$LIMITS{$key}\n";
  }
  close $lhf;
  
}

#
# determine the maximum number of simultaneous background processes
#
sub find_max_fork {
  my $limits_file = $LIMITS{file};
  if (-f $limits_file) {
    unlink $limits_file;
  }

  my $N = 200;
  print STDERR "";
  undef $@;
  my $r = eval {
    unlink "$limits_file.pid";
    for (my $i=0; $i<$N; $i++) {
      undef $@;
      my $pid;
      eval { 
	$pid = fork();    # CORE::fork, not Forks::Super::fork
      }; 
      if ($@ || !defined $pid) {
	print STDERR "$^O-$] cannot fork more than $i child processes.\n";
	1 while wait > -1;
	exit 0;
      } elsif ($pid == 0) {
	print STDERR "";
	sleep 10;
	exit 0;
      }
      if ($i > 1) {
	&write_limits('maxfork' => $i);
      }
    }
    print STDERR "$^O-$] successfully forked $N processes.\n";
    1 while wait > -1;
  };
  print "Result: $r / $@\n";
  return $r;
}

#
# determine the maximum number of open filehandles allowed
# by a process on this system. The module doesn't (currently)
# do anything with this information.
#
sub find_max_open_filehandles {

    # in BSD, this information can be obtained from
    # sysctl kern.maxfiles[=new_value]
    # sysctl kern.maxfilesperproc[=new_value]

    # in Linux, check out the files. They can be written to.
    # /proc/sys/kernel|fs/file-max  [max open filehandles]
    # /proc/sys/kernel/inode-max
    # /proc/sys/kernel/file-nr   [filehandles in use]
    # Per process limits from:  ulimit -n ; sudo ulimit -n <n>

    # Solaris: add to /etc/system:
    #     set rlim_fd_max = xxxx
    #     set rlim_fd_cur = xxxx

  my $i = 0;
  undef $!;
  my $j = $$;
  my @fh = ();
  while (open (my $fh, ">", "xxx.$j")) {
    $i++;
    push @fh, $fh;
  }
  my $err = $!;
  close $_ for @fh;
  print STDERR "Msg for $i open files: $err\n";
  &write_limits('maxfilehandle' => $i);
  unlink "xxx.$j";

  return $i;
}

# XXX - TODO
sub find_max_open_sockets {
}

#
# try to guess how many processors this system has.
# Eventually we could use that information to set
# a default value of $Forks::Super::MAX_PROC in the
# installed code.
#
sub count_number_of_cpus {
  # XXX - TODO
  # XXX - Maybe wait for Sys::CpuAffinity
}

