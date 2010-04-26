# bundle.pl to conditionally install a bundled submodule

package Sys::CpuAffinity;
use ExtUtils::MakeMaker;
use strict;
use warnings;

my $buildClass = 'Sys::CpuAffinity::Custom::Builder';
my $SuperModule = 'Forks::Super';
my $TargetModule = 'Sys::CpuAffinity';
my $TargetModuleMinVersion = '0.90';
my $version = MM->parse_version('lib/Sys/CpuAffinity.pm');

my $TargetModulePitch = qq[

Sys::CpuAffinity is a module for manipulating CPU affinities
of processes. If Sys::CpuAffinity is available, Forks::Super can
use it to set the CPU affinities of the background processes
it launches. Without Sys::CpuAffinity, this feature probably
won't work.

Installation of this module is entirely optional. The  Module::Build
module is required to install this module. The installation of
Forks::Super will proceed even if the installation of Sys::CpuAffinity
is unsuccessful.
];

my $TargetModulePrompt = "Do you want to attempt to install Sys::CpuAffinity v$version?";
my $TargetModulePromptDefault = 'n';
my $TargetModuleDeclineMessage =
  qq[Some features of $SuperModule may not be available.\n];

# Makefile.PL for Sys::CpuAffinity included with Forks::Super distribution.

# Note: this file was auto-generated by Module::Build::Compat version 0.3607

sub run_auto_generated_Makefile_PL {
    unless (eval "use Module::Build::Compat 0.02; 1" ) {
      print "This module requires Module::Build to install itself.\n";

      require ExtUtils::MakeMaker;
      my $yn = ExtUtils::MakeMaker::prompt
	('  Install Module::Build now from CPAN?', 'y');

      unless ($yn =~ /^y/i) {
	die " *** Cannot install without Module::Build.  Exiting ...\n";
      }

      require Cwd;
      require File::Spec;
      require CPAN;

      # Save this 'cause CPAN will chdir all over the place.
      my $cwd = Cwd::cwd();

      CPAN::Shell->install('Module::Build::Compat');
      CPAN::Shell->expand("Module", "Module::Build::Compat")->uptodate
	or die "Couldn't install Module::Build, giving up.\n";

      chdir $cwd or die "Cannot chdir() back to $cwd: $!";
    }
    eval "use Module::Build::Compat 0.02; 1" or die $@;
    use lib '_build/lib';
    Module::Build::Compat->run_build_pl(args => \@ARGV);
    my $build_script = 'Build';
    $build_script .= '.com' if $^O eq 'VMS';
    exit(0) unless(-e $build_script); # cpantesters convention

    eval "require $buildClass"; die $@ if $@;
    Module::Build::Compat->write_makefile(build_class => $buildClass);

}

do '../conditionally-install-submodule.pl';

&conditionally_install_submodule
(
  superModule => $SuperModule,
  targetModule => $TargetModule,
  minVersion => $TargetModuleMinVersion,
  pitch => $TargetModulePitch,
  prompt => $TargetModulePrompt,
  promptDefault => 'n',
  declineMessage => "Some features of Forks::Super may not be available",
  force => scalar(grep { /force/ } @ARGV),
  reinstall => scalar(grep { /reinstall/ || /bundle/ } @ARGV),

);
