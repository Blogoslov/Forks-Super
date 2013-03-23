use Forks::Super ':test', MAX_PROC => 5, ON_BUSY => 'queue';
use Test::More tests => 5;
use strict;
use warnings;

# as of v0.30, the kill and kill_all functions are not very well speced out.
# these tests should pass in the current incarnation, though.

if (${^TAINT}) {
    require Cwd;

    $ENV{PATH} = '';
    ($^X) = $^X =~ /(.*)/;

    my $ipc_dir = Forks::Super::Job::Ipc::_choose_dedicated_dirname();
    if (! eval {$ipc_dir = Cwd::abs_path($ipc_dir)}) {
	$ipc_dir = Cwd::getcwd() . "/" . $ipc_dir;
    }
    ($ipc_dir) = $ipc_dir =~ /(.*)/;
    Forks::Super::Job::Ipc::set_ipc_dir($ipc_dir);
}

our $INT = $^O eq 'cygwin' ? 'TERM' : 'INT';

SKIP: {
    if ($^O eq "MSWin32" && !Forks::Super::Config::CONFIG("Win32::API")) {
	skip "kill is unsafe on MSWin32 without Win32::API", 5;
    }


    # kill on <xxx>deferred jobs</xxx>

    my $pid1 = fork { sub => sub { sleep 5 } };
    my $pid2 = fork { sub => sub { sleep 5 } };
    my $pid3 = fork { sub => sub { sleep 5 }, depend_on => $pid1 };
    my $j1 = Forks::Super::Job::get($pid1);
    sleep 1;

    #my $zero = Forks::Super::kill('ZERO', $pid1, $pid2, $pid3);
    my $zero = 4*!!Forks::Super::kill('ZERO',$pid1)
	+ 2*!!Forks::Super::kill('ZERO',$pid2)
	+ !!Forks::Super::kill('ZERO',$pid3);
    ok($zero==7, "SIGZERO successfully sent to 2 active and 1 deferred proc")
	or diag("result was $zero, expected 4(a)+2(a)+1(d)");

    # failure point on MSWin32 - terminates the script
    if ($^O eq 'MSWin32') {
	diag("Sending SIG$INT to $pid1");
    }
    my $y = Forks::Super::kill($INT, $pid1);
    sleep 2;
    Forks::Super::Queue::run_queue();
    ok($y == 1, "sent SUG$INT to $y==1 proc active job");

    $zero = Forks::Super::kill('ZERO', $pid1, $pid2, $pid3);
    ok($zero==2, "SIGZERO successfully sent to 2 processes")
	or diag("sent to $zero procs, expected 2");

    # (fails under forked_harness, but passes as standalone?)
    ok($j1->is_complete, 
       "killed active job is complete " . $j1->{state}); ### 7 ###
    waitall;

    $y = Forks::Super::kill($INT, $pid1, $pid2, $pid3);
    ok($y == 0, "kill to complete jobs returns 0");

}
