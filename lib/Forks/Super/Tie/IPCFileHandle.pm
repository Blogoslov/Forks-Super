#
# tied filehandle class for interprocess communication file and socket
# handles. This class is mainly for facilitating testing and debugging.
# We ought to be able to drop in and drop out this class without
# changing the behavior of any application using Forks::Super.
#

# as of Forks::Super v0.35 this package is still being
# improved and evaluated, and is not being referenced by
# any other part of this module

package Forks::Super::Tie::IPCFileHandle;

use Exporter;
our @ISA = qw(Exporter);
# use base qw(Exporter);

use strict;
use warnings;
use Carp;
use IO::Handle;
# use Time::HiRes;

our @EXPORT = qw(tieopen tiesocketpair);
our $DEBUG = defined($ENV{XFH}) && $ENV{XFH} > 1;
if ($DEBUG) {
  open TTY, '>&2';   # original STDERR
}

*_gensym = \&Forks::Super::Job::Ipc::_gensym;


sub _printtty ($$;@) {
  my ($self,$func,@msg) = @_;
  return unless $DEBUG;
  return unless $self;
  open LOCK, '>>', '/tmp/lock';
  flock LOCK, 2;

  print TTY $$ == $Forks::Super::MAIN_PID ? "PPPPPP $$ " : "CCCCCC $$ ";
  print TTY $func, " DEBUG=$DEBUG XFH=$ENV{XFH} ";
  print TTY " on ", *$self, " ", $$self->{name} || '<unknown>';
  print TTY " [", $$self->{$func} || '';
  print TTY "] :";
  print TTY "@msg\n";

  close LOCK;
}

sub TIEHANDLE {
  my ($class, %props) = @_;
  my $self = bless _gensym(), $class;
  $$self->{$_} = $props{$_} for keys %props;
  $$self->{created} = Time::HiRes::gettimeofday();
  return $self;
}

#############################################################################

sub OPEN {
  my ($self, $mode, $expr) = @_;
  $$self->{OPEN}++;
  my ($result, $new_err);
  my $old_err = $!;
  my $glob = *$self;

  $$self->{mode} = $mode;
  $$self->{filename} ||= $expr || '';

  {
    local $! = 0;
    if (defined $expr) {
      _printtty $self, "OPEN", " $mode + $expr";
      $result = open $glob, $mode, $expr;
    } else {
      _printtty $self, "OPEN", " $mode ";
      $result = open $glob, $mode;
    }
    $$self->{closed} = 1 if !$result;
    $$self->{open_error} = $new_err = $_;
  }
  $! = $new_err || $old_err;
  return $result;
}

sub BINMODE {
  my ($self, $discipline) = @_;
  $$self->{BINMODE}++;
  return binmode *$self, $discipline || ":raw";
}

sub READLINE {
  my $self = shift;
  $$self->{READLINE}++;
  my $glob = *$self;

  _printtty $self, "READLINE";

  return <$glob>;
}

sub FILENO {
  my $self = shift;
  $$self->{FILENO}++;
  my $glob = *$self;
  return $$self->{fileno} ||= fileno($glob);
}

sub SEEK {
  my ($self, $whence, $position) = @_;
  $$self->{SEEK}++;
  my $glob = *$self;
  return seek $glob, $whence, $position;
}

sub GETC {
  my $self = shift;
  $$self->{GETC}++;
  my $glob = *$self;
  return getc($glob);
}

sub READ {
  my ($self, undef, $length, $offset) = @_;
  $$self->{READ}++;
  my $glob = *$self;
  return read $glob, $_[1], $length, $offset;
}

sub PRINT {
  my $self = shift;
  $$self->{PRINT}++;
  my $glob = *$self;

  _printtty $self, "PRINT", "$_[0] ...";

  if ($$self->{closed}) {

    carp "print on closed fh ", *$self, " ", 
      $$self->{name}||'', " closed=",$$self->{closed},"\n";
    return;

  }
  my $z = print $glob @_;
  IO::Handle::flush($glob);
  return $z;
}

sub PRINTF {
  my $self = shift;
  $$self->{PRINTF}++;
  my $glob = *$self;

  _printtty $self, "PRINT", "$_[0] ...";

  if ($$self->{closed}) {

    carp "printf on closed fh ", $$self->{name}, "\n";
    return;

  }
  seek $glob, 0, 2;
  printf $glob  @_;
}

sub TELL {
  my $self = shift;
  $$self->{TELL}++;
  my $glob = *$self;
  return tell $glob;
}

sub WRITE {
  my ($self, $string, $length, $offset) = @_;
  $$self->{WRITE}++;
  my $glob = *$self;

  if ($$self->{closed}) {

    carp "write/syswrite on closed fh ", $$self->{name}, "\n";
    return;

  }
  seek $glob, 0, 2;
  return syswrite $glob, $string, $length||length($string), $offset||0;
}

sub CLOSE {
  my $self = shift;
  $$self->{CLOSE}++;
  my $glob = *$self;

  _printtty $self, "CLOSE";

  if (!$$self->{closed}) {
    $$self->{closed} = Time::HiRes::gettimeofday();

    my $elapsed = $$self->{closed} - $$self->{opened}||$$self->{created}||$^T;
    $$self->{elapsed} = $elapsed;
    my $result = close $glob;
    untie *$self;
    return $result;
  }
  return;
}

sub EOF {
  my $self = shift;
  my $glob = *$self;
  return eof $glob;
}

######################################################################

sub tieopen (*$;$@) {
  my $props = pop @_;
  my ($glob, $mode, $expr, @list) = @_;
  my $result;

  $glob = _gensym() if !defined $glob;

  my ($pkg, $file, $line) = caller;
  my $tied;
  if (1) {
    $tied = tie *$glob, 'Forks::Super::Tie::IPCFileHandle', %$props;
    $$tied->{opened} = Time::HiRes::gettimeofday();
    $$tied->{open_caller} = "$pkg ; $file:$line";
    $$tied->{name} = sprintf "%d:%s%s", $$, $mode, 
      ($expr||$props->{filename}||'') . "@list";
    foreach my $prop (keys %$props) {
      $$tied->{$prop} = $props->{$prop};
    }
  }

  if (!defined $expr) {
    $result = open $glob, $mode;
  } elsif (@list == 0) {
    $result = open $glob, $mode, $expr;
  } else {
    $result = open $glob, $mode, $expr, @list;
  }
  $$tied->{open_result} = $result;
  $_[0] = $glob;
  if ($result) {
    $$tied->{fileno} = fileno($glob);
  }
  return $result;
}

##################################################################

1;
