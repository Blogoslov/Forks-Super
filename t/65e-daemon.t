use Forks::Super ':test';
use Test::More tests => 3;
use Cwd;
use Carp;
use strict;
use warnings;

our $CWD = Cwd::getcwd;

if (${^TAINT}) {
    $ENV{KEEP} ||= 0;
    ($ENV{KEEP}) = $ENV{KEEP} =~ /(.*)/;
    ($CWD) = $CWD =~ /(.*)/;
    $ENV{PATH} = '';
    ($^X) = $^X =~ /(.*)/;
}

my $output = "$CWD/t/out/daemon4.$$.out";

# does daemon respect a timeout option
my $pid = fork {
     env => { LOG_FILE => $output, VALUE => 30 },
     name => 'daemon4',
     daemon => 1,
     cmd => [ $^X, "$CWD/t/external-daemon.pl" ],
     timeout => 4,
};
ok(isValidPid($pid), "fork to cmd with daemon & timeout");
my $k = Forks::Super::kill 'ZERO', $pid;
sleep 2;
ok($k, "($k) daemon proc is alive");
sleep 6;
$k = Forks::Super::kill 'ZERO', $pid;
ok(!$k, "($k) daemon proc timed out in <= 8s");
if ($k) {
   for (1..5) {
       sleep 1;
       $k = Forks::Super::kill 'ZERO',$pid;
       if (!$k) {
           diag "daemon proc timed out after additional $_ s";
	   last;
       }
   }  
}

unlink $output unless $ENV{KEEP};

