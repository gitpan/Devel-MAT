#  You may distribute under the terms of either the GNU General Public License
#  or the Artistic License (the same terms as Perl itself)
#
#  (C) Paul Evans, 2013 -- leonerd@leonerd.org.uk

package Devel::MAT::Dumpfile;

use strict;
use warnings;

our $VERSION = '0.04';

use Carp;
use IO::Handle;   # ->read
use IO::Seekable; # ->tell

use Devel::MAT::SV;

use List::Util qw( pairs );

=head1 NAME

C<Devel::MAT::Dumpfile> - load and analyse a heap dump file

=head1 SYNOPSIS

 use Devel::MAT::Dumpfile;

 my $df = Devel::MAT::Dumpfile->load( "path/to/the/file.pmat" );

 TODO

=head1 DESCRIPTION

This module provides a class that loads a heap dump file previously written by
L<Devel::MAT::Dumper>. It provides accessor methods to obtain various
well-known root starting addresses, or to find arbitrary SVs by address. Each
SV is represented by an instance of L<Devel::MAT::SV>.

=cut

my @ROOTS;
my %ROOTDESC;
foreach (
   [ maincv        => "the main code" ],
   [ defstash      => "the default stash" ],
   [ mainstack     => "the main stack AV" ],
   [ beginav       => "the BEGIN list" ],
   [ checkav       => "the CHECK list" ],
   [ unitcheckav   => "the UNITCHECK list" ],
   [ initav        => "the INIT list" ],
   [ endav         => "the END list" ],
   [ strtabhv      => "the shared string table HV" ],
   [ envgv         => "the ENV GV" ],
   [ incgv         => "the INC GV" ],
   [ statgv        => "the stat GV" ],
   [ statname      => "the statname SV" ],
   [ tmpsv         => "the temporary SV" ],
   [ defgv         => "the default GV" ],
   [ argvgv        => "the ARGV GV" ],
   [ argvoutgv     => "the argvout GV" ],
   [ argvout_stack => "the argvout stack AV" ],
   [ fdpidav       => "the FD-to-PID mapping AV" ],
   [ preambleav    => "the compiler preamble AV" ],
   [ modglobalhv   => "the module data globals HV" ],
   [ regex_padav   => "the REGEXP pad AV" ],
   [ sortstash     => "the sort stash" ],
   [ firstgv       => "the *a GV" ],
   [ secondgv      => "the *b GV" ],
   [ debstash      => "the debugger stash" ],
   [ stashcache    => "the stash cache" ],
   [ isarev        => "the reverse map of \@ISA dependencies" ],
   [ mros          => "the registered MROs HV" ],
) {
   my ( $name, $desc ) = @$_;
   push @ROOTS, $name;
   $ROOTDESC{$name} = $desc;

   # Autogenerate the accessors
   my $name_at = "${name}_at";
   my $code = sub { my $self = shift; $self->sv_at( $self->{$name_at} ) };
   no strict 'refs';
   *$name = $code;
}

=head1 CONSTRUCTOR

=cut

=head2 $df = Devel::MAT::Dumpfile->load( $path, %args )

Loads a heap dump file from the given path, and returns a new
C<Devel::MAT::Dumpfile> instance representing it.

Takes the following named arguments:

=over 8

=item progress => CODE

If given, should be a CODE reference to a function that will be called
regularly during the loading process, and given a status message to update the
user.

=back

=cut

