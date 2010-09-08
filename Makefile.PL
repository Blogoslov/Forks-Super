use strict;
use warnings;
use ExtUtils::MakeMaker;
use 5.007003;   # needs "safe signals" - see perlipc

# command-line arguments "bundle=1" or "reinstall=1"
# or environment var     "BUNDLE_REINSTALL=1"
# will force attempt to install bundled modules,
# even if they are already installed



# run installer for the additional modules
# that were included with this distribution.
#
# run  perl Makefile.PL BUNDLE=1
# or   BUNDLE_REINSTALL=1 perl Makefile.PL
# to allow re-installation of bundled modules
sub install_bundled_modules {
  if (-d 'bundle') {
    chdir 'bundle';
    opendir my $sub_dh, '.';
    while (my $submod = readdir $sub_dh) {
      next if $submod eq '.';
      next if $submod eq '..';
      next if ! -d $submod;

      if (-f "$submod/bundle.pl") {
	print "--------------------------------------------------\n";
	print "Running builder for submodules/$submod\n";
	chdir $submod;
	system($^X,'bundle.pl',@ARGV);
	chdir '..';
      }
    }
    print "--------------------------------------------------\n";
    closedir $sub_dh;
    chdir '..';
  }
}

sub probe_system {
  print STDERR "Gathering information on current system $^O.$]\n";
  print STDERR "and creating Forks::Super::SysInfo package.\n";
  system($^X, 'SysInfo.pm.PL', 'lib/Forks/Super/SysInfo.pm');
}

# Construct %REQUIRED, %RECOMMENDED. We currently don't use %RECOMMENDED.
our %RECOMMENDED
  = ('YAML' => '0.62',
     'JSON' => '2.0',
     'Sys::CpuAffinity' => '0.91',
     'Sys::CpuLoadX' => '0.02',
     'DateTime::Format::Natural' => '0.89');
our %REQUIRED = ('Test::More' => '0',
		'Time::HiRes' => '1.30');

if ($^O eq "MSWin32" || $^O =~ /cygwin/i) {
  $RECOMMENDED{'Win32::Process'} = '0.11';
  $RECOMMENDED{'Win32::API'} = '0.43';
  if ($^O eq "MSWin32") {
    $RECOMMENDED{'Win32::Process::Kill'} = '2.64';
    $REQUIRED{'Win32::API'} = '0.43';
  }
}

######################################################################

if (" @ARGV " =~ / bundle\b/i || " @ARGV " =~ / reinstall\b/i) {
  $ENV{BUNDLE_REINSTALL} = 1;
  @ARGV = grep { !/^bundle\b/i && !/^reinstall\b/ } @ARGV;
}

# install bundled modules first so Sys::CpuAffinity is avail to system-limits.PL
install_bundled_modules();
probe_system();
WriteMakefile(
    ($ExtUtils::MakeMaker::VERSION+0 >= 6.46
         ? ('META_MERGE' => { 'recommends' => \%RECOMMENDED })
	 : ()),
    NAME                => 'Forks::Super',
    AUTHOR              => q[Marty O'Brien <mob@cpan.org>],
    VERSION_FROM        => 'lib/Forks/Super.pm',
    ABSTRACT_FROM       => 'lib/Forks/Super.pm',
    ($ExtUtils::MakeMaker::VERSION+0 >= 6.3002
      ? ('LICENSE'=> 'perl')
      : ()),
    PL_FILES            => {},

    PREREQ_PM => \%REQUIRED,

    dist                => { COMPRESS => 'gzip -9f', SUFFIX => 'gz', },
    clean               => { FILES => join (" ",'Forks-Super-*',
					    'system-limits',
					    'system-limits.lock',
					    'lib/Forks/Super/SysInfo.pm',
					    't/out/spawn*',
					    't/out/sigchld.debug',
					    't/out/test*',
					    't/out/.lock-*',
					    'lib/_Inline', 
					    'perl.exe.stackdump', # #$@^!cygwin
					    '_Inline') },
);


print STDERR q[

"Makefile.PL" complete. After you run "make", you can run "make test"
to run the Forks::Super unit tests in series, or "make fasttest" to use
the Forks::Super framework to run the tests in parallel.


];






package MY;

######################################################################
# additional testing targets
######################################################################

sub MY::postamble {

  my $stresstestargs = "-r 20 -x 5 -s -q";
  if ($^O =~ /solaris/i) {
    $stresstestargs = "-r 25 -x 4 -s -q";
  }
  my $postamble = <<"__END_POSTAMBLE__";


#################################################
#
# Additional targets for Forks::Super module.
#
#

# ------ fasttest: use Forks::Super to run Forks::Super tests in parallel

fasttest :: pure_all
	\$(PERLRUN) t/forked_harness.pl \$(TEST_FILES) -h -q

# ------ stress test: run all tests in parallel 100 times

stresstest :: pure_all
	\$(PERLRUN) t/forked_harness.pl \$(TEST_FILES) $stresstestargs

__END_POSTAMBLE__

  return $postamble;
}
