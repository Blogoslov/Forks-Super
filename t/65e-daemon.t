use Forks::Super ':test';
use Test::More tests => 3;
use Cwd;
use Carp;
use strict;
use warnings;

our $CWD = Cwd::getcwd;
my $output = "$CWD/t/out/daemon4.$$.out";

# does daemon respect a timeout option

my $pid = fork {
     env => { LOG_FILE => $output, VALUE => 30 },
     name => 'daemon4',
     daemon => 1,
     cmd => [ $^X, "$CWD/t/external-daemon.pl" ],
     timeout => 4
};
ok(isValidPid($pid), "fork to cmd with daemon & timeout");
my $k = Forks::Super::kill 'ZERO', $pid;
sleep 2;
ok($k, "daemon proc is alive");
sleep 6;
$k = Forks::Super::kill 'ZERO', $pid;

ok(!$k, "daemon proc timed out in <= 8s");

unlink $output unless $ENV{KEEP};

__END__

tests on a daemon process:

    if we can inspect process table, note that daemon is not a child process
                                     note that daemon has no parent

    file-based IPC works
    job status =~ /DAEMON/
    cannot wait on a daemon process
    natural, to sub, to cmd

    how to test that the daemon lives on past the end of the program?
