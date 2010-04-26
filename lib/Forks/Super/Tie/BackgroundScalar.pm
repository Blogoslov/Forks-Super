#
# Forks::Super::Tie::BackgroundScalar - a scalar context
#    value that is calculated in a background task
#

package Forks::Super::Tie::BackgroundScalar;
use Forks::Super;
use Forks::Super::Wait 'WREAP_BG_OK';
use Carp;

# a scalar reference that is evaluated in a child process.
# when the value is dereferenced, retrieve the output from
# the child, waiting for the child to finish if necessary

sub TIESCALAR {
  my ($class, $style, $command_or_code, %other_options) = @_;
  my $self = { value_set => 0, style => $style };
  if ($style eq 'eval') {
    $self->{code} = $command_or_code;
    if ($other_options{'use_YAML'}) {
      require YAML;
      $self->{job_id} = Forks::Super::fork { %other_options, child_fh => 'out',
			  sub => sub {
			    my $Result = $command_or_code->();
			    print STDOUT YAML::Dump($Result);
			  }, _is_bg => 1, _useYAML => 1 };
    } elsif ($other_options{'use_JSON'}) {
      require JSON;
      $self->{job_id} = Forks::Super::fork { %other_options, child_fh => 'out',
			  sub => sub {
			    my $Result = $command_or_code->();
			    if (ref $Result eq "") {
			      print STDOUT JSON::encode_json(["$Result"]);
			    } else {
			      print STDOUT JSON::encode_json([$Result]);
			    }
			  }, _is_bg => 1, _useJSON => 1 };
    } else {
      croak "Forks::Super::Tie::BackgroundScalar: expected YAML or JSON ",
	"to be available\n";
    }
  } elsif ($style eq 'qx') {
    $self->{command} = $command_or_code;
    $self->{stdout} = '';
    $self->{job_id} = Forks::Super::fork { %other_options, child_fh => 'out',
			  cmd => $command_or_code,
			  stdout => \$self->{stdout}, _is_bg => 1 };
  }
  $self->{job} = Forks::Super::Job::get($self->{job_id});
  $Forks::Super::LAST_JOB_ID = $self->{job_id};
  $Forks::Super::LAST_JOB = $self->{job};
  $self->{value} = undef;
  bless $self, $class;
  return $self;
}

sub _retrieve_value {
  my $self = shift;
  if (!$self->{job}->is_complete) {
    my $pid = Forks::Super::waitpid $self->{job_id}, WREAP_BG_OK;
    if ($pid != $self->{job}->{real_pid}) {
      carp "Forks::Super::bg_eval: failed to retrieve result from process!\n";
      $self->{value_set} = 1;
      return;
    }
  }
  if ($self->{style} eq 'eval') {
    my $stdout = join'', Forks::Super::read_stdout($self->{job_id});
    if ($self->{job}->{_useYAML}) {
      require YAML;
      my ($result) = YAML::Load( $stdout );
      $self->{value_set} = 1;
      $self->{value} = $result;
    } elsif ($self->{job}->{_useJSON}) {

      require JSON;
      if (!defined $stdout || $stdout eq "") {
	$self->{value_set} = 1;
	$self->{value} = undef;
      } else {
	my $result = JSON::decode_json( $stdout );
	$self->{value_set} = 1;
	$self->{value} = $result->[0];
      }
    } else {
      croak "Forks::Super::Tie::BackgroundScalar: ",
	"YAML or JSON required to use bg_eval\n";
    }
  } elsif ($self->{style} eq 'qx') {
    $self->{value_set} = 1;
    $self->{value} = $self->{stdout};
  }
  return $self->{value};
}

sub FETCH {
  my $self = shift;
  if (!$self->{value_set}) {
    $self->_retrieve_value;
  }
  return $self->{value};
}

sub STORE {
  my ($self, $new_value) = @_;
  if (!$self->{value_set}) {
    $self->_retrieve_value;
  }
  my $old_value = $self->{value};
  $self->{value} = $new_value;
  return $old_value;
}

1;
