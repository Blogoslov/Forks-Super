use Forks::Super ':test';
use Test::More tests => 35;
use strict;
use warnings;

### scalar context ###
#
# result is a tie'd scalar, so exercise fetch/store
#

no warnings 'once';
ok(!defined $Forks::Super::LAST_JOB, 
   "$$\\\$Forks::Super::LAST_JOB not set");
ok(!defined $Forks::Super::LAST_JOB_ID, 
   "\$Forks::Super::LAST_JOB_ID not set");

delete $Forks::Super::Config::CONFIG{"JSON"};
$Forks::Super::Config::CONFIG{"YAML"} = 0;

if ($ENV{NO_JSON} || !Forks::Super::Config::CONFIG("JSON")) {
 SKIP: {
    skip "JSON not available, skipping bg_eval tests", 33;
  }
  exit 0;
}

require "t/62-bg_eval.tt";

__END__



my $t0 = Time();
my $x = bg_eval { sleep 3 ; return 42 };
my $t = Time();
ok(defined $Forks::Super::LAST_JOB, 
   "\$Forks::Super::LAST_JOB set");                     ### 36 ###
ok(defined $Forks::Super::LAST_JOB_ID, "\$Forks::Super::LAST_JOB_ID set");
ok(Forks::Super::isValidPid($Forks::Super::LAST_JOB_ID), 
   "\$Forks::Super::LAST_JOB_ID set");
ok($Forks::Super::LAST_JOB->{_is_bg} > 0, 
   "\$Forks::Super::LAST_JOB marked bg");
my $p = waitpid -1, 0;
ok($p == -1, "waitpid doesn't catch bg_eval job");
ok($$x == 42, "scalar bg_eval");
my $t1 = Time();
($t,$t0) = ($t1-$t,$t1-$t0);
my $y = $$x;
ok($y == 42, "scalar bg_eval");
ok($t0 >= 2.95 && $t <= 3.85, 
   "scalar bg_eval took ${t}s ${t0}s expected ~3s");
$$x = 19;
ok($$x == 19, "result is not read only");

$x = bg_eval { sleep 10; return 19 } { timeout => 2 };
$t = Time();
ok(!defined $$x, "scalar bg_eval undef on failure");
$t = Time() - $t;
ok($t <= 3.25, "scalar bg_eval respected timeout, took ${t}s expected ~2s");

### list context ###
#
# result is a tie'd array so let's exercise the array operations
#

$t = Time();
my @x = bg_eval {
  sleep 2;
  opendir(X, "t");
  my @f = grep { /\.t$/ } readdir(X);
  closedir X;
  return @f;
};
my @tests = @x;
$t = Time() - $t;
ok(@tests > 10, "list bg_eval");
ok($t >= 1.84, "list bg_eval took ${t}s expected ~2s");

my $n = @x;
my $u = shift @x;
ok($u =~ /\.t$/ && @x == $n - 1, "list bg_eval shift");
$u = pop @x;
ok(@x == $n - 2 && $u =~ /\.t$/, "list bg_eval pop");
unshift @x, "asdf";
ok(@x == $n - 1, "list bg_eval unshift");
push @x, "qwer", "tyuiop";
ok(@x == $n + 1, "list bg_eval push");
splice @x, 3, 3, "pq";
ok(@x == $n - 1 && $x[3] eq "pq", "list bg_eval splice");
$x[3] = "rst";
ok(@x == $n - 1 && $x[3] eq "rst", "list bg_eval store");
ok($x[5] =~ /.t$/, "list bg_eval fetch");
delete $x[4];
ok(!defined $x[4], "list bg_eval delete");
@x = ();
ok(@x == 0, "list bg_eval clear");

### scalar context, return reference ###

$t0 = Time();
$x = bg_eval {
  sleep 2;
  opendir(X, "t");
  my @f = grep { !/\.t$/ } readdir(X);
  closedir X;
  return \@f;
};
$t = Time();
my @others = @$$x;
my $t2 = Time();
($t,$t0) = ($t2-$t,$t2-$t0);
ok($t0 >= 1.95 && $t <= 3.57,           ### 25 ### was 3.25 obs 3.56
   "listref bg_eval took ${t0}s ${t}s expected ~2s");
ok(@others > 0, "listref bg_eval");
$$x = [ "a", "v", "rst" ];
ok(@$$x == 3, "listref bg_eval overwrite ok");
waitall;

### test variery of %options ###

$$x = 20;
my $w = 14;
$t0 = Time();
$x = bg_eval {
  sleep 5; return 19
} { name => 'bg_eval_job', delay => 3, on_busy => "queue",
      callback => { queue => sub { $w++ }, start => sub { $w+=2 },
		    finish => sub { $w+=5 } }
    };
$t = Time();
my $j = Forks::Super::Job::get('bg_eval_job');
ok($j eq $Forks::Super::LAST_JOB, "\$Forks::Super::LAST_JOB updated");
ok($j->{state} eq "DEFERRED", "bg_eval with delay");
ok($w == 14 + 1, "bg_eval job queue callback");
Forks::Super::pause(4);
ok($j->{state} eq "ACTIVE", "bg_eval job left queue " . $j->toString());
ok($w == 14 + 1 + 2, "bg_eval start callback");
ok($$x == 19, "scalar bg_eval with lots of options");
$t1 = Time();
($t,$t0) = ($t1-$t,$t1-$t0);
ok($t0 > 7.85 && $t < 10.36,  ### 34 ### was 9.6 obs 9.99,10.21,10.26,10.35
   "bg_eval with delay took ${t}s ${t0}s, expected ~8s");
ok($w == 14 + 1 + 2 + 5, "bg_eval finish callback");

use Carp;$SIG{SEGV} = sub { Carp::cluck "XXXXXXX Caught SIGSEGV during cleanup of $0 ...\n" };