sub load
{
   my $class = shift;
   my ( $path, %args ) = @_;

   my $progress = $args{progress};

   $progress->( "Loading file $path..." ) if $progress;

   open my $fh, "<", $path or croak "Cannot read $path - $!";
   my $self = bless { fh => $fh }, $class;

   my $filelen = -s $fh;

   # Header
   $self->_read(4) eq "PMAT" or croak "File magic signature not found";

   my $flags = $self->_read_u8;

   my $endian = ( $self->{big_endian} = $flags & 0x01 ) ? ">" : "<";

   my $u32_fmt = $self->{u32_fmt} = "L$endian";
   my $u64_fmt = $self->{u64_fmt} = "Q$endian";

   @{$self}{qw( uint_len uint_fmt )} =
      ( $flags & 0x02 ) ? ( 8, $u64_fmt ) : ( 4, $u32_fmt );

   @{$self}{qw( ptr_len ptr_fmt )} =
      ( $flags & 0x04 ) ? ( 8, $u64_fmt ) : ( 4, $u32_fmt );

   @{$self}{qw( nv_len nv_fmt )} =
      ( $flags & 0x08 ) ? ( 10, "D$endian" ) : ( 8, "d$endian" );

   $self->{ithreads} = !!( $flags & 0x10 );

   $flags &= ~0x1f;
   die sprintf "Cannot read %s - unrecognised flags %x\n", $path, $flags if $flags;

   $self->{minus_1} = unpack $self->{uint_fmt}, pack $self->{uint_fmt}, -1;

   $self->_read_u8 == 0 or die "Cannot read $path - 'zero' header field is not zero";

   unpack( "S>", $self->_read(2) ) == 0 or die "Cannot read $path - unrecognised file version";

   $self->{perlver} = $self->_read_u32;

   # Roots
   foreach (qw( undef yes no )) {
      my $addr = $self->{"${_}_at"} = $self->_read_ptr;
      my $class = "Devel::MAT::SV::\U$_";
      $self->{uc $_} = $class->_new( $self, $addr );
   }
   foreach (@ROOTS) {
      $self->{"${_}_at"} = $self->_read_ptr;
   }

   # Stack
   my $stacksize = $self->_read_uint;
   $self->{stack_at} = [ map { $self->_read_ptr } 1 .. $stacksize ];

   $self->{heap} = \my %heap;
   while( my $sv = $self->_read_sv ) {
      $heap{$sv->addr} = $sv;

      my $pos = $fh->tell;
      $progress->( sprintf "Loading file %d of %d (%.2f%%)",
         $pos, $filelen, 100*$pos / $filelen ) if $progress and (keys(%heap) % 1000) == 0;
   }

   $self->_fixup( %args ) unless $args{no_fixup};

   return $self;
}

sub _fixup
{
   my $self = shift;
   my %args = @_;

   my $progress = $args{progress};

   my $heap = $self->{heap};

   my $heap_total = scalar keys %$heap;

   # While dumping we weren't able to determine what ARRAYs were really
   # PADLISTs. Now we can fix them up
   my $count = 0;
   while( my ( $addr ) = each %$heap ) {
      my $sv = $heap->{$addr} or next;
      $sv->_fixup if $sv->can( "_fixup" );
      $count++;
      $progress->( sprintf "Fixing %d of %d (%.2f%%)",
         $count, $heap_total, 100*$count / $heap_total ) if $progress and ($count % 1000) == 0;
   }

   # Now fix up all the inrefs
   $count = 0;
   while( my ( undef, $sv ) = each %$heap ) {
      foreach ( pairs $sv->outrefs ) {
         my ( $name, $ref ) = @$_;
         $ref->_push_inref_at( $sv->addr ) if !$ref->immortal;
      }
      $count++;
      $progress->( sprintf "Patching refs in %d of %d (%.2f%%)",
         $count, $heap_total, 100*$count / $heap_total ) if $progress and ($count % 200) == 0
   }

   foreach (@ROOTS) {
      my $root = $self->sv_at( $self->{"${_}_at"} );
      $root->_push_inref_at( "the $_ root" ) if defined $root;
   }
   foreach my $addr ( @{ $self->{stack_at} } ) {
      my $sv = $self->sv_at( $addr ) or next;
      $sv->_push_inref_at( "a value on the stack" );
   }

   return $self;
}

# Nicer interface to IO::Handle
sub _read
{
   my $self = shift;
   my ( $len ) = @_;
   return "" if $len == 0;
   $self->{fh}->read( my $buf, $len ) or croak "Cannot read - $!";
   return $buf;
}

sub _read_u8
{
   my $self = shift;
   return unpack "C", $self->_read(1);
}

sub _read_u32
{
   my $self = shift;
   return unpack $self->{u32_fmt}, $self->_read(4);
}

sub _read_u64
{
   my $self = shift;
   return unpack $self->{u64_fmt}, $self->_read(8);
}

sub _read_uint
{
   my $self = shift;
   return unpack $self->{uint_fmt}, $self->_read($self->{uint_len});
}

sub _read_ptr
{
   my $self = shift;
   return unpack $self->{ptr_fmt}, $self->_read($self->{ptr_len});
}

sub _read_nv
{
   my $self = shift;
   return unpack $self->{nv_fmt}, $self->_read($self->{nv_len});
}

sub _read_str
{
   my $self = shift;
   my $len = $self->_read_uint;
   return undef if $len == $self->{minus_1};
   return $self->_read($len);
}

sub _read_sv
{
   my $self = shift;

   while(1) {
      my $type = $self->_read_u8;
      return if !$type;

      if( $type == 0x80 ) {
         # magic
         my $sv_addr = $self->_read_ptr;
         my $obj     = $self->_read_ptr;
         my $type    = chr $self->_read_u8;

         $self->sv_at( $sv_addr )->more_magic( $type => $obj );
         next;
      }

      return Devel::MAT::SV->load( $type, $self );
   }
}

