#
# Forks::Super::Tie::BackgroundZcalar - experimental and undocumented
#    alternative to Forks::Super::Tie::BackgroundScalar for lazy
#    evaluation of a perl subroutine or external command
#
# When you use this package instead of Forks::Super::Tie::BackgroundScalar,
# you don't need to dereference the result:
#
# BackgroundScalar:
#     $x = bg_eval { sub { sleep 3 ; 42 } };
#     print "Expect $$x == 42\n";
#
# BackgroundZcalar:
#     $x = bg_eval { sub { sleep 3 ; 42 } };
#     print "Expect $x == 42\n";
#

package Forks::Super::Tie::BackgroundZcalar;
use Forks::Super;
use Forks::Super::Wait 'WREAP_BG_OK';
use Carp;
use strict;
use warnings;
use overload
  '""' => \&_fetch,
  '+' => sub { $_[0]->_fetch + $_[1] },
  '*' => sub { $_[0]->_fetch * $_[1] },
  '&' => sub { $_[0]->_fetch & $_[1] },
  '|' => sub { $_[0]->_fetch | $_[1] },
  '^' => sub { $_[0]->_fetch ^ $_[1] },
  '~' => sub { ~$_[0]->_fetch },
  '<=>' => sub { $_[2] ? $_[1]||0 <=> $_[0]->_fetch 
		       : $_[0]->_fetch <=> $_[1]||0 },
  'cmp' => sub { $_[2] ? $_[1] cmp $_[0]->_fetch : $_[0]->_fetch cmp $_[1] },
  '-' => sub { $_[2] ? $_[1] - $_[0]->_fetch : $_[0]->_fetch - $_[1] },
  '/' => sub { $_[2] ? $_[1] / $_[0]->_fetch : $_[0]->_fetch / $_[1] },
  '%' => sub { $_[2] ? $_[1] % $_[0]->_fetch : $_[0]->_fetch % $_[1] },
  '**' => sub { $_[2] ? $_[1] ** $_[0]->_fetch : $_[0]->_fetch ** $_[1] },
  '<<' => sub { $_[2] ? $_[1] << $_[0]->_fetch : $_[0]->_fetch << $_[1] },
  '>>' => sub { $_[2] ? $_[1] >> $_[0]->_fetch : $_[0]->_fetch >> $_[1] },
  'x' => sub { $_[2] ? $_[1] x $_[0]->_fetch : $_[0]->_fetch x $_[1] },

# derefencing operators: should return a reference of the correct type.

  '${}' => sub { $_[0]->_fetch },
  '@{}' => sub { $_[0]->_fetch },
  '&{}' => sub { $_[0]->_fetch },
  '*{}' => sub { $_[0]->_fetch },

  # when we define %{} and internally require an element of an object,
  # we must unbless the object before the operation and rebless it
  # afterward. See http://search.cpan.org/perldoc?overload#Two-face_references

  '%{}' => sub { $_[0]->_fetch },

  'cos' => sub { cos $_[0]->_fetch },
  'sin' => sub { sin $_[0]->_fetch },
  'exp' => sub { exp $_[0]->_fetch },
  'log' => sub { log $_[0]->_fetch },
  'sqrt' => sub { sqrt $_[0]->_fetch },
  'int' => sub { int $_[0]->_fetch },
  'abs' => sub { abs $_[0]->_fetch },
  'atan2' => sub { $_[2] ? atan2($_[1], $_[0]->_fetch) 
		         : atan2($_[0]->_fetch, $_[1]) }
;

# a scalar reference that is evaluated in a child process.
# when the value is dereferenced, retrieve the output from
# the child, waiting for the child to finish if necessary

sub new {
#sub TIESCALAR {
  my ($class, $style, $command_or_code, %other_options) = @_;
  my $self = { value_set => 0, style => $style };
  if ($style eq 'eval') {
    my $protocol = $other_options{'protocol'};
    $self->{code} = $command_or_code;
    $self->{job_id} 
      = Forks::Super::fork { %other_options, child_fh => 'out',
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
  return bless $self, $class;
}

sub _encode {
  my ($protocol, $data) = @_;
  if ($protocol eq 'YAML') {
    require YAML;
    return YAML::Dump($data);
  } elsif ($protocol eq 'JSON1') {
    require JSON;
    if (ref $data eq '') {
      return new JSON()->objToJson(["$data"]);
    } else {
      return new JSON()->objToJson([$data]);
    }
  } elsif ($protocol eq 'JSON2') {
    require JSON;
    if (ref $data eq '') {
      return JSON::encode_json(["$data"]);
    } else {
      return JSON::encode_json([$data]);
    }
  } elsif ($protocol eq 'YAML::Tiny') {
    require YAML::Tiny;
    return YAML::Tiny::Dump($data);
  } elsif ($protocol eq 'Data::Dumper') {
    require Data::Dumper;
    return Data::Dumper::Dumper($data);
  } else {
    croak "Forks::Super::Tie::BackgroundZcalar: ",
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
    my $decoded = eval "$data";
    return $decoded;
  } elsif ($protocol eq 'YAML::Tiny') {
    require YAML::Tiny;
    return YAML::Tiny::Load($data);
  } else {
    croak "YAML or JSON required to use bg_eval";
  }
}

# unbless the object (so we can access hash elements without going
# through the overloaded hash dereference operator). Return the
# original object type so we can re-bless it.
sub _unbless {
  my $self = shift;
  my $class = ref $self;
  bless $self, "!@#$%";
  return $class;
}

sub is_ready {
  my $self = shift;
  my $is_ready = 0;

  my $class = $self->_unbless;

  if ($self->{value_set}) { $is_ready = 1 }
  if ($self->{job}->is_complete) { $is_ready = 1 }

  bless $self, $class;

  # XXX - pause here or waitpid WNOHANG? That might be helpful on Windows.
  return 0;
}

# retrieves the result of the background task. If necessary, wait for the
# background task to finish.
sub _fetch {
  my $self = shift;

  # turn off overloaded hash dereferencing. Don't forget to turn it back on
  my $class = $self->_unbless;

  if (!$self->{value_set}) {
    if (!$self->{job}->is_complete) {
      my $pid = Forks::Super::waitpid $self->{job_id}, WREAP_BG_OK;
      if ($pid != $self->{job}->{real_pid} && $pid != $self->{job}->{pid}) {

	carp "Forks::Super::bg_eval: ",
	  "failed to retrieve result from process!\n";
	$self->{value_set} = 1;
	$self->{error} = "waitpid failed, result not retrieved from process";
	bless $self, $class;
	return;
      }
      if ($self->{job}->{status} != 0) {
	$self->{error} = "job status: " . $self->{job}->{status};
      }
      # XXX - what other error conditions are there to set ?
    }

    if ($self->{style} eq 'eval') {
      my $stdout = join'', Forks::Super::read_stdout($self->{job_id});
      eval {
	$self->{value} = _decode($self->{job}->{_lazy_proto}, $stdout);
      };
      if ($@) {
	$self->{error} ||= $@;
	$self->{value} = undef;
      }
      $self->{value_set} = 1;
    } elsif ($self->{style} eq 'qx') {
      $self->{value_set} = 1;
      $self->{value} = $self->{stdout};
    }
  }
  my $value = $self->{value};
  bless $self, $class;
  return $value;
}

1;
