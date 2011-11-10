use Forks::Super ':test';
use Test::More tests => 5;
use strict;
use warnings;

if (${^TAINT}) {
    $ENV{PATH} = "";
    ($^X) = $^X =~ /(.*)/;
    ($ENV{HOME}) = $ENV{HOME} =~ /(.*)/;

    # since v0.53 (daemon code) we call Cwd::abs_path or Cwd::getcwd and
    # the default IPC directory is tainted ...
    my $ipc_dir = Forks::Super::Job::Ipc::_choose_dedicated_dirname(".");
    if (! eval {$ipc_dir = Cwd::abs_path($ipc_dir)}) {
	$ipc_dir = Cwd::getcwd() . "/" . $ipc_dir;
    }
    ($ipc_dir) = $ipc_dir =~ /(.*)/;
    Forks::Super::Job::Ipc::set_ipc_dir($ipc_dir);
}


my ($pid,$out);
$ENV{XYZ} = "foo";
$pid = fork {
    child_fh => 'all',
    sub => sub { print $ENV{XYZ} },
#   env => { XYZ => 'bar' }
};
$pid->wait;
$out = $pid->read_stdout();

ok($ENV{XYZ} eq 'foo', "fork does not change parent environment");
ok($out eq 'foo', "child inherits parent environment");

$ENV{WXYZ} = 'quux';
$pid = fork {
    child_fh => 'all,block',
    sub => sub { eval { print $ENV{WXYZ}, $ENV{XYZ} } },
    env => { WXYZ => 'bar' }
};
ok(isValidPid($pid), "$$\\fork with env option launched");
ok($ENV{XYZ} eq 'foo' && $ENV{WXYZ} eq 'quux', 
   "fork does not change parent environment");

$pid->wait;
$out = $pid->read_stdout();
ok($out eq 'barfoo', "child respects env option")
    or diag("output was '$out', expected 'barfoo'");


