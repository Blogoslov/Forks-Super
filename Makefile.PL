use strict;
use warnings;
use ExtUtils::MakeMaker;

# run installer for the additional modules
# that were included with this distribution.
#
# run  perl Makefile.PL BUNDLE=1
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

sub recommend_modules {
  my @recommends = ("Time::HiRes" => '1.30', 
		    "YAML" => '0.62',
		    "JSON" => '2.0',
		    "Sys::CpuAffinity" => '0.9',
		    "Sys::CpuLoadX" => '0.02',
		   );

  if ($^O eq "MSWin32" || $^O =~ /cygwin/i) {
    push @recommends, ("Win32::Process" => '0.11',
		       "Win32::API" => '0.43');
  }
  return [ @recommends ];
}

######################################################################

WriteMakefile(
    ($ExtUtils::MakeMaker::VERSION+0 >= 6.46
         ? ('META_MERGE' => { 'recommends' => &recommend_modules })
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
&install_bundled_modules;




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
