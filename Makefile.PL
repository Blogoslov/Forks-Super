use strict;
use warnings;
use ExtUtils::MakeMaker;

#
# recommended modules.
# many of them are OS dependent
#

my @recommends = ("Time::HiRes" => 0);
if ($^O eq "MSWin32") {
  push @recommends, ("Win32" => 0, 
		     "Win32::Process" => 0,
		     "Win32::API" => 0);
}
if ($^O =~ /cygwin/) {
  push @recommends, ("Win32::Process" => 0);
}
if ($^O =~ /bsd/i) {
  push @recommends, ("BSD::Process::Affinity" => 0);
}

WriteMakefile(
    ((@recommends > 0 && $ExtUtils::MakeMaker::VERSION >= 6.46)
         ? ('META_MERGE' => { 'recommends' => [ @recommends ] })
	 : ()),
    NAME                => 'Forks::Super',
    AUTHOR              => q[Marty O'Brien <mob@cpan.org>],
    VERSION_FROM        => 'lib/Forks/Super.pm',
    ABSTRACT_FROM       => 'lib/Forks/Super.pm',
    ($ExtUtils::MakeMaker::VERSION >= 6.3002
      ? ('LICENSE'=> 'perl')
      : ()),
    PL_FILES            => {},
    PREREQ_PM => {
        'Test::More' => 0,
    },
    dist                => { COMPRESS => 'gzip -9f', SUFFIX => 'gz', },
    clean               => { FILES => 'Forks-Super-*' },
);


