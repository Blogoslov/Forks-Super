###############################################################
# system-limits.PL
#
# probe the limitations of this system including the maximum
# number of simultaneous child processes and the maximum number
# of open filehandles.
#
# this information is used in t/32-stress-test.t and to create
# the  Forks/Super/SysInfo.pm  file
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
# affects the testing of the module except to create some
# zombie processes for a few minutes.
#
###############################################################

use lib q(lib);
use strict;
use warnings;
use Config;


my $limits_file = $ARGV[0] || "t/out/limits.$^O.$]";
my %LIMITS = (file => $limits_file);
our $MAIN_PID = $$;

if ($^O eq 'cygwin') {
  
  # I think we've fixed this.
  0 && print STDERR qq!
*************************************************
* On Cygwin systems, if you see error messages  *
* that say "WFSO timed out after longjmp" five  *
* minutes from now, they came from this script  *
*              and they are normal.             *
*                                               *
*    You may also see an error message like:    *
*                                               *
* *** fatal error - CreateThread failed for ... *
*                                               *
*    with a stack dump. This is also normal.    *
*************************************************\n!;

}

my $pid = fork();
if ($pid) {
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
    if ($^O eq 'cygwin') {
	# clean up the stray process with the same PGID as this process.
	# If that works, it will suppress the "WSFO time out ..." error.
	my $target_pgid = $$;
	if (fork() == 0) {
	    $0="system-limits.PL cygwin cleanup";
	    sleep 30;
	    my @proc_table = qx(/usr/bin/ps);
	    shift @proc_table;             # skip header
	    foreach my $ps (@proc_table) {
		next if $ps =~ m(/usr/bin/ps);
		$ps =~ s/^\s+//;
		my @ps = split /\s+/, $ps;
		if ($ps[2] == $target_pgid && $ps[0] != $target_pgid) {
		    sleep 10;
		    system("taskkill /f /pid $ps[3]");
		}
	    }
	    exit;
	}
    }
    exit;
}

# for best results, only one process should be testing limits at a time
open(LOCK, ">>", "t/out/.lock-flim");
flock LOCK, 2;

END {
    if ($$ == $MAIN_PID) {
	close LOCK;
	unlink "t/out/.lock-flim";
    }
}

#my %LIMITS = ();
#$LIMITS{file} = $ARGV[0] || "t/out/limits.$^O.$]";
$LIMITS{system} = $^O;
$LIMITS{version} = $];

# XXX - what else is interesting? 
#       max pending signals?

&get_Time_HiRes_tolerance;
&checkif_sleep_alarm_compatible;
&count_number_of_cpus;
&find_max_open_filehandles;     # on some systems:  ulimit -n
&find_max_open_sockets;         # TODO
&find_socket_capacity;
&find_pipe_capacity;            # on some systems:  512 * ulimit -p
&wait_waitpid_results;
&explore_sync_options;

&find_max_fork(300);  # run last because it might crash the program
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

#############################################################################

sub get_Time_HiRes_tolerance {
    # I found an insidious bug where this code:
    #    do {
    #       $t1 = Time::HiRes::time();
    #       $t2 = Time::HiRes::time();
    #       $t2 < $t1
    #    };
    # could return *TRUE*. 
    #
    # On opensolaris 5.11 (running on Oracle VM Virtualbox, which was
    # running on Windows 7), this can be as much as 0.03s.
    #
    # Even on Windows 7/Cygwin, it can be 0.0005s
    #
    # www.cpantesters.org/cpan/report/df00514e-153d-11e1-b03e-8398e1de4735:
    # this value is 0.89s ?!?!?!
    #

    # Ideally, this subroutine is run on a lightly loaded system.

    unless (eval { use Time::HiRes (); 1 }) {
	write_limits(TimeHiRes_tol => '0E0');
    }
    my ($max,$t,$u,$diff) = (0, Time::HiRes::time());
    my $v = $t + 15;
    while ($t < $v) {
	($u,$t) = ($t,Time::HiRes::time());
	$diff = $u-$t;
	$max=$diff if $max<$diff;
    }
    if ($max > 0) {
	print STDERR "Observed time on this system skipping backwards by ${max}s.\n";
    }
    write_limits(TimeHiRes_tol => $max * 1.1);
}

