#  You may distribute under the terms of either the GNU General Public License
#  or the Artistic License (the same terms as Perl itself)
#
#  (C) Paul Evans, 2013 -- leonerd@leonerd.org.uk

package Devel::MAT::Dumper;

use strict;
use warnings;

our $VERSION = '0.04';

require XSLoader;
XSLoader::load( __PACKAGE__, $VERSION );

=head1 NAME

C<Devel::MAT::Dumper> - write a heap dump file for later analysis

=head1 SYNOPSIS

 use Devel::MAT::Dumper;

 Devel::MAT::Dumper::dump( "path/to/the/file.pmat" );

=head1 DESCRIPTION

This module provides the memory-dumping function that creates a heap dump file
which can later be read by L<Devel::MAT::Dumpfile>. It provides a single
function which is not exported, which writes a file to the given path.

The dump file will contain a representation of every SV in Perl's arena,
providing information about pointers between them, as well as other
information about the state of the process at the time it was created. It
contains a snapshot of the process at that moment in time, which can later be
loaded and analysed by various tools using C<Devel::MAT::Dumpfile>.

=cut

=head1 AUTHOR

Paul Evans <leonerd@leonerd.org.uk>

=cut

0x55AA;
