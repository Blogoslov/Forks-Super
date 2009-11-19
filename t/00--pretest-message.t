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
sleep 3;
ok(1);