#  You may distribute under the terms of either the GNU General Public License
#  or the Artistic License (the same terms as Perl itself)
#
#  (C) Paul Evans, 2013-2014 -- leonerd@leonerd.org.uk

package Devel::MAT::Dumper;

use strict;
use warnings;

our $VERSION = '0.20';

use File::Basename qw( basename );

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

=head2 -dump_at_DIE

Installs a handler for the special C<__DIE__> signal to write a dump file when
C<die()> is about to cause a fatal signal. This is more reliable at catching
the callstack and memory state than using an C<END> block.

 $ perl -MDevel::MAT::Dumper=-dump_at_DIE ...

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

Sets the name of the file which is automatically dumped; defaults to basename
F<$0.pmat> if not supplied.

 $ perl -MDevel::MAT::Dumper=-file,foo.pmat ...

If the pattern contains C<NNN>, this will be replaced by a unique serial
number per written file, starting from 0. This may be helpful in the case of
C<DIE> or C<SIGQUIT> handlers, which could be invoked multiple times.

=head2 -max_string

Sets the maximum length of string buffer to dump from PVs; defaults to 256 if
not supplied. Use a negative size to dump the entire buffer of every PV
regardless of size.

=head2 -eager_open

Opens the dump file immediately at C<import> time, instead of waiting until
the time it actually writes the heap dump. This may be useful if the process
changes working directory or user ID, or to debug problems involving too many
open filehandles.

=cut

our $MAX_STRING = 256; # used by XS code

my $dumpfile_name = basename( $0 ) . ".pmat";
my $dumpfh;
my $next_serial = 0;

my $dump_at_END;
END {
   return unless $dump_at_END;

   if( $dumpfh ) {
      Devel::MAT::Dumper::dumpfh( $dumpfh );
   }
   else {
      ( my $file = $dumpfile_name ) =~ s/NNN/$next_serial++/e;
      print STDERR "Dumping to $file because of END\n";
      Devel::MAT::Dumper::dump( $file );
   }
}

sub import
{
   my $pkg = shift;

   my $eager_open;

   while( @_ ) {
      my $sym = shift;

      if( $sym eq "-dump_at_DIE" ) {
         my $old_DIE = $SIG{__DIE__};
         $SIG{__DIE__} = sub {
            local $SIG{__DIE__} = $old_DIE if defined $old_DIE;
            die @_ if $^S;

            ( my $file = $dumpfile_name ) =~ s/NNN/$next_serial++/e;
            print STDERR "Dumping to $file because of DIE\n";
            Devel::MAT::Dumper::dump( $file );
            die @_;
         };
      }
      elsif( $sym eq "-dump_at_END" ) {
         $dump_at_END++;
      }
      elsif( $sym eq "-dump_at_SIGABRT" ) {
         $SIG{ABRT} = sub {
            ( my $file = $dumpfile_name ) =~ s/NNN/$next_serial++/e;
            print STDERR "Dumping to $file because of SIGABRT\n";
            Devel::MAT::Dumper::dump( $file );
            undef $SIG{ABRT};
            kill ABRT => $$;
         };
      }
      elsif( $sym eq "-dump_at_SIGQUIT" ) {
         $SIG{QUIT} = sub {
            ( my $file = $dumpfile_name ) =~ s/NNN/$next_serial++/e;
            print STDERR "Dumping to $file because of SIGQUIT\n";
            Devel::MAT::Dumper::dump( $file );
         };
      }
      elsif( $sym eq "-file" ) {
         $dumpfile_name = shift;
      }
      elsif( $sym eq "-max_string" ) {
         $MAX_STRING = shift;
      }
      elsif( $sym eq "-eager_open" ) {
         $eager_open++;
      }
      else {
         die "Unrecognised $pkg import symbol $sym\n";
      }
   }

   if( $eager_open ) {
      open $dumpfh, ">", $dumpfile_name or
         die "Cannot open $dumpfile_name for writing - $!\n";
   }
}

=head1 FUNCTIONS

These functions are not exported, they must be called fully-qualified.

=head2 dump( $path )

Writes a heap dump to the named file

=head2 dumpfh( $fh )

Writes a heap dump to the given filehandle (which must be a plain OS-level
filehandle, though does not need to be a regular file, or seekable).

=cut

=head1 AUTHOR

Paul Evans <leonerd@leonerd.org.uk>

=cut

0x55AA;
