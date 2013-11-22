#  You may distribute under the terms of either the GNU General Public License
#  or the Artistic License (the same terms as Perl itself)
#
#  (C) Paul Evans, 2013 -- leonerd@leonerd.org.uk

package Devel::MAT::Dumper;

use strict;
use warnings;

our $VERSION = '0.09';

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

=head1 IMPORT OPTIONS

The following C<import> options control the behaviour of the module. They may
primarily be useful when used in the C<-M> perl option:

=head2 -dump_at_END

Installs an C<END> block which writes a dump file at C<END> time, just before
the interpreter exits.

 $ perl -MDevel::MAT::Dumper=-dump_at_END ...

=head2 -dump_at_SIGABRT

Installs a handler for C<SIGABRT> to write a dump file if the signal is
received. After dumping the file, the signal handler is removed and the signal
re-raised.

 $ perl -MDevel::MAT::Dumper=-dump_at_SIGABRT ...

=head2 -dump_at_SIGQUIT

Installs a handler for C<SIGQUIT> to write a dump file if the signal is
received. The signal handler will remain in place and can be used several
times.

 $ perl -MDevel::MAT::Dumper=-dump_at_SIGQUIT ...

=head2 -file $PATH

Sets the name of the file which is automatically dumped; defaults to
F<$0.pmat> if not supplied.

 $ perl -MDevel::MAT::Dumper=-file,foo.pmat ...

=cut

my $dumpfile_name = "$0.pmat";

my $dump_at_END;
END {
   Devel::MAT::Dumper::dump( $dumpfile_name ) if $dump_at_END;
}

sub import
{
   my $pkg = shift;

   while( @_ ) {
      my $sym = shift;

      if( $sym eq "-dump_at_END" ) {
         $dump_at_END++;
      }
      elsif( $sym eq "-dump_at_SIGABRT" ) {
         $SIG{ABRT} = sub {
            Devel::MAT::Dumper::dump( $dumpfile_name );
            undef $SIG{ABRT};
            kill ABRT => $$;
         };
      }
      elsif( $sym eq "-dump_at_SIGQUIT" ) {
         $SIG{QUIT} = sub {
            Devel::MAT::Dumper::dump( $dumpfile_name );
         };
      }
      elsif( $sym eq "-file" ) {
         $dumpfile_name = shift;
      }
      else {
         die "Unrecognised $pkg import symbol $sym\n";
      }
   }
}

=head1 AUTHOR

Paul Evans <leonerd@leonerd.org.uk>

=cut

0x55AA;
