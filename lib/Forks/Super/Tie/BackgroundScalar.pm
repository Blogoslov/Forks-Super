#
# Forks::Super::Tie::BackgroundScalar - lazy evaluation of a perl
#    subroutine or external command
#
# Unlike previous version of Forks::Super::Tie::BackgroundScalar,
# you don't need to dereference the result:
#
# previous BackgroundScalar:
#     $x = bg_eval { sub { sleep 3 ; 42 } };
#     print "Expect $$x == 42\n";
#
# this BackgroundScalar:
#     $x = bg_eval { sub { sleep 3 ; 42 } };
#     print "Expect $x == 42\n";
#
# Also unlike the previous version, you don't actually use 'tie'
# with this object type.

package Forks::Super::Tie::BackgroundScalar;
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
    'cmp' => sub {
	$_[2] ? $_[1] cmp $_[0]->_fetch : $_[0]->_fetch cmp $_[1]
    },
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

our $VERSION = '0.55';

# "protocols" for serializing data and the methods used
# to carry out the serialization

my %serialization_dispatch = (

    YAML => {
	require => sub { require YAML },
	encode => sub { return YAML::Dump($_[0]) },
	decode => sub { return YAML::Load($_[0]) }
    },

    JSON1 => {
	require => sub { require JSON },
	encode => sub {
	    my $data = shift;
	    if (ref $data eq '') {
		$data = "$data";
	    }
	    return JSON->new->objToJson([$data]);
	},
	decode => sub { return JSON->new->jsonToObj($_[0])->[0] }
    },

    JSON2 => {
	require => sub { require JSON },
	encode => sub { 
	    my $data = shift;
	    if (ref $data eq '') {
		$data = "$data";
	    }
	    return JSON::encode_json([$data]);
	},
	decode => sub { return JSON::decode_json($_[0])->[0] }
    },

    'Data::Dumper' => {
	require => sub { require Data::Dumper },
	encode => sub { return Data::Dumper::Dumper($_[0]) },
	decode => sub {
	    my ($data,$job,$VAR1) = @_;
	    if (${^TAINT}) {
		if ($job->{untaint}) {
		    ($data) = $data =~ /(.*)/s;
		} else {
		    carp 'Forks::Super::bg_eval/bg_qx(): ',
		        'Using Data::Dumper for serialization, which cannot ',
		        "operate on 'tainted' data. Use bg_eval {...} ",
		        '{untaint => 1} or bg_qx COMMAND, ',
		        "{untaint => 1} to retrieve the result.\n";
		    return;
		}
	    }
	    my $decoded = eval "$data";    ## no critic (StringyEval)
	    return $decoded;
	}
    },

    'YAML::Tiny' => {
	require => sub { require YAML::Tiny },
	encode => sub { return YAML::Tiny::Dump($_[0]) },
	decode => sub { return YAML::Tiny::Load($_[0]) }
    },

    );

# a scalar reference that is evaluated in a child process.
# when the value is dereferenced, retrieve the output from
# the child, waiting for the child to finish if necessary

sub new {
    my ($class, $style, $command_or_code, %other_options) = @_;
    my $self = { value_set => 0, style => $style };
    if ($style eq 'eval') {
	my $protocol = $other_options{'protocol'};
	$self->{code} = $command_or_code;
	$self->{job_id} = Forks::Super::fork { 
	    (%other_options,
	     child_fh => 'out',
	     sub => sub {
		 my $Result = $command_or_code->();
		 print STDOUT _encode($protocol, $Result);
	     }, 
	     _is_bg => 1, 
	     _lazy_proto => $protocol )
	};

    } elsif ($style eq 'qx') {
	$self->{command} = $command_or_code;
	$self->{stdout} = '';
	$self->{job_id} = Forks::Super::fork { 
	    (%other_options, 
	     child_fh => 'out',
	     cmd => $command_or_code,
	     stdout => \$self->{stdout}, 
	     _is_bg => 1)
	};
    }
    $self->{job} = Forks::Super::Job::get($self->{job_id});
    ($Forks::Super::LAST_JOB, $Forks::Super::LAST_JOB_ID)
	= ($self->{job}, $self->{job_id});
    $self->{value} = undef;
    return bless $self, $class;
}

sub _encode {
    my ($protocol, $data) = @_;
    if (defined $serialization_dispatch{$protocol}) {
	$serialization_dispatch{$protocol}{'require'}->();
	return $serialization_dispatch{$protocol}{encode}->($data);
    } else {
	croak 'Forks::Super::Tie::BackgroundScalar: ',
	    'YAML, JSON, or Data::Dumper required to use bg_eval';
    }
}

sub _decode {
    my ($protocol, $data, $job) = @_;
    if (defined $serialization_dispatch{$protocol}) {
	$serialization_dispatch{$protocol}{require}->();
	return $serialization_dispatch{$protocol}{decode}->($data,$job);
    } else {
	croak 'Forks::Super::Tie::BackgroundScalar: ',
	    'YAML, JSON, or Data::Dumper required to use bg_eval';
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
	    if ($pid != $self->{job}{real_pid} && $pid != $self->{job}{pid}) {

		carp 'Forks::Super::bg_eval: ',
			"failed to retrieve result from process!\n";
		$self->{value_set} = 1;
		$self->{error} = 
		    'waitpid failed, result not retrieved from process';
		bless $self, $class;
		return '';  # v0.53 on failure return empty string
	    }
	    if ($self->{job}{status} != 0) {
		$self->{error} = 'job status: ' . $self->{job}{status};
	    }
	    # XXX - what other error conditions are there to set ?
	}

	if ($self->{style} eq 'eval') {
	    my $stdout = join'', Forks::Super::read_stdout($self->{job_id});
	    if (!eval {
		$self->{value} = _decode($self->{job}{_lazy_proto}, 
					 $stdout, $self->{job});
		1
		}) {
		$self->{error} ||= $@;
		$self->{value} = undef;
	    }
	    $self->{value_set} = 1;
	} elsif ($self->{style} eq 'qx') {
	    $self->{value_set} = 1;
	    if (defined $self->{stdout}) {
		$self->{value} = $self->{stdout};
	    } else {
		$self->{value} = '';
	    }
	}
    }
    my $value = $self->{value};
    bless $self, $class;
    return $value;
}

1;
