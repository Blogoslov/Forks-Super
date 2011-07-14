# exercise Forks::Super::Util package

use Forks::Super::Util;
use Test::More tests => 27;
use strict;
use warnings;

ok(Forks::Super::Util::is_number("1234"), 'is_number #1');
ok(Forks::Super::Util::is_number("-1234"), 'is_number #2');
ok(Forks::Super::Util::is_number("14.56"), 'is_number #3');
ok(!Forks::Super::Util::is_number("14.56ff"), 'is_number #4');
ok(!Forks::Super::Util::is_number("blech"), 'is_number #5');
ok(Forks::Super::Util::is_number("-4.3E-0003"), 'is_number #6');

my $THR_avail = $Forks::Super::Util::Time_HiRes_avail;
my $T = Time::HiRes::time();
ok($T > $^T, "Util::Time() $T vs $^T");
# I hope it doesn't take 10s to get here
ok($T < $^T + 10.0, "Util::Time() $T vs $^T");

ok(Forks::Super::Util::isValidPid("5000"), 'isValidPid #1');
ok(!Forks::Super::Util::isValidPid("-1"), 'isValidPid #2');
ok(!Forks::Super::Util::isValidPid("0"), 'isValidPid #3');
ok(!Forks::Super::Util::isValidPid("word"), 'isValidPid #4');
ok(!Forks::Super::Util::isValidPid("-999999"), 'isValidPid #5');
ok(Forks::Super::Util::isValidPid("-404") ^ ($^O ne 'MSWin32'), 'isValidPid #6');

my $Ct = Forks::Super::Util::Ctime();
ok(length($Ct) == 2+2+2+3+3+2, "Ctime: $Ct");

my ($t1,$t2) = (time, scalar Time::HiRes::time());
my $t3 = Forks::Super::Util::pause();
($t1,$t2) = (time - $t1, Time::HiRes::time() - $t2);
ok($t1 <= 1 && abs($t1-$t2) < 1, 'pause #1');
ok($THR_avail ? $t2 >= 0.1 && $t2 <= 1.05 : $t2 <= 1, "pause #2 $t1/$t2"); ### 17 ###
ok(abs($t2-$t3) <= 1, 'pause #3');

$Forks::Super::Util::DEFAULT_PAUSE = 0.1;
($t1,$t2) = (time, scalar Time::HiRes::time());
$t3 = Forks::Super::Util::pause(3.8);
$t1 = time - $t1;
$t2 = Time::HiRes::time() - $t2;
ok($t1 <= 4 && abs($t1-$t2) < 1, 'pause #4');                      ### 19 ###
ok($THR_avail ? $t2 >= 3.75 && $t2 <= 4.25 : $t2 >= 3 && $t2 <= 5, ### 20 ###
   "pause #5 $t1/$t2");
ok(abs($t2-$t3) <= 1, 'pause #6');

$Forks::Super::Util::DEFAULT_PAUSE = 2.5;
($t1,$t2) = (time, scalar Time::HiRes::time());
$t3 = Forks::Super::Util::pause();
$t1 = time - $t1;
$t2 = Time::HiRes::time() - $t2;
ok($t1 <= 3 && abs($t1-$t2) < 1, "pause #7 $t1/$t2"); ### 22 ###
ok($THR_avail ? $t2 >= 2.43 && $t2 <= 3.95 
	      : $t2 >= 2 && $t2 <= 4, "pause #8 $t1/$t2"); ### 23 ###
ok(abs($t2-$t3) <= 1, 'pause #9');

my $w = 1;
my $x = 1;
Forks::Super::Util::set_productive_pause_code { $w = 4 };
Forks::Super::Util::pause(0.25);
ok($w == 4, 'set_productive_pause_code #1');
Forks::Super::Util::set_productive_pause_code { $w++; $x++ };
Forks::Super::Util::pause(0.25);
ok($w > 4, 'set_productive_pause_code #2');
$x = 1;
$w = 4;
Forks::Super::Util::set_other_productive_pause_code { $w = 0 };
Forks::Super::Util::pause(0.25);
ok($w == 0 && $x > 1, 'set_other_productive_pause_code');
