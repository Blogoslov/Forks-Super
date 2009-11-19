use Forks::Super ':test';
use strict;
use warnings;

use Test::More tests => 1;
ok(1);


#
# feature not implemented
#


__END__
-------------------------------------------------------

Feature:	fork with filehandles (socket)

What to test:	sub/natural style
		parent can send data to child through child_stdin{}
		child can send data to parent through child_stdout{}
		child can send data to parent through child_stderr{}
		join_stdout option puts child stdout/stderr through same fh
		parent detects when child is complete and closes filehandles
		parent can clear eof on child filehandles
		clean up
		parent/child back-and-forth proof of concept 
		master/slave proof-of-concept

-------------------------------------------------------
