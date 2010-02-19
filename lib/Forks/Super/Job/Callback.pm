package Forks::Super::Job::Callback;
use Forks::Super::Util qw(qualify_sub_name);
use Exporter;
use base 'Exporter';
use Carp;
use strict;
use warnings;

our @EXPORT_OK = qw(run_callback);
our %EXPORT_TAGS = (all => \@EXPORT_OK);

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
  if ($ref ne "CODE" && ref ne "") {
    carp "Forks::Super::Job::run_callback: invalid callback $callback. ",
      "Got $ref, expected CODE or subroutine name\n";
    return;
  }

  $job->{"callback_time_$callback"} = Forks::Super::Util::Time();
  $callback = delete $job->{$key};

  no strict 'refs';
  $callback->($job, $job->{pid});
}

sub preconfig_callbacks {
  my $job = shift;
  if (!defined $job->{callback}) {
    return;
  }
  if (ref $job->{callback} eq "" || ref $job->{callback} eq "CODE") {
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

sub config_callback_child {
  my $job = shift;
  delete $job->{$_} for grep { /^_?callback/ } keys %$job;
}


1;

