use Forks::Super ':test';
use Test::More tests => 8;
use IO::Handle;
use strict;
use warnings;

my $PID = $$;

END {
    if ($$ == $PID) {
	unlink glob("t/out/24e.$PID.*");
    }
}


sub write_test_file {
    my ($filename,$count) = @_;
    open my $fn, '>', $filename;
    $fn->autoflush(1);
    $SIG{INT} = $SIG{QUIT} = $SIG{TERM} = sub { 
	close $fn; 
	exit 10 
    };
    for (1..$count) {
	print $fn $_ x $_, "\n";
	sleep 1;
    }
    close $fn;
}

sub sizes {
    return (-s "t/out/24e.$PID.a",
	    -s "t/out/24e.$PID.b",
	    -s "t/out/24e.$PID.c");
}

my $pid = CORE::fork();
if ($pid == 0) {
    write_test_file("t/out/24e.$PID.a", 40);
    exit;
}
my $job = fork();
if ($job == 0) {
    write_test_file("t/out/24e.$PID.b", 40);
    exit;
}
my $j2 = fork { 
    sub => \&write_test_file, 
    args => [ "t/out/24e.$PID.c", 40 ] 
};

ok($pid != 0 && $job != 0 && $j2 != 0,
   "$PID\\launched 3 processes $pid $job $j2");

sleep 2;
my @s = sizes();
sleep 3;
my @t = sizes();

ok($t[2]>$s[2], "fork-to-sub job is active");
ok($t[1]>$s[1], "fork-to-natural job is active");
ok($t[0]>$s[0], "foreign job is active");

my @k = Forks::Super::kill('TERM', $pid, $job, $j2);
sleep 2;
my @u = sizes();
sleep 2;
my @v = sizes();


ok($v[2]==$u[2], "fork-to-sub was signalled");
ok($v[1]==$u[1], "fork-to-natural was signalled");
ok($v[0]==$u[0], "foreign job was signalled");


ok(@k == 3, "sent kill signal to 3 processes")
    or diag("signalled @k, expected 3 procs");

waitall;
