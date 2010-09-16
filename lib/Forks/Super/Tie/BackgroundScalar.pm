#
# Forks::Super::Tie::BackgroundScalar - a scalar context
#    value that is calculated in a background task
#

package Forks::Super::Tie::BackgroundScalar;
use Forks::Super;
use Forks::Super::Wait 'WREAP_BG_OK';
use Carp;
use strict;
use warnings;

# a scalar reference that is evaluated in a child process.
# when the value is dereferenced, retrieve the output from
# the child, waiting for the child to finish if necessary

sub TIESCALAR {
  my ($class, $style, $command_or_code, %other_options) = @_;
  my $protocol = $other_options{'protocol'};
  my $self = { value_set => 0, style => $style };
  if ($style eq 'eval') {
    $self->{code} = $command_or_code;
    $self->{job_id} = Forks::Super::fork { %other_options, child_fh => 'out',
			  sub => sub {
			    my $Result = $command_or_code->();
			    print STDOUT _encode($protocol, $Result);
			  }, _is_bg => 1, _lazy_proto => $protocol };
  } elsif ($style eq 'qx') {
    $self->{command} = $command_or_code;
    $self->{stdout} = '';
    $self->{job_id} = Forks::Super::fork { %other_options, child_fh => 'out',
			  cmd => $command_or_code,
			  stdout => \$self->{stdout}, _is_bg => 1 };
  }
  $self->{job} = Forks::Super::Job::get($self->{job_id});
  Forks::Super::_set_last_job($self->{job}, $self->{job_id});
  $self->{value} = undef;
  bless $self, $class;
  return $self;
}

sub _encode {
  my ($protocol, $data) = @_;
  if ($protocol eq 'YAML') {
    require YAML;
    return YAML::Dump($data);
  } elsif ($protocol eq 'JSON1') {
    require JSON;
    if (ref $data eq "") {
      return new JSON()->objToJson([ "$data" ]);
    } else {
      return new JSON()->objToJson([ $data ]);
    }
  } elsif ($protocol eq 'JSON2') {
    require JSON;
    if (ref $data eq "") {
      return JSON::encode_json([ "$data" ]);
    } else {
      return JSON::encode_json([ $data ]);
    }
  } elsif ($protocol eq 'YAML::Tiny') {
    require YAML::Tiny;
    return YAML::Tiny::Dump($data);
  } elsif ($protocol eq 'Data::Dumper') {
    require Data::Dumper;
    $data = Data::Dumper::Dumper($data);
    return $data;
  } else {
    croak "Forks::Super::Tie::BackgroundScalar: ",
      "expected YAML or JSON to be available\n";
  }
}

sub _decode {
  my ($protocol, $data) = @_;
  if (!defined($data) || $data eq "") {
    return;
  } elsif ($protocol eq 'YAML') {
    require YAML;
    return YAML::Load($data);
  } elsif ($protocol eq 'JSON1') {
    require JSON;
    return new JSON()->jsonToObj($data)->[0];
  } elsif ($protocol eq 'JSON2') {
    require JSON;
    return JSON::decode_json($data)->[0];
  } elsif ($protocol eq 'Data::Dumper') {
    require Data::Dumper;
    my $VAR1;
    my $x = eval "$data";
    return $x;
  } elsif ($protocol eq 'YAML::Tiny') {
    require YAML::Tiny;
    return YAML::Tiny::Load($data);
  }
  croak "Forks::Super::Tie::BackgroundScalar: ",
    "YAML or JSON required to use bg_eval\n";
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
    if (!defined $stdout || $stdout eq "") {
      $self->{value_set} = 1;
      $self->{value} = undef;
    } else {
      $self->{value_set} = 1;
      $self->{value} = _decode($self->{job}->{_lazy_proto}, $stdout);
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
