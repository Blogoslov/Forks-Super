use strict;
use warnings;
use ExtUtils::MakeMaker;

######################################################################
# recommended modules. This module and most of
# its features will work even if these modules
# are not available. Many of them are specific
# to an operating system.

my @recommends = ("Time::HiRes" => '1.30', 
		  "YAML" => '0.62',
#		  "Sys::CpuAffinity" => '0.9'
		 );

if ($^O =~ /darwin/i || $^O =~ /macos/) {
  push @recommends, ("Inline" => '0.44',
		     "Inline::C" => '0.44');
} else {
  push @recommends, ("Inline" => '0.42',
		     "Inline::C" => '0.42');
}

if ($^O eq "MSWin32" || $^O =~ /cygwin/i) {
  push @recommends, ("Win32::Process" => '0.11',
		     "Win32::API" => '0.43');
}

if ($^O =~ /bsd/i) {
  push @recommends, ("BSD::Process::Affinity" => '0.01');
}

######################################################################

WriteMakefile(
    ((@recommends > 0 && $ExtUtils::MakeMaker::VERSION+0 >= 6.46)
         ? ('META_MERGE' => { 'recommends' => [ @recommends ] })
	 : ()),
    NAME                => 'Forks::Super',
    AUTHOR              => q[Marty O'Brien <mob@cpan.org>],
    VERSION_FROM        => 'lib/Forks/Super.pm',
    ABSTRACT_FROM       => 'lib/Forks/Super.pm',
    ($ExtUtils::MakeMaker::VERSION+0 >= 6.3002
      ? ('LICENSE'=> 'perl')
      : ()),
    PL_FILES            => { },   # ignore system-limits.PL
    PREREQ_PM => {
        'Test::More' => 0,
    },

    dist                => { COMPRESS => 'gzip -9f', SUFFIX => 'gz', },
    clean               => { FILES => join (" ",'Forks-Super-*',
					    'system-limits',
					    'system-limits.lock',
					    't/out/spawn*',
					    't/out/sigchld.debug',
					    't/out/test*',
					    't/out/.lock-*',
					    'lib/_Inline', 
					    'perl.exe.stackdump', # #$@^!cygwin
					    '_Inline') },
);


package MY;

######################################################################
# testing targets, including custom fasttest and stresstest targets,
# depend on ./system-limits file
######################################################################

sub MY::test {
  my $test = shift->SUPER::test(@_);
  $test =~ s!^test(\w+) :: !test$1 :: system-limits !gm;
  return $test;
}

sub MY::postamble {

  my $stresstestargs = "-r 10 -x 10 -s -q";
  if ($^O =~ /solaris/i) {
    $stresstestargs = "-r 20 -x 5 -s -q";
  }
  my $postamble = <<"__END_POSTAMBLE__";

# ------ system-limits file discovers some system limitations

system-limits :: system-limits.PL pm_to_blib
	\$(PERLRUNINST) system-limits.PL system-limits

# ------ fasttest: use Forks::Super to run Forks::Super tests in parallel

fasttest :: pm_to_blib system-limits
	\$(PERLRUN) t/forked_harness.pl \$(TEST_FILES) -h

# ------ stress test: run all tests in parallel 100 times

stresstest :: pm_to_blib system-limits
	\$(PERLRUN) t/forked_harness.pl \$(TEST_FILES) $stresstestargs

__END_POSTAMBLE__

  return $postamble;
}
