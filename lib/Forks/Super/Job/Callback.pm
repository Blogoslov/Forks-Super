#
# Forks::Super::Job::Callback - manage callback functions
#    that are called in the parent at certain points in the
#    lifecycle of a child process
# implements
#    fork { callback => \&sub }
#    fork { callback => { event => code , event => code , ... } }


package Forks::Super::Job::Callback;
use Forks::Super::Util qw(qualify_sub_name);
use Forks::Super::Debug qw(:all);
use Exporter;
use base 'Exporter';
use Carp;
use strict;
use warnings;

our @EXPORT_OK = qw(run_callback);
our %EXPORT_TAGS = (all => \@EXPORT_OK);
our $VERSION = $Forks::Super::Util::VERSION;

sub run_callback {
  my ($job, $callback) = @_;
  my $key = "_callback_$callback";
  if (!defined $job->{$key}) {
    return;
  }
  if ($job->{debug}) {
    debug("Forks::Super: Job ",$job->{pid}," running $callback callback");
  }
  my $ref = ref $job->{$key};
  if ($ref ne 'CODE' && ref ne '') {
    carp "Forks::Super::Job::run_callback: invalid callback $callback. ",
      "Got $ref, expected CODE or subroutine name\n";
    return;
  }

  $job->{"callback_time_$callback"} = Time::HiRes::gettimeofday();
  $callback = delete $job->{$key};

  no strict 'refs';
  if (ref $callback eq 'HASH') {
    Carp::confess("bad callback: $callback ",
		  "(did you forget to specify \"sub\" { }?)");
  } else {
    $callback->($job, $job->{pid});
  }
}

sub _preconfig_callbacks {
  my $job = shift;

  if (defined $job->{suspend}) {
    $job->{suspend} = qualify_sub_name $job->{suspend};
  }
  if (!defined $job->{callback}) {
    return;
  }
  if (ref $job->{callback} eq "" || ref $job->{callback} eq 'CODE') {
    $job->{callback} = { finish => $job->{callback} };
  }
  foreach my $callback_type (qw(finish start queue fail)) {
    if (defined $job->{callback}{$callback_type}) {
      $job->{"_callback_" . $callback_type}
	= qualify_sub_name($job->{callback}{$callback_type});
      if ($job->{debug}) {
	debug("Forks::Super::Job: registered callback type $callback_type");
      }
    }
  }
}

sub Forks::Super::Job::_config_callback_child {
  my $job = shift;
  for my $callback (grep { /^callback/ || /^_callback/ } keys %$job) {
    # this looks odd, but it clears up a SIGSEGV that was happening here
    $job->{$callback} = '';
    delete $job->{$callback};
  }
}


1;

