use Forks::Super ':test';
use Test::More tests => 27;
use strict;
use warnings;

### scalar context ###
#
# result is a tie'd scalar, so exercise fetch/store
#

my $t = Time();
my $x = bg_eval { sleep 3 ; return 42 };
$t = Time();
ok($$x == 42, "scalar bg_eval");
$t = Time() - $t;
my $y = $$x;
ok($y == 42, "scalar bg_eval");
ok($t >= 2.95, "scalar bg_eval took ${t}s expected ~3s");
$$x = 19;
ok($$x == 19, "result is not read only");

$x = bg_eval { sleep 4; return 19 } { timeout => 2 };
$t = Time();
ok(!defined $$x, "scalar bg_eval undef on failure");
$t = Time() - $t;
ok($t <= 3, "scalar bg_eval respected timeout, took ${t}s expected ~2s");

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
ok($t >= 1.95, "list bg_eval took ${t}s expected ~2s");

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

$x = bg_eval {
  sleep 2;
  opendir(X, "t");
  my @f = grep { !/\.t$/ } readdir(X);
  closedir X;
  return \@f;
};
$t = Time();
my @others = @$$x;
$t = Time() - $t;
ok($t >= 1.85, "listref bg_eval took ${t}s expected ~2s");
ok(@others > 0, "listref bg_eval");
$$x = [ "a", "v", "rst" ];
ok(@$$x == 3, "listref bg_eval overwrite ok");
waitall;

### test variery of %options ###

$$x = 20;
my $w = 14;
$x = bg_eval {
  sleep 5; return 19
} { name => 'bg_eval_job', delay => 3, on_busy => "queue",
      callback => { queue => sub { $w++ }, start => sub { $w+=2 },
		    finish => sub { $w+=5 } }
};
$t = Time();
my $j = Forks::Super::Job::get('bg_eval_job');
ok($j->{state} eq "DEFERRED", "bg_eval with delay");
ok($w == 14 + 1, "bg_eval job queue callback");
Forks::Super::pause(4);
ok($j->{state} eq "ACTIVE", "bg_eval job left queue " . $j->toString());
ok($w == 14 + 1 + 2, "bg_eval start callback");
ok($$x == 19, "scalar bg_eval with lots of options");
$t = Time() - $t;
ok($t > 7.85, "bg_eval with delay took ${t}s, expected ~8s");
ok($w == 14 + 1 + 2 + 5, "bg_eval finish callback");
