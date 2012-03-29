#
# Forks::Super::Tie::BackgroundArray - lazy evaluation of a perl
#    expression in list context
#

package Forks::Super::Tie::BackgroundArray;
use Forks::Super;
use Forks::Super::Wait 'WREAP_BG_OK';
use Carp;
use strict;
use warnings;

our $VERSION = '0.63';

# "protocols" for serializing data and the methods used
# to carry out the serialization

my %serialization_dispatch = (

    YAML => {
	require => sub { require YAML },
	encode => sub { return YAML::Dump( \@_ ) },
	decode => sub { return YAML::Load($_[0]) }
    },

    JSON1 => {
	require => sub { require JSON },
	encode => sub { return JSON->new->objToJson( \@_ ); },
	decode => sub { return JSON->new->jsonToObj($_[0]) }
    },

    JSON2 => {
	require => sub { require JSON },
	encode => sub { return JSON::encode_json( \@_ ); },
	decode => sub { return JSON::decode_json($_[0]) }
    },

    'Data::Dumper' => {
	require => sub { require Data::Dumper },
	encode => sub { return Data::Dumper::Dumper( \@_ ) },
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
	encode => sub { return YAML::Tiny::Dump( \@_ ) },
	decode => sub { return YAML::Tiny::Load($_[0]) }
    },

    );

# an array that is evaluated in a child process.
# the first time an element of the array is dereferenced,
# retrieve the output from the child,
# waiting for the child to finish if necessary

sub new {
    my ($class, $style, $command_or_code, %other_options) = @_;
    my $self = { value_set => 0, value => undef, style => $style };
    if ($style eq 'eval') {
	my $protocol = $other_options{'protocol'};
	$self->{code} = $command_or_code;
	$self->{job_id} = Forks::Super::fork {
	    (%other_options,
	     child_fh => 'out',
	     sub => sub {
		 my @result = $command_or_code->();
		 print STDOUT _encode($protocol, @result);
	     }, 
	     _is_bg => 2, 
	     _lazy_proto => $protocol )
	};

    } elsif ($style eq 'qx') {
	croak "Always use F::S::Tie::BackgroundScalar with bg_qx\n";
	$self->{command} = $command_or_code;
	$self->{delimiter} = $/;
	$self->{stdout} = '';
	$self->{job_id} = Forks::Super::fork {
	    %other_options, child_fh => 'out',
	    cmd => $command_or_code,
	    stdout => \$self->{stdout},
	    _is_bg => 2};
    }
    $self->{job} = Forks::Super::Job::get($self->{job_id});
    ($Forks::Super::LAST_JOB, $Forks::Super::LAST_JOB_ID)
	= ($self->{job}, $self->{job_id});
    $self->{value} = [];
    return bless $self, $class;
}

sub _encode {
    my ($protocol, @data) = @_;
    if (defined $serialization_dispatch{$protocol}) {
	$serialization_dispatch{$protocol}{'require'}->();
	return $serialization_dispatch{$protocol}{encode}->(@data);
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

sub _fetch {
    my $self = shift;
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
		return ();  # v0.53 on failure return empty string
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
		$self->{value} = [];
	    } elsif (ref $self->{value} ne 'ARRAY') {

		if ($self->{value} eq '') {
		    $self->{value} = [];
		} else {
		    $self->{value} = [];
		}
	    }
	    $self->{value_set} = 1;
	} else {
	    croak "expect  style  to be 'eval' in F::S::Tie::BackgroundArray";
	}
    }
    my $value = $self->{value};
    bless $self, $class;
    return @$value;
}

1;
