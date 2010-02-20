package Forks::Super::Tie::BackgroundArray;
use Forks::Super;
use Carp;

# an array that is evaluated in a child process.
# the first time an element of the array is dereferenced, 
# retrieve the output from the child, 
# waiting for the child to finish if necessary


sub TIEARRAY {
  my ($classname, $style, $command_or_code, %other_options) = @_;
  my $self = { value_set => 0, value => undef, style => $style };
  if ($style eq "eval") {
    require YAML;
    $self->{code} = $command_or_code;
    $self->{job_id} = Forks::Super::fork { %other_options, child_fh => "out",
					     sub => sub {
					       my @Result = $command_or_code->();
					       print STDOUT YAML::Dump(@Result);
					     } };
  } elsif ($style eq "qx") {
    $self->{command} = $command_or_code;
    $self->{delimiter} = $/;
    $self->{stdout} = "";
    $self->{job_id} = Forks::Super::fork { %other_options, child_fh => "out",
					     cmd => $command_or_code,
					     stdout => \$self->{stdout} };
  }
  $self->{job} = Forks::Super::Job::get($self->{job_id});
  bless $self, $classname;
  return $self;
}

sub _retrieve_value {
  my $self = shift;
  if (!$self->{job}->is_complete) {
    my $pid = Forks::Super::waitpid $self->{job_id}, 0;
    if ($pid != $self->{job}->{real_pid}) {
      carp "Forks::Super::bg_eval: failed to retrieve result from process\n";
      $self->{value_set} = 1;
      return;
    }
  }
  if ($self->{style} eq "eval") {
    require YAML;
    my @result = YAML::Load( join'', Forks::Super::read_stdout($self->{job_id}) );
    $self->{value} = [ @result ];
    $self->{value_set} = 1;
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
