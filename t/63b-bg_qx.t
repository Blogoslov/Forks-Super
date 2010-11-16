use Forks::Super ':test';
use Test::More tests => 16;
use strict;
use warnings;

if (${^TAINT}) {
  $ENV{PATH} = "";
  ($^X) = $^X =~ /(.*)/;
}



### list context ###

my $t = Time::HiRes::time();
my @x = bg_qx "$^X t/external-command.pl -e=Hello -n -s=2 -e=World -n -s=2 -e=\"it is a\" -n -e=beautiful -n -e=day";
my @tests = @x;
$t = Time::HiRes::time() - $t;
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

SKIP: {

  if ($Forks::Super::SysInfo::SLEEP_ALARM_COMPATIBLE <= 0) {
    skip "alarm/sleep not compatible on this system, "
      . "can't use timeout with bg_qx", 4;
  }

  $t = Time::HiRes::time();
  @x = bg_qx "$^X t/external-command.pl -e=Hello -n -s=1 -e=World -s=12".
    " -n -e=\"it is a\" -n -e=beautiful -n -e=day", { timeout => 6 };
  @tests = @x;
  $t = Time::HiRes::time() - $t;
  ok($tests[0] eq "Hello \n", "list bg_qx first line ok");
  ok($tests[1] eq "World \n", "list bg_qx second line ok");    ### 30 ###
  ok(@tests == 2, "list bg_qx interrupted output had " 
	        . scalar @tests . "==2 lines");              ### 31 ###
  if (@tests>2) {
    print STDERR "output was:\n", @tests, "\n";
  }
  ok($t >= 5.5 && $t < 11.9,
	"list bg_qx took ${t}s expected ~6-8s");             ### 32 ###
}

sub hex_enc{join'', map {sprintf"%02x",ord} split//,shift} # for debug


__END__