=head1 METHODS

=cut

=head2 $version = $df->perlversion

Returns the version of perl that the heap dump file was created by, as a
string in the form C<5.14.2>.

=cut

sub perlversion
{
   my $self = shift;
   my $v = $self->{perlver};
   return join ".", $v>>24, ($v>>16) & 0xff, $v&0xffff;
}

=head2 $endian = $df->endian

Returns the endian direction of the perl that the heap dump was created by, as
either C<big> or C<little>.

=cut

sub endian
{
   my $self = shift;
   return $self->{big_endian} ? "big" : "little";
}

=head2 $len = $df->uint_len

Returns the length in bytes of a uint field of the perl that the heap dump was
created by.

=cut

sub uint_len
{
   my $self = shift;
   return $self->{uint_len};
}

=head2 $len = $df->ptr_len

Returns the length in bytes of a pointer field of the perl that the heap dump
was created by.

=cut

sub ptr_len
{
   my $self = shift;
   return $self->{ptr_len};
}

=head2 $len = $df->nv_len

Returns the length in bytes of a double field of the perl that the heap dump
was created by.

=cut

sub nv_len
{
   my $self = shift;
   return $self->{nv_len};
}

=head2 $ithreads = $df->ithreads

Returns a boolean indicating whether ithread support was enabled in the perl
that the heap dump was created by.

=cut

sub ithreads
{
   my $self = shift;
   return $self->{ithreads};
}

=head2 %roots = $df->roots

Returns a key/value pair list giving the names and SVs at each of the roots.

=cut

sub roots
{
   my $self = shift;
   return map { +$ROOTDESC{$_} => $self->sv_at( $self->{"${_}_at"} ) } @ROOTS;
}

=head2 $sv = $df->ROOT

For each of the root names given below, a method exists with that name which
returns the SV at that root:

 maincv
 defstash
 mainstack
 beginav
 checkav
 unitcheckav
 initav
 endav
 strtabhv
 envgv
 incgv
 statgv
 statname
 tmpsv
 defgv
 argvgv
 argvoutgv
 argvout_stack
 fdpidav
 preambleav
 modglobalhv
 regex_padav
 sortstash
 firstgv
 secondgv
 debstash
 stashcache
 isarev
 mros

=cut

=head2 @svs = $df->heap

Returns all of the heap-allocated SVs, in no particular order

=cut

sub heap
{
   my $self = shift;
   return values %{ $self->{heap} };
}

=head2 $sv = $df->sv_at( $addr )

Returns the SV at the given address, or C<undef> if one does not exist.

(Note that this is unambiguous, as a Perl-level C<undef> is represented by the
immortal C<Devel::MAT::SV::UNDEF> SV).

=cut

sub sv_at
{
   my $self = shift;
   my ( $addr ) = @_;
   return undef if !$addr;

   return $self->{UNDEF} if $addr == $self->{undef_at};
   return $self->{YES}   if $addr == $self->{yes_at};
   return $self->{NO}    if $addr == $self->{no_at};

   return $self->{heap}{$addr};
}

=head2 @text = $df->identify( $sv )

Traces the tree of inrefs from C<$sv> back towards the known roots, returning
a textual description as a list of lines of text.

The lines of text, when printed, will form a reverse reference tree, showing
the paths from the given SV back to the roots.

=cut

sub identify
{
   my $self = shift;
   my ( $sv, $seen ) = @_;
   my $svaddr = $sv->addr;

   return ( "undef" ) if $svaddr == $self->{undef_at};
   return ( "true" )  if $svaddr == $self->{yes_at};
   return ( "false" ) if $svaddr == $self->{no_at};

   foreach my $root ( @ROOTS ) {
      return $ROOTDESC{$root} if $svaddr == $self->{"${root}_at"};
   }

   $seen ||= { $sv->addr => 1 };

   my @ret = ();
   my %inrefs = $sv->inrefs;
   foreach my $desc ( sort keys %inrefs ) {
      my $ref = $inrefs{$desc};

      my @me;
      if( $ref == $sv ) {
         @me = "itself";
      }
      elsif( $seen->{$ref->addr} ) {
         @me = "already found";
      }
      else {
         @me = $self->identify( $ref, $seen );
      }

      $seen->{$ref->addr}++;

      push @ret,
         sprintf( "%s of %s, which is:", $desc, $ref->desc_addr ),
         map { "  $_" } @me;
   }

   return "not found" unless @ret;
   return @ret;
}

=head1 AUTHOR

Paul Evans <leonerd@leonerd.org.uk>

=cut

0x55AA;
