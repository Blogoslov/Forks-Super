#
# Forks::Super::Debug package - manage Forks::Super module-specific
#         debugging messages
#

package Forks::Super::Debug;
use Forks::Super::Util;
use IO::Handle;
use Exporter;
use Carp;
use strict;
use warnings;

our @ISA = qw(Exporter);
our @EXPORT_OK = qw(debug $DEBUG carp_once);
our %EXPORT_TAGS = (all => [ @EXPORT_OK ]);
our $VERSION = '0.54';

our ($DEBUG, $DEBUG_FH, %_CARPED, 
     $OLD_SIG__WARN__, $OLD_SIG__DIE__, $OLD_CARP_VERBOSE);

## no critic (BriefOpen,TwoArgOpen)

# initialize $DEBUG_FH.
do {
    if (uc($ENV{FORKS_SUPER_DEBUG} || '') eq 'TTY') {
	my $console = $^O eq 'MSWin32' ? 'CON' : '/dev/tty';
	eval { open($DEBUG_FH, '>:encoding(UTF-8)', $console) } 
	or eval { open($DEBUG_FH, '>', $console) }
	or 0;
    } else {
	0;
    }
} or open($DEBUG_FH, '>&2')
    or $DEBUG_FH = *STDERR
    or carp_once('Forks::Super: Debugging not available in module!');

## use critic
$DEBUG_FH->autoflush(1);
$DEBUG = !!$ENV{FORKS_SUPER_DEBUG} || '0';

sub init {
}

sub debug {
    my @msg = @_;
    print {$DEBUG_FH} $$,' ',Forks::Super::Util::Ctime(),' ',@msg,"\n";
    return;
}

# sometimes we only want to print a warning message once
sub carp_once {
    my @msg = @_;
    my ($p,$f,$l) = caller;
    my $z = '';
    if (ref $msg[0] eq 'ARRAY') {
	$z = join ';', @{$msg[0]};
	shift @msg;
    }
    return if $_CARPED{"$p:$f:$l:$z"}++;
    return carp @msg;
}

# load or emulate Carp::Always for the remainder of the program
sub use_Carp_Always {
    if (!defined $OLD_CARP_VERBOSE) {
	$OLD_CARP_VERBOSE = $Carp::Verbose;
    }
    $Carp::Verbose = 'verbose';
    if (!defined($OLD_SIG__WARN__)) {
	$OLD_SIG__WARN__ = $SIG{__WARN__} || 'DEFAULT';
	$OLD_SIG__DIE__ = $SIG{__DIE__} || 'DEFAULT';
    }
    ## no critic (RequireCarping)
    $SIG{__WARN__} = sub { warn &Carp::longmess };
    $SIG{__DIE__} = sub { warn &Carp::longmess };
    return 1;
}

# stop emulation of Carp::Always
sub no_Carp_Always {
  $Carp::Verbose = $OLD_CARP_VERBOSE || 0;
  $SIG{__WARN__} = $OLD_SIG__WARN__ || 'DEFAULT';
  $SIG{__DIE__} = $OLD_SIG__DIE__ || 'DEFAULT';
  return;
}

#############################################################################

# display some information about filehandles that were opened by
# Forks::Super and are still open. I didn't intend for anyone else
# to use this, but feel free.
sub __debug_open_filehandles {
    use POSIX ();

    print STDERR "Open FH count is ",
           "$Forks::Super::Job::Ipc::__OPEN_FH in ",
           scalar keys %Forks::Super::Job::Ipc::__OPEN_FH, " fds\n";

    # where are the open filehandles?
    my %jobs;
    while ( my($fileno, $job) = each %Forks::Super::Job::Ipc::__OPEN_FH) {

	my $pid = $job->{real_pid} || $job->{pid};
	$jobs{$pid} ||= [];

	push @{$jobs{$pid}}, $fileno;
    }

    foreach my $pid (sort {$a <=> $b} keys %jobs) {

	my @filenos = @{$jobs{$pid}};
	my ($m,$n) = (0,0);
	foreach (@filenos) {
	    $n++;
	    if (defined POSIX::close($_)) {
		$m++;
	    }
	}
	print STDERR "Open FH in $pid: @filenos   Close $m/$n\n";
    }
    return;
}

1;

=head1 NAME

Forks::Super::Debug - debugging and logging routines for Forks::Super distro

=head1 VERSION

0.54

=head1 VARIABLES

=head2 $DEBUG

Many routines in the L<Forks::Super|Forks::Super> module look at this
variable to decide whether to invoke the L<"debug"> function. So if
this variable is set to true, a lot of information about what the
L<Forks::Super|Forks::Super> module is doing will be written to the
debugging output stream.

If the environment variable C<FORKS_SUPER_DEBUG> is set, the C<$DEBUG>
variable will take on its value. Otherwise, the default value of this
variable is zero.

=head2 $DEBUG_FH

An output file handle for all debugging messages. Initially, this module
tries to open C<$DEBUG_FH> as an output handle to the current tty (C<CON>
on MSWin32). If that fails, it will try to dup file descriptor 2 (which
is usually C<STDERR>) or alias C<$DEBUG_FH> directly to C<*STDERR>.

The initial setting can be overwritten at runtime. See C<t/15-debug.t>
in this distribution for an example.

=head1 FUNCTIONS

=head2 debug

Output the given message to the current C<$DEBUG_FH> file handle.
Usually you check whether C<$DEBUG> is set to a true value before
calling this function.

=head2 carp_once

Like L<"carp" in Carp|Carp/"carp">, but remembers what warning 
messages have already been printed and suppresses duplicate messages.
This is useful for heavily used code paths that usually work, but tend
to produce an enormous number of warnings when they don't.

    use Forks::Super::Debug 'carp_once';
    for (1 .. 9999) {
        $var = &some_function_that_should_be_zero_but_sometimes_isnt;
        if ($var != 0) {
            carp_once "var was $var, not zero!";
        }
    }

should produce at most one warning in the lifetime of the program,

C<carp_once> can take a list reference as an optional first argument
to provide additional context for the warning message. This code,
for example, will produce one warning message for every different 
value of C<$!> that can be produced.

    while (<$fh>) {
        local $! = 0;
        do_something($_);
        if ($!) {
            carp_once [$!], "do_something() did something!: $!";
        }
    }

=head1 EXPORTS

This module exports the C<$DEBUG> variable and the C<debug> and
C<carp_once> methods.
The C<:all> tag exports all of these symbols.

=head1 SEE ALSO

L<Forks::Super|Forks::Super>, L<Carp|Carp>

=head1 AUTHOR

Marty O'Brien, E<lt>mob@cpan.orgE<gt>

=head1 LICENSE AND COPYRIGHT

Copyright (c) 2009-2011, Marty O'Brien.

This library is free software; you can redistribute it and/or modify
it under the same terms as Perl itself, either Perl version 5.8.8 or,
at your option, any later version of Perl 5 you may have available.

See http://dev.perl.org/licenses/ for more information.

=cut