sub checkif_sleep_alarm_compatible {
    my $compatible = -1;
    eval {
	local $SIG{ALRM} = sub { die "Timeout\n" };
	alarm 2;
	$compatible = 1;
	sleep 4;
	$compatible = "000";
	alarm 0;
    };
    if ($compatible > 0) {
	print STDERR "$compatible: sleep and alarm are ",
		"compatible on this system\n";
    } else {
	# either "alarm" isn't implemented, or
	# "alarm" or "sleep" are implemented in terms of each other,
	# and can't be used together
	#
	# does Perl v5.8 on Solaris suffer from this?
	print STDERR "sleep and alarm are *not* compatible on this system\n";
    }
    write_limits(sleep_alarm_compat => $compatible);
}

#
# determine the maximum number of simultaneous background processes
#
sub find_max_fork {
    my $N = shift;
    my $limits_file = $LIMITS{file};
    if (-f $limits_file) {
	unlink $limits_file;
    }

    print STDERR "";
    undef $@;
    my $r = eval {
	unlink "$limits_file.pid";
	for (my $i=0; $i<$N; $i++) {
	    undef $@;
	    my $pid;
	    eval { $pid = fork() };    # CORE::fork, not Forks::Super::fork
	    if ($@ || !defined $pid) {
		print STDERR "Cannot fork more than $i child processes.\n";
		1 while wait > -1;
		exit 0;
	    } elsif ($pid == 0) {
		print STDERR "";
		$0 = "system-limits.PL \&find_max_fork";
		sleep 10;
		exit 0;
	    }
	    if ($i > 1) {
		&write_limits('maxfork' => $i);
	    }
	}
	1 while wait > -1;

	if ($N < 2000) {
	    return find_max_fork(2000);
	}
	# print STDERR "$^O-$] successfully forked $N processes.\n";
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



    # we also want to get the error number for the
    # "Too many open files" and "No such file or directory"
    # error messages -- in a different locale we cannot
    # count on $! containing any particular text.

    my $i = 0;
    undef $!;
    my $j = $$;
    my @fh = ();
    while (open (my $fh, ">", "xxx.$j")) {
	$i++;
	push @fh, $fh;
    }
    my $err = 0 + $!;
    close $_ for @fh;
    # print STDERR "Msg for $i open files: $err\n";
    $! = $err;
    &write_limits('maxfilehandle' => $i,
		  'maxfilehandle_msg' => $!,
		  'maxfilehandle_errno' => $err);
    unlink "xxx.$j";
    print STDERR "Can open $i file handles simultaneously\n";

    #################################
    # also figure out the errno
    # for file not found.
    #################################

    $! = 0;
    open my $xh, '<', 'qwpor/qwer/qw/t/346/234/t';
    &write_limits('fnf_errno' => 0+$!,
		  'fnf_msg' => $!);

    return $i;
}

sub find_max_open_sockets {
    # TODO
}

# what values do CORE::wait and CORE::waitpid return
# for bogus inputs? What are the side effects on $? ?
sub wait_waitpid_results {
    use POSIX ':sys_wait_h';
    my %info = ();
    my $pid = CORE::fork();
    if (defined($pid) && $pid==0) {
	$0 = "system-limits.PL wait_waitpid_results";
	sleep 3;
	exit;
    }
    $info{active_waitpid_result} = waitpid $pid, &WNOHANG;
    $info{active_waitpid_status} = $?;

    # XXX - not idiot proof - $pid+1 could be a valid process identifier
    $info{bogus_waitpid_result} = waitpid $pid+1, &WNOHANG;
    $info{bogus_waitpid_status} = $?;

    waitpid $pid, 0;

    $info{reaped_waitpid_result} = waitpid $pid, &WNOHANG;
    $info{reaped_waitpid_status} = $?;

    local $SIG{CHLD} = 'IGNORE';
    $pid = CORE::fork();
    exit if $pid == 0;
    sleep 1;
    $info{ignore_waitpid_result} = waitpid $pid, 0;
    $info{ignore_waitpid_status} = $?;
    if ($info{ignore_waitpid_result} == $pid) {
	$info{ignore_waitpid_result} = 'undef';
	$info{ignore_waitpid_status} = 'undef';
    }

    write_limits( %info );
}

#
# what options are available to this system for interprocess synchronization?
#
sub explore_sync_options {
    my @sync = ();

    if ($^O eq 'MSWin32' || $^O =~ /cygwin/i) {
	if (eval { require Win32::Semaphore; 1 }) {
	    print STDERR "Win32 semaphores are available for ",
	    	"ipc synchronization\n";
	    push @sync, "Win32";
	    write_limits( sync_options => join('/', @sync) );
	}

	if (eval { require Win32::Mutex; 1 }) {
	    print STDERR "Win32 mutexes are available for ",
	    	"ipc synchronization\n";
	    push @sync, "Win32Mutex";
	    write_limits( sync_options => join('/', @sync) );
	}
    }

    if (eval {
	# exercise IPC::Semaphore
	require IPC::Sempahore;
	require IPC::SysC;
	IPC::SysV->import(qw(IPC_PRIVATE S_IRUSR S_IWUSR IPC_CREAT IPC_NOWAIT));
	my $sem = IPC::Semaphore->new(&IPC_PRIVATE, 2,
				      &S_IRUSR | &S_IWUSR | &IPC_CREAT);
	$sem->setall(1,0);
	$sem->setval(1,1);
	$sem->remove;
	eval { alarm 0 };
	1
	} ) {
	print STDERR "SysV semaphores are available for ipc synchornization\n";
	push @sync, "IPCSemaphore";
	write_limits( sync_options => join('/', @sync) );
    }
        
    # advisory file locking ? I expect this to work almost everywhere
    my $file = "foo.$$";
    if (fork() == 0) {
	open my $fh, ">>", $file;
	flock $fh, 2;
	sleep 5;
	close $fh;
	exit;
    }
    sleep 2;
    open my $fh, '>>', $file;
    my $t = time;
    eval { eval { alarm 30 }; flock $fh, 2; alarm 0; };
    $t = time - $t;
    close $fh;
    if ($t > 1 && $t < 20) {
	print STDERR "advisory filelocking available for ipc synchornization\n";
	push @sync, "Semaphlock";
	write_limits( sync_options => join('/', @sync) );
    }
    unlink $file;

    write_limits( sync_options => join('/', @sync) );
}

#
# try to guess how many processors this system has.
# Eventually we could use that information to set
# a default value of $Forks::Super::MAX_PROC in the
# installed code.
#
# See also: Sys::CpuAffinity getNumCpus() method
#           Forks::Super::Job::OS::get_number_of_processors() method
#
sub count_number_of_cpus {
    my ($ncpu, $fh);

    $ncpu = 0;
    if (eval "require Sys::CpuAffinity; 1") {
	$ncpu = Sys::CpuAffinity::getNumCpus();

	# darwin: result might have format "1 [2 cores]"
	$ncpu =~ s{\d+ \[(\d+) cores\]}{$1};
    }
    if ($ncpu == 0 && eval "require Test::Smoke::SysInfo;1") {
	my $sysinfo = Test::Smoke::SysInfo->new();
	$ncpu = $sysinfo && $sysinfo->{_ncpu};
    }

    if ($ncpu == 0 && $^O eq "MSWin32") {
	$ncpu = $ENV{NUMBER_OF_PROCESSORS};
    }
    if ($ncpu == 0 && open($fh,'<','/proc/cpuinfo')) {
	$ncpu = grep /^processor\s/, <$fh>;
	close $fh;
    }
    if ($ncpu == 0 && open($fh,'<','/proc/stat')) {
	$ncpu = grep /^cpu\d/i, <$fh>;
	close $fh;
    }
    if ($ncpu == 0) {
	$ncpu = grep /\d+.+processors?$/i, qx(hinv -c processor 2>/dev/null);
    }
    if ($ncpu == 0) {
	$ncpu = () = qx(bindprocessor -q 2>/dev/null);
    }
    if ($ncpu == 0) {
	$ncpu = grep /^hw.ncpu:/, qx(sysctl -a 2>/dev/null);
    }
    if ($ncpu == 0) {
	$ncpu = () = qx(psrinfo 2> /dev/null);
    }
    if ($ncpu == 0) {
	$ncpu = qx(hwprefs cpu_count 2>/dev/null);
    }

    if ($ncpu > 0) {
	print STDERR "There are $ncpu cpus on this system.\n";
	write_limits( ncpu => $ncpu + 0 );
    } else {
	print STDERR "I am having trouble detecting the number\n";
	print STDERR "of processors on your system. Consider\n";
	print STDERR "installing the  Sys::CpuAffinity  module\n";
	print STDERR "before running this script.\n";
	write_limits( ncpu => "1.0" );
    }
}

sub find_socket_capacity {
    my $socket_capacity = 
	_get_capacity(16384, 1,
		      qq[use Socket;
		         socketpair DUMMY,WRITER,AF_UNIX,SOCK_STREAM,PF_UNSPEC]);
    print STDERR "Default socket capacity is about $socket_capacity bytes\n";
    &write_limits('socket_capacity' => $socket_capacity);
}

sub find_pipe_capacity {
    my $pipe_capacity =
	_get_capacity(256, 2, qq[pipe DUMMY,WRITER]);
    print STDERR "Default pipe capacity is about $pipe_capacity bytes\n";
    &write_limits('pipe_capacity' => $pipe_capacity);
}

sub _get_capacity {
    my ($packetsize, $timeout, $create_WRITER) = @_;
    my $capacity = __get_capacity($packetsize,$timeout,$create_WRITER);
    while ($capacity <= 0) {
	if ($capacity > -2) {
	    return 0 if $packetsize <= 1;
	    print STDERR "Packet size of $packetsize was too large. Retrying\n";
	    $packetsize = int($packetsize / 64);
	} elsif ($capacity == -2) {
	    return 0 if $timeout > 300;
	    print STDERR "Capacity not found with timeout=$timeout. Retrying\n";
	    $timeout *= 2;
	}
	$capacity = __get_capacity($packetsize,$timeout,$create_WRITER);
    }
    return $capacity;
}

#####################################################################
# to find the capacity of a pipe or socket on this system,
# the idea is to keep writing bytes to the handle until it blocks.
# Windows is pretty cantankerous and it is hard to recover from the
# deadlock when a write operation blocks: the 4-arg select won't
# work with pipes (and it doesn't work that well with sockets,
# anyway), and alarm() won't interrupt an I/O operation.
# The portable solution is overkill on non-Windows systems but
# gets the job done -- test the socket in a separate process
# (NOT a psuedo-process/thread) and let the process kill itself
# when it times out.
#####################################################################
sub __get_capacity {
    my ($packetsize, $timeout, $create_WRITER, $output_file) = @_;
    $output_file ||= "./test-capacity.out";
    my $pid_file = "./test-capacity.pid";
    if ($packetsize < 1) {
	$packetsize = 1;
    }

    # capacity == -1  means the packetsize was too large: decrease packetsize
    # capacity == -2  means the pipe did not block: increase timeout
    my $capacity = -1;
    my $code = <<"__END_SLAVE_CODE__";
use IO::Handle;
use strict;
\$| = 1;
$create_WRITER;
*WRITER->autoflush(1);
binmode WRITER;
my \$output = " " x $packetsize;
my \$written = 0;
for (;;) {
 # print WRITER \$output;
 syswrite WRITER, \$output;
 \$written += length \$output;
 open F, ">", \"$output_file\";
 print F time - \$^T >= $timeout ? -2 : \$written;
 close F;
}
__END_SLAVE_CODE__
;

    unlink $output_file, $pid_file;
    if (fork() == 0) {
	$0 = "system-limits.PL __get_capacity";
	sleep $timeout + 1;
	open my $pf, '<', $pid_file;
	my $pid = 0 + <$pf>;

	# hopefully, one of these will do the job on your system
	kill ('TERM', $pid)
	    || kill ('HUP', $pid)
	    || !system ("TASKKILL /f /pid $pid")
	    || do {
		warn "Attempts to kill pid \"$pid\" failing ...\n"; 0
	}
	|| !system ("kill -TERM $pid") 
	    || kill ('BREAK', $pid);
	exit 0;
    }

    my $pid = open(SLAVE, "| $^X");

    open my $pf, '>', $pid_file;
    print $pf $pid;
    close $pf;

    print SLAVE $code;
    close SLAVE;

    sleep 1;
    open(CAP, '<', $output_file);
    $capacity = (<CAP>)[-1];
    close CAP;
    unlink $output_file, $pid_file;
    return $capacity + 0;
}
