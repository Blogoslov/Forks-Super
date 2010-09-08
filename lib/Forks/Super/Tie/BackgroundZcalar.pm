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
    $self->{code} = $command_or_code;
    if ($other_options{'use_YAML'}) {
      require YAML;
      $self->{job_id} = Forks::Super::fork { %other_options, child_fh => 'out',
			  sub => sub {
			    my $Result = $command_or_code->();
			    print STDOUT YAML::Dump($Result);
			  }, _is_bg => 1, _useYAML => 1 };
    } elsif ($other_options{'use_JSON2'}) {
      require JSON;
      $self->{job_id} = Forks::Super::fork { %other_options, child_fh => 'out',
			  sub => sub {
			    my $Result = $command_or_code->();
			    if (ref $Result eq "") {
			      print STDOUT JSON::encode_json(["$Result"]);
			    } else {
			      print STDOUT JSON::encode_json([$Result]);
			    }
			  }, _is_bg => 1, _useJSON => 1, _useJSON2 => 1 };
    } elsif ($other_options{'use_JSON1'}) {
      require JSON;
      $self->{job_id} = Forks::Super::fork { %other_options, child_fh => 'out',
			  sub => sub {
			    my $Result = $command_or_code->();
			    my $js = new JSON;
			    if (ref $Result eq "") {
			      print STDOUT $js->objToJson(["$Result"]);
			    } else {
			      print STDOUT $js->objToJson([$Result]);
			    }
			  }, _is_bg => 1, _useJSON => 1, _useJSON1 => 1 };
    } else {
      croak "Forks::Super::Tie::BackgroundZcalar: expected YAML or JSON ",
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
  Forks::Super::_set_last_job($self->{job}, $self->{job_id});
  $self->{value} = undef;
  return bless $self, $class;
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
      if ($pid != $self->{job}->{real_pid}) {
	carp "Forks::Super::bg_eval: failed to retrieve result from process!\n";
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
      if ($self->{job}->{_useYAML}) {
	require YAML;
	my ($result) = YAML::Load( $stdout );
	$self->{value_set} = 1;
	$self->{value} = $result;
      } elsif ($self->{job}->{_useJSON2}) {

	require JSON;
	if (!defined $stdout || $stdout eq "") {
	  $self->{value_set} = 1;
	  $self->{value} = undef;
	} else {
	  my $result = JSON::decode_json( $stdout );
	  $self->{value_set} = 1;
	  $self->{value} = $result->[0];
	}
      } elsif ($self->{job}->{_useJSON1}) {

	require JSON;
	if (!defined $stdout || $stdout eq "") {
	  $self->{value_set} = 1;
	  $self->{value} = undef;
	} else {
	  my $js = new JSON;
	  my $result = $js->jsonToObj( $stdout );
	  $self->{value_set} = 1;
	  $self->{value} = $result->[0];
	}
      } else {
	$self->{error} ||= "YAML or JSON required to use bg_eval call";
	bless $self, $class;
	croak "Forks::Super::Tie::BackgroundZcalar: ",
	  "YAML or JSON required to use bg_eval\n";
      }
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
