BEGIN { $Devel::Trace::TRACE = 0 };
use Forks::Super ':test';
use Test::More tests => 10;
use strict;
use warnings;

# can we set priority, cpu affinity on daemon jobs?
# do daemon jobs recognize names? delays? dependencies?

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
      skip "test $0 not for use with MSWin32", 10;
    }
    exit;
}

my $pid = fork { sub => sub { sleep 5 } };
my $base_priority = get_os_priority($pid);
my $np = Forks::Super::Config::CONFIG_module("Sys::CpuAffinity")
    ? Sys::CpuAffinity::getNumCpus() : 0;

print "base priority is $base_priority ...\n";

my $daemon = fork {
    sub => sub { sleep 5 },
    daemon => 1,
    os_priority => $base_priority + 1,
    cpu_affinity => $np > 1 ? 2 : 1
};
sleep 2; # give FS time to update priority
my $new_priority = get_os_priority($daemon);
ok($new_priority == $base_priority + 1,
   "set os priority on daemon process");

SKIP: {
    if ($np <= 1) {
	skip "one processor, can't test set CPU affinity", 1;
    }
    sleep 2; # give FS a couple seconds to update CPU affinity
    my $affinity = Sys::CpuAffinity::getAffinity($daemon);
    ok($affinity == 2, "set CPU affinity on daemon process");
}


my $t = Time::HiRes::time();
my $d1 = fork {
    daemon => 1,
    sub => sub { sleep 5 },
    delay => 3
};
ok($d1->{state} eq 'DEFERRED', 'daemon job was delayed');
for (1..5) {
    Forks::Super::pause(1) while $d1->{state} eq 'DEFERRED';
}
ok($d1->{state} ne 'DEFERRED', 'daemon job was started');
ok(!Forks::Super::Util::isValidPid($d1->{pid}),"pid is for deferred job");
ok(Forks::Super::Util::isValidPid($d1->{real_pid}),"real pid is valid");

my $n1 = fork {
    daemon => 0,
    sub => sub { 
        print time-$^T," DAEMON 1 MONITOR START\n";
	sleep 1 while CORE::kill 'ZERO', $d1->{real_pid};
        print time-$^T," DAEMON 1 MONITOR COMPLETE\n";
    },
    name => 'daemon1 monitor'
};
sleep 1;

$Devel::Trace::TRACE = 0;
my $d2 = fork {
    daemon => 1,
    name => 'daemon2',
    depend_on => 'daemon1 monitor',
    sub => sub { sleep 1 },
    on_busy => 'queue',
    debug => 0,
};

$Devel::Trace::TRACE = 0;

ok($d2->{state} eq 'DEFERRED', '2nd daemon is deferred');
Forks::Super::Util::pause(6);

ok($d1 && $d2, "daemon procs launched") or diag("d1=$d1, d2=$d2");
ok($d1->{start} > $t + 2, "daemon1 launch was delayed");
ok($d2->{start} >= $n1->{end}, "daemon2 launch waited for daemon1");


#############################################################################

sub get_os_priority {
    my ($pid) = @_;
    my $p;
    eval {
	$p = getpriority(0, $pid);
    };
    if ($@ eq '') {
	return $p;
    }

    if ($^O eq 'MSWin32') {
	#return Forks::Super::Job::OS::Win32::get_thread_priority($pid);
	return Forks::Super::Job::OS::Win32::get_priority($pid);
    }
    return;
}
