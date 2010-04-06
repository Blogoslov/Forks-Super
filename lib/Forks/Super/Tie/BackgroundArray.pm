#
# Forks::Super::Tie::BackgroundArray - an array context value that
#    is calculated in a background task
#

package Forks::Super::Tie::BackgroundArray;
use Forks::Super;
use Forks::Super::Wait 'WREAP_BG_OK';
use Carp;

# an array that is evaluated in a child process.
# the first time an element of the array is dereferenced,
# retrieve the output from the child,
# waiting for the child to finish if necessary


sub TIEARRAY {
  my ($classname, $style, $command_or_code, %other_options) = @_;
  my $self = { value_set => 0, value => undef, style => $style };
  if ($style eq "eval") {
    $self->{code} = $command_or_code;
    if ($other_options{"use_YAML"}) {
      require YAML;
      $self->{job_id} = Forks::Super::fork { %other_options, child_fh => "out",
				  sub => sub {
				    my @Result = $command_or_code->();
				    print STDOUT YAML::Dump(@Result);
				  }, _is_bg => 2, _useYAML => 1 };
    } elsif ($other_options{"use_JSON"}) {
      require JSON;
      $self->{job_id} = Forks::Super::fork { %other_options, child_fh => "out",
				  sub => sub {
				    my @Result = $command_or_code->();
				    print STDOUT JSON::encode_json([@Result]);
				  }, _is_bg => 2, _useJSON => 1 };
    }
  } elsif ($style eq "qx") {
    $self->{command} = $command_or_code;
    $self->{delimiter} = $/;
    $self->{stdout} = "";
    $self->{job_id} = Forks::Super::fork { %other_options, child_fh => "out",
					     cmd => $command_or_code,
					     stdout => \$self->{stdout},
					     _is_bg => 2};
  }
  $self->{job} = Forks::Super::Job::get($self->{job_id});
  $Forks::Super::LAST_JOB_ID = $self->{job_id};
  $Forks::Super::LAST_JOB = $self->{job};
  bless $self, $classname;
  return $self;
}

sub _retrieve_value {
  my $self = shift;
  if (!$self->{job}->is_complete) {
    my $pid = Forks::Super::waitpid $self->{job_id}, WREAP_BG_OK;
    if ($pid != $self->{job}->{real_pid}) {
      carp "Forks::Super::bg_eval: failed to retrieve result from process\n";
      $self->{value_set} = 1;
      return;
    }
  }
  if ($self->{style} eq "eval") {
    my $stdout = join'', Forks::Super::read_stdout($self->{job_id});
    if ($self->{job}->{_useYAML}) {
      require YAML;
      my @result = YAML::Load( $stdout );
      $self->{value} = [ @result ];
      $self->{value_set} = 1;
    } elsif ($self->{job}->{_useJSON}) {
print STDERR "JSON decoding:\n------\n$stdout\n--------\n";
      if (!defined $stdout or $stdout eq "") {
	$self->{value_set} = 1;
	$self->{value} = [];
      } else {
	require JSON;
	my $result = JSON::decode_json( $stdout );
	$self->{value} = [ @$result ];
	$self->{value_set} = 1;
      }
    } else {
      croak "Forks::Super::Tie::BackgroundArray: ",
	"YAML or JSON required to use bg_eval\n";
    }
  } elsif ($self->{style} eq "qx") {
    my @result = ();
    if (defined $self->{delimiter}) {
      @result = split /$self->{delimiter}/, $self->{stdout};
      @result = grep { $_ .= $self->{delimiter} } @result;
    } else {
      @result = ($self->{stdout});
    }
    $self->{value} = [ @result ];
    $self->{value_set} = 1;
  }
  return;
}

sub FETCH {
  my ($self, $index) = @_;
  if (!$self->{value_set}) {
    $self->_retrieve_value;
  }
  return $self->{value}->[$index];
}

sub STORE {
  my ($self, $index, $new_value) = @_;
  if (!$self->{value_set}) {
    $self->_retrieve_value;
  }
  my $old_value = $self->{value}->[$index];
  $self->{value}->[$index] = $new_value;
  return $old_value;
}

sub FETCHSIZE {
  my $self = shift;
  if (!$self->{value_set}) {
    $self->_retrieve_value;
  }
  return scalar @{$self->{value}};
}

sub STORESIZE {
  my ($self, $count) = @_;
  if (!$self->{value_set}) {
    $self->_retrieve_value;
  }
  my $diff = $count - $self->FETCHSIZE();
  if ($diff > 0) {
    push @{$self->{value}}, (undef) x $diff;
  } else {
    splice @{$self->{value}}, $diff;
  }
}

sub DELETE {
  my ($self, $index) = @_;
  if (!$self->{value_set}) {
    $self->_retrieve_value;
  }
  return delete $self->{value}->[$index];
}

sub CLEAR {
  my $self = shift;
  if (!$self->{value_set}) {
    $self->_retrieve_value;
  }
  $self->{value} = [];
}

sub PUSH {
  my ($self, @list) = @_;
  if (!$self->{value_set}) {
    $self->_retrieve_value;
  }
  push @{$self->{value}}, @list;
  return $self->FETCHSIZE();
}

sub UNSHIFT {
  my ($self, @list) = @_;
  if (!$self->{value_set}) {
    $self->_retrieve_value;
  }
  unshift @{$self->{value}}, @list;
  return $self->FETCHSIZE();
}

sub POP {
  my $self = shift;
  if (!$self->{value_set}) {
    $self->_retrieve_value;
  }
  return pop @{$self->{value}};
}

sub SHIFT {
  my $self = shift;
  if (!$self->{value_set}) {
    $self->_retrieve_value;
  }
  return shift @{$self->{value}};
}

sub SPLICE {
  my ($self, $offset, $length, @list) = @_;
  $offset = 0 if !defined $offset;
  $length = $self->FETCHSIZE() - $offset if !defined $length;
  if (!$self->{value_set}) {
    $self->_retrieve_value;
  }
  return splice @{$self->{value}}, $offset, $length, @list;
}

sub EXISTS {
  my ($self, $index) = @_;
  if (!$self->{value_set}) {
    $self->_retrieve_value;
  }
  return exists $self->{value}->[$index];
}

1;
