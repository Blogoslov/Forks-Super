use Test::More tests => 1;
print STDERR <<'pretest_message_ends';
, 
 
  
#############################################
#                                           #
# In many tests of the Forks::Super module, #
# long delays are induced so that various   #
# timing conditions can be validated.       #
#                                           #
# This does not mean that there is          #
# anything in the Forks::Super package      #
# that will seriously degrade the           #
# performance of your scripts.              #
#                                           #
# On the other hand, it doesn't mean that   #
# there isn't anything wrong with the       #
# module either.                            #
#                                           #
# Anyway, please be patient.                #
#                                           #
#############################################

pretest_message_ends

ok(1);

my $limits_file = "t/out/limits.$^O.$]";
if (-f $limits_file) {
  exit 0;
}


$SIG{ALRM} = \sub { die "find-limits.pl timed out\n" };
eval 'alarm 60';

print STDERR "\nTesting system limitations\n";	
if ($^O	=~ /cygwin/i) {
  print STDERR "On Cygwin, this test can hang for 5 minutes.\n";
}

system($^X, "t/find-limits.pl", $limits_file);

END {
  $SIG{ALRM} = 'DEFAULT';
  eval 'alarm 0';
};
