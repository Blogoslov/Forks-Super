use strict;
use warnings;
use ExtUtils::MakeMaker;
use v5.006; # 5.7.1 or better recommended

our %RECOMMENDED
    = ('YAML' => '0.62',
       'JSON' => '2.0',
       'YAML::Tiny' => '1.39',
       'Sys::CpuAffinity' => '0.91',
       'Sys::CpuLoadX' => '0.02',
       'DateTime::Format::Natural' => '0.89',
       'PerlIO::gzip' => 0 );

if ($^O eq 'cygwin') {
    $RECOMMENDED{'Win32::API'} = '0.71';
}
if ($^O eq 'MSWin32') {
    %RECOMMENDED = (%RECOMMENDED,
		    'Win32::API' => '0.71',
		    'Win32::IPC' => 0,
		    'Win32::Process' => '0.14',
		    'Win32::Process::Kill' => '2.64',
		    'DBD::WMI' => 0);
}

our %REQUIRED 
    = ('Test::More' => '0',
       'Time::HiRes' => '1.30');
if ($^O eq 'MSWin32') {
    $REQUIRED{'Win32::API'} = '0.43';
    # Win32::Process? 
}

# files that may exist and be nice to clean up with a  make clean
our $FILES_TO_CLEAN 
    = join " ", qw(Forks-Super-* system-limits system-limits.lock
		   lib/Forks/Super/SysInfo.pm* t/out/spawn* t/out/07*
		   t/out/sigchld.debug t/out/test* t/out/.lock-*
		   t/out/48b.* t/out/debug1-* t/out/limits.* t/poorsort.pl
		   t/out/ipc* t/out/new-ipc* t/out/66* t/dir* t/out/24*
                   t/out/daemon* lib/_Inline *.stackdump t/out/.sync*);

our %META_MERGE
    = (recommends => \%RECOMMENDED,
       no_index => { 
	   'package' => ['Sys::CpuAffinity', 
			 'Signals::XSIG',
			 'Signals::XSIG::Default',
	       	         'Signals::XSIG::TieArray56'] });

######################################################################

if ($] < 5.007003) {

    # common but intermittent test failures on linux v5.6.2:
    #   t/32
    #   t/30b
    #   t/48a
    #   t/43g
    #   t/56a
    #   t/44g
    #   and others

    warn qq{

WARNING !!! The Forks::Super module makes heavy use of 
insufficiently paranoid signal handlers (See "Deferred
Signals (Safe Signals)" in a more recent version of perlipc) 
and is not recommended on versions of perl older than
v5.7.3. (Your version: $])

};
    sleep 1;
}


# Win32::API v0.71 strongly recommended on Windows
if ($^O eq 'MSWin32') {
    my $V = eval 'use Win32::API; $Win32::API::VERSION';
    if ($@) {
	warn qq[

Win32::API not found. That module is strongly recommended
with this distribution on Windows systems (at least v0.71).

];
    } elsif ($V < 0.71) {
	warn qq[

Win32::API v$V found. This distribution strongly recommends
that you upgrade Win32::API to at least v0.71.

];
    }
}

if (" @ARGV " =~ / bundle\b/i || " @ARGV " =~ / reinstall\b/i) {
    if ("@ARGV" =~ /bundle=0/i) {
	$ENV{BUNDLE} = '0';
    } else {
	$ENV{BUNDLE_REINSTALL} = 1;
    }
    @ARGV = grep { !/^bundle\b/i && !/^reinstall\b/ } @ARGV;
}
if (defined($ENV{BUNDLE}) && $ENV{BUNDLE} eq "0") {
    print STDERR "Skip check and install for bundled modules.\n";
} else {
    install_bundled_modules();
}
probe_system();

my $MM_VERSION = eval $ExtUtils::MakeMaker::VERSION;

WriteMakefile(

    NAME                => 'Forks::Super',
    AUTHOR              => q[Marty O'Brien <mob\@cpan.org>],       #'],
    VERSION_FROM        => 'lib/Forks/Super.pm',
    ABSTRACT_FROM       => 'lib/Forks/Super.pm',
    PL_FILES            => {},
    PREREQ_PM => \%REQUIRED,

    ($MM_VERSION >= 6.46   ? ('META_MERGE' => \%META_MERGE ) : ()),
    ($MM_VERSION >= 6.3002 ? ('LICENSE'    => 'perl')        : ()),

    dist                => { COMPRESS => 'gzip -9f', SUFFIX => 'gz', },
    clean               => { FILES => $FILES_TO_CLEAN },

);


print STDERR q[

"Makefile.PL" complete. After you run "make", you can run "make test"
to run the Forks::Super unit tests in series, or "make fasttest" to use
the Forks::Super framework to run the tests in parallel.


];

#############################################################################
#
# run installer for the additional modules
# that were included with this distribution.
#
# run  perl Makefile.PL BUNDLE=1
# or   BUNDLE_REINSTALL=1 perl Makefile.PL
# to allow re-installation of bundled modules
#
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
    unless ($ENV{NOLIMITS}) {
	print STDERR "Gathering information on current system $^O.$]\n";
	print STDERR "and creating Forks::Super::SysInfo package.\n";
	system($^X, 'SysInfo.pm.PL', 'lib/Forks/Super/SysInfo.pm');
    }
}


#############################################################################

package MY;

# # # # # # # # # # # # # # # # # # # # # # # # # # # # # # 
# additional testing targets
# # # # # # # # # # # # # # # # # # # # # # # # # # # # # # 

sub MY::postamble {

    my $stresstestargs = "-r 20 -x 5 -s -q -t 150";
    if ($^O =~ /solaris/i) {
	$stresstestargs = "-r 25 -x 4 -s -q -t 150";
    }
    # $(PERLRUN) not avail in 5.6.1, ExtUtils::MakeMaker 5.45
    my $PERLEXE = '$(FULLPERL)';  
    my $postamble = <<"__END_POSTAMBLE__";

# # # # # # # # # # # # # # # # # # # # # # # # # # # # # # 
#
# Additional testing targets for Forks::Super module.
#
# # # # # # # # # # # # # # # # # # # # # # # # # # # # # # 

# ------ fasttest: use Forks::Super to run Forks::Super tests in parallel

fasttest :: pure_all
	$PERLEXE t/forked_harness.pl \$(TEST_FILES) -h -q -t 150

# ------ stress test: run all tests in parallel 100 times

stresstest :: pure_all
	$PERLEXE t/forked_harness.pl \$(TEST_FILES) $stresstestargs

__END_POSTAMBLE__

    return $postamble;
}
