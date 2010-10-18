use Sys::CpuAffinity;
use Test::More tests => 1;
use strict qw(vars subs);
use warnings;
$| = 1;

#
# Exercise all of the methods in the toolbox to
# count processors on the system, get cpu affinity,
# and set cpu affinity. 
#
# Generally each tool is targeted to work on a
# single system. Since most of the tools are
# targeted at a different system than yours,
# most of these tools will fail on your system.
#
# Among the tools that are targeted to your
# system, some of them will depend on certain
# Perl modules or certain external programs
# being available, so those tools might also
# fail on your system.
#
# Hopefully, we'll find at least one tool for
# each task (count cpus, get affinity, set
# affinity) that will work for you. And that's
# all we need.
#

my ($pid,$wpid);

$wpid = $pid = $$;
if ($^O eq "cygwin") {
  $wpid = Sys::CpuAffinity::__pid_to_winpid($pid);
}

require "t/inventory.pl";

select STDERR;

EXERCISE_COUNT_NCPUS();

my $n = Sys::CpuAffinity::getNumCpus();
if ($n <= 1) {
 SKIP: {
    if ($n == 1) {
      skip "affinity exercise. Only one processor on this system", 1;
    } else {
      skip "affinity exercise. Can't detect number of processors", 1;
    }
  }
  exit 0;
}

EXERCISE_GET_AFFINITY();
EXERCISE_SET_AFFINITY();
ok(1);


sub EXERCISE_GET_AFFINITY {

    print "\n\n===============================================\n";

    print "Current affinity = \n";
    
    my $success = 0;
    for my $s (inventory::getAffinity()) {
	my $sub = 'Sys::CpuAffinity::_getAffinity_with_' . $s;
	printf "    %-25s ==> ", $s;
	my $z = $s =~ /Win32/ ? eval { $sub->($wpid) } 
	                      : eval { $sub->($pid) };
	printf "%d\n", $z || 0;
	$success += $z > 0;
    }

    if ($success == 0) {
      recommend($^O, 'getAffinity');
    }
}

sub EXERCISE_COUNT_NCPUS {

    print "\n\n=================================================\n";

    print "Num processors =\n";

    for my $technique (inventory::getNumCpus()) {
	my $s = 'Sys::CpuAffinity::_getNumCpus_from_' . $technique;
	printf "    %-25s ", $technique;
	printf "- %d -\n", eval { $s->() } || 0;
    }

}

sub EXERCISE_SET_AFFINITY {

    print "\n\n==================================================\n";


    my $np = Sys::CpuAffinity::getNumCpus();
    return 0 if $np <= 1;

    my ($TARGET,$LAST_TARGET) = (0,0);
    my @mask = ();
    while (@mask < 500) {
	$TARGET = int(rand() * (2**$np - 1)) + 1
	    while $TARGET == $LAST_TARGET;
	$LAST_TARGET = $TARGET;
	push @mask, $TARGET;
    }

    # print "@mask\n";
    my $success = 0;

    print "Set affinity =\n";

    for my $technique (inventory::setAffinity()) {
	my $rr = Sys::CpuAffinity::getAffinity($pid);
	my $mask;
	do {
	    $mask = shift @mask;
	} while $mask == $rr;

	my $s = "Sys::CpuAffinity::_setAffinity_with_$technique";
	if ($technique =~ /Win32/) {
	    eval { $s->($wpid,$mask) };
	} else {
	    eval { $s->($pid,$mask) };
	}
	printf "    %-25s => %3u ==> ", $technique, $mask;
	my $r = Sys::CpuAffinity::getAffinity($pid);
	my $result = $r==$rr ? "FAIL" : " ok ";
	if ($r != $rr) {
	  $success++;
	}
	printf "%3u   [%s]\n", $r, $result;
    }

    if ($success == 0) {
      recommend($^O, 'setAffinity');
    }
}

sub recommend {
  use Config;

  my ($sys, $function) = @_;

  print "\n\n==========================================\n\n";
  print "The function 'Sys::CpuAffinity::$function' does\n";
  print "not seem to work on this system.\n\n";

  my @recommendations = ("a C complier");
  if ($Config{"cc"}) {
    push @recommendations, "\t(preferrably $Config{cc})";
  }

  if ($sys eq 'cygwin') {
    push @recommendations, "the  Win32  module";
    push @recommendations, "the  Win32::API  module";
    push @recommendations, "the  Win32::Process  module";
  } elsif ($sys eq 'MSWin32') {
    push @recommendations, "the  Win32  module";
    push @recommendations, "the  Win32::API  module";
    push @recommendations, "the  Win32::Process  module";
  } elsif ($sys =~ /bsd/i) {
    push @recommendations, "the  BSD::Process::Affinity  module";
    push @recommendations, "make sure the  cpuset  program is in the PATH";
  } elsif ($sys =~ /solaris/i) {
    push @recommendations, "make sure the  pbind  program is in the PATH";
  } elsif ($sys =~ /irix/i) {
    # still need to learn to use the  cpuset_XXX  functions
  } elsif ($sys =~ /darwin/i || $sys =~ /MacOS/i) {
    @recommendations = ();
    print "The Mac OS does not provide (as far as I can tell)\n";
    print "a way to manipulate the CPU affinities of processes.\n";
    print "\n\n==========================================\n\n\n";
    return;
  } elsif ($sys =~ /aix/i) {
    push @recommendations, 
      "make sure the  bindprocessor  program is in the PATH";
  } else {
    push @recommendations, 
      "don't know what else to recommend for system $sys";
  }

  if (@recommendations > 0) {
    print "To make this module work, you may want to install:\n\n";
    foreach (@recommendations) {
      print "\t$_\n";
    }
    print "\n\n";
    print "If these recommendations do not help, drop a note\n";
    print "to mob\@cpan.org with details about your\n";
    print "system configuration.\n";
  }

  print "\n\n==========================================\n\n\n";
}


