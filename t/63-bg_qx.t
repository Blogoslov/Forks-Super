use Forks::Super ':test';
use Test::More tests => 23;
use strict;
use warnings;

my $t = Time();
my $z = sprintf "%05d", 100000 * rand();
my $x = bg_qx "$^X t/external-command.pl -e=$z -s=3";
$t = Time();
ok($$x eq "$z \n", "scalar bg_qx");
$t = Time() - $t;
my $y = $$x;
ok($y == $z, "scalar bg_eval");
ok($t >= 2.95, "scalar bg_qx took ${t}s expected ~3s");
$$x = 19;
ok($$x == 19, "result is not read only");

### interrupted bg_qx, scalar context ###

$y = "";
$z = sprintf "B%05d", 100000 * rand();
my $x2 = bg_qx "$^X -d:Trace t/external-command.pl -s=8 -e=$z 2>/tmp/qqq", timeout => 2;
#my $x2 = bg_qx "$^X t/external-command.pl -s=8 -e=$z", timeout => 2;
$t = Time();
$y = $$x2;

# if (!defined $y) { print "\$y,\$\$x is: <undef>\n"; } else { print "\$y,\$\$x is: \"$y\"\n"; }

#-- intermittent failure here: --#
ok((!defined $y) || $y eq "" || $y eq "\n", "scalar bg_qx empty on failure");
if (defined $y && $y ne "" && $y ne "\n") {
	print STDERR "Fail on test 5: \$y: ", hex_enc($y), "\n";
	print STDERR `cat /tmp/qqq`;
}
$t = Time() - $t;
ok($t <= 3, "scalar bg_qx respected timeout, took ${t}s expected ~2s");

### interrupted bg_qx, capture existing output ###

$z = sprintf "C%05d", 100000 * rand();
$x = bg_qx "$^X t/external-command.pl -e=$z -s=4", timeout => 2;
$t = Time();
ok($$x eq "$z \n" || $$x eq "$z ", "scalar bg_qx failed but retrieved output");
$t = Time() - $t;
ok($t <= 3, "scalar bg_qx respected timeout, took ${t}s expected ~2s");

### list context ###

$t = Time();
my @x = bg_qx "$^X t/external-command.pl -e=Hello -n -s=2 -e=World -n -s=2 -e=\"it is a\" -n -e=beautiful -n -e=day";
my @tests = @x;
$t = Time() - $t;
ok($tests[0] eq "Hello \n" && $tests[1] eq "World \n", "list bg_qx");
ok(@tests == 5, "list bg_qx");
ok($t >= 3.95, "list bg_qx took ${t}s expected ~4s");

# exercise array operations on the tie'd @x variable to make sure
# we implemented everything correctly 

my $n = @x;
my $u = shift @x;
ok($u eq "Hello \n" && @x == $n - 1, "list bg_qx shift");
$u = pop @x;
ok(@x == $n - 2 && $u =~ /day/, "list bg_qx pop");
unshift @x, "asdf";
ok(@x == $n - 1, "list bg_qx unshift");
push @x, "qwer", "tyuiop";
ok(@x == $n + 1, "list bg_qx push");
splice @x, 3, 3, "pq";
ok(@x == $n - 1 && $x[3] eq "pq", "list bg_qx splice");
$x[3] = "rst";
ok(@x == $n - 1 && $x[3] eq "rst", "list bg_qx store");
ok($x[2] =~ /it is a/, "list bg_qx fetch");
delete $x[4];
ok(!defined $x[4], "list bg_qx delete");
@x = ();
ok(@x == 0, "list bg_qx clear");

### partial output ###

$t = Time();
@x = bg_qx "$^X t/external-command.pl -e=Hello -n -s=2 -e=World -s=3 -n -e=\"it is a\" -n -e=beautiful -n -e=day", { timeout => 3 };
@tests = @x;
$t = Time() - $t;
ok($tests[0] eq "Hello \n" && $tests[1] eq "World \n", "list bg_qx");
ok(@tests == 2, "list bg_qx interrupted output had " . scalar @tests . " lines");
ok($t >= 2.95 && $t < 4.05, "list bg_qx took ${t}s expected ~3s");
waitall;

1 while CORE::wait > -1;

$Forks::Super::DONT_CLEANUP = -1 if $^O eq "MSWin32";

sub hex_enc{join'', map{sprintf"%02x",ord}split//,shift} # for debug

__END__

exit 0;

### test variery of %options ###

$$x = 20;
my $w = 14;
$x = bg_eval {
  sleep 5; return 19
} { name => 'bg_qx_job', delay => 3, on_busy => "queue",
      callback => { queue => sub { $w++ }, start => sub { $w+=2 },
		    finish => sub { $w+=5 } }
};
$t = Time();
my $j = Forks::Super::Job::get('bg_qx_job');
ok($j->{state} eq "DEFERRED", "bg_qx with delay");
ok($w == 14 + 1, "bg_qx job queue callback");
Forks::Super::pause(4);
ok($j->{state} eq "ACTIVE", "bg_qx job left queue " . $j->toString());
ok($w == 14 + 1 + 2, "bg_qx start callback");
ok($$x == 19, "scalar bg_qx with lots of options");
$t = Time() - $t;
ok($t > 7.85, "bg_qx with delay took ${t}s, expected ~8s");
ok($w == 14 + 1 + 2 + 5, "bg_qx finish callback");


