use Forks::Super ':test';
use Test::More tests => 8;
use Cwd;
use strict;
use warnings;

# does a "daemon" process act like a daemon process?
#    no parent ppid?
#    daemon process can survive when the process that spawned it dies
#

our $CWD = &Cwd::getcwd;
if (${^TAINT}) {
  my $ipc_dir = Forks::Super::Job::Ipc::_choose_dedicated_dirname();
  if (! eval {$ipc_dir = Cwd::abs_path($ipc_dir)}) {
      $ipc_dir = Cwd::getcwd() . "/" . $ipc_dir;
  }
  ($ipc_dir) = $ipc_dir =~ /(.*)/;
  Forks::Super::Job::Ipc::set_ipc_dir($ipc_dir);
  ($CWD) = $CWD =~ /(.*)/;
  ($^X) = $^X =~ /(.*)/;
  $ENV{PATH}='';
}

# need a separate test for MSWin32
if ($^O eq 'MSWin32') {
  SKIP: {
      skip "test $0 not for use with MSWin32", 8;
    }
    exit;
}

# procedure?
#
#    start a child with CORE::fork
#    in the child:
#        launch a daemon with F::S::fork
#           the daemon should live for a while and produce some output
#        print out the child pid and the daemon pid
#        exit
#    wait for the child
#    verify that the child is gone
#    verify that the daemon exists
#    verify that only some of the daemon output exists
#    wait a little more
#    verify more daemon output exists, which proves that the daemon is alive
#    kill the daemon

my $child_output = "$CWD/t/out/daemon-parent.$$.out";
my $daemon_output = "$CWD/t/out/daemon.$$.out";

unlink $child_output, $daemon_output;

my $child_pid = CORE::fork();
if ($child_pid == 0) {

    open my $c, '>', $child_output;
    print $c "Child pid is $$\n";

    my $daemon = fork {
	    sub => sub {
		open my $d, '>', $daemon_output;
		select $d;
		$| = 1;
		print "$$\n";
		sleep 3;
		my $ppid = eval { getppid() } || 'unknown';
		print "$ppid\n";
		for (3 .. 15) {
		    print " $_" x $_, "\n";
		    sleep 1;
		}
		close $d;
	    },
	    daemon => 1,
    };

    print $c "Daemon pid is $daemon\n";
    print $c "Daemon output is $daemon_output\n";
    close $c;
    exit;
}

my $t = Time::HiRes::time;
my $wait = CORE::wait;
$t = Time::HiRes::time - $t;
my $fail = 0;

ok($t < 3.0, "child process finished quickly ${t}s, expected fast");  ### 1 ###
ok($wait == $child_pid, "CORE::wait captured child process");

sleep 3;
my $s1 = -s $daemon_output;

ok(-f $daemon_output, "daemon process created output file  size=$s1");
sleep 5;

my $s2 = -s $daemon_output;
ok($s1 < $s2, "daemon process still alive after child is gone $s1 => $s2");

open my $dh, '<', $daemon_output;
my $dpid = 0 + <$dh>;
my $dppid = <$dh>;
close $dh;

ok($dppid == 1 || $dppid eq "unknown\n" || $dppid eq "unknown$/",
   "daemon process does not have a parent");

if (${^TAINT}) {
    ($dpid) = $dpid =~ /([-\d]*)/;
}

my $nk = CORE::kill 'TERM', $dpid;
ok($nk == 1, "daemon process $dpid was signalled");
sleep 2;
my $s3 = -s $daemon_output;
sleep 3;
my $s4 = -s $daemon_output;
ok($s3 == $s4, "daemon is not still running");

open $dh, '<', $daemon_output;
my @daemon_output = <$dh>;
close $dh;

ok($daemon_output[-1] !~ /12/ && $daemon_output[-2] !~ /12/,
   "daemon was successfully killed");

unlink $child_output, $daemon_output;
