#  You may distribute under the terms of either the GNU General Public License
#  or the Artistic License (the same terms as Perl itself)
#
#  (C) Paul Evans, 2013-2014 -- leonerd@leonerd.org.uk

package Devel::MAT::SV;

use strict;
use warnings;
use feature qw( switch );
no if $] >= 5.017011, warnings => 'experimental::smartmatch';

our $VERSION = '0.19';

use Carp;
use Scalar::Util qw( weaken );
use List::Util qw( pairgrep pairmap pairs );

# Load XS code
require Devel::MAT;

use constant immortal => 0;

use Struct::Dumb qw( readonly_struct );
readonly_struct Reference => [qw( name strength sv )];

=head1 NAME

C<Devel::MAT::SV> - represent a single SV from a heap dump

=head1 DESCRIPTION

Objects in this class represent individual SV variables found in the arena
during a heap dump. Actual types of SV are represented by subclasses, which
are documented below.

=cut

# Lexical subs, so all inline subclasses can see it
my $direct_or_rv = sub {
   my ( $name, $sv ) = @_;
   if( defined $sv and $sv->type eq "REF" and !$sv->{magic} ) {
      return ( "+$name" => $sv,
               ";$name via RV" => $sv->rv );
   }
   else {
      return ( "+$name" => $sv );
   }
};

my $indirect_or_rv = sub {
   my ( $name, $sv ) = @_;
   if( defined $sv and $sv->type eq "REF" and !$sv->{magic} ) {
      return ( ";$name" => $sv,
               ";$name via RV" => $sv->rv );
   }
   else {
      return ( ";$name" => $sv );
   }
};

my %types;
sub register_type
{
   $types{$_[1]} = $_[0];
   # generate the ->type constant method
   ( my $typename = $_[0] ) =~ s/^Devel::MAT::SV:://;
   no strict 'refs';
   *{"$_[0]::type"} = sub () { $typename };
}

sub new
{
   shift;
   my ( $type, $df, $header, $ptrs, $strs ) = @_;

   my $class = $types{$type} or croak "Cannot load unknown SV type $type";

   my $self = bless {}, $class;

   $self->_set_core_fields(
      $type, $df,
      ( unpack "$df->{ptr_fmt} $df->{u32_fmt} $df->{uint_fmt}", $header ),
      $ptrs->[0],
   );

   return $self;
}

=head1 COMMON METHODS

=cut

=head2 $type = $sv->type

Returns the major type of the SV. This is the class name minus the
C<Devel::MAT::SV::> prefix.

=cut

=head2 $desc = $sv->desc

Returns a string describing the type of the SV and giving a short detail of
its contents. The exact details depends on the SV type.

=cut

=head2 $desc = $sv->desc_addr

Returns a string describing the SV as with C<desc> and giving its address in
hex. A useful way to uniquely identify the SV when printing.

=cut

sub desc_addr
{
   my $self = shift;
   return sprintf "%s at %#x", $self->desc, $self->addr;
}

=head2 $addr = $sv->addr

Returns the address of the SV

=cut

# XS accessor

=head2 $count = $sv->refcnt

Returns the C<SvREFCNT> reference count of the SV

=head2 $count = $sv->refcount_adjusted

Returns the reference count of the SV, adjusted to take account of the fact
that the C<SvREFCNT> value of the backrefs list of a hash or weakly-referenced
object is artificially high.

=cut

# XS accessor

sub refcount_adjusted { shift->refcnt }

=head2 $stash = $sv->blessed

If the SV represents a blessed object, returns the stash SV. Otherwise returns
C<undef>.

=cut

sub blessed
{
   my $self = shift;
   return $self->df->sv_at( $self->blessed_at );
}

=head2 $size = $sv->size

Returns the (approximate) size in bytes of the SV

=cut

# XS accessor

=head2 ( $type, $sv, $type, $sv, ... ) = $sv->magic

Returns a pair list of magic applied to the SV; each giving the type and
target SV.

=cut

# TODO: This interface needs fixing
sub magic
{
   my $self = shift;
   return unless my $magic = $self->{magic};

   my $df = $self->df;
   return map { my ( $type, undef, $obj_at, $ptr_at ) = @$_;
                ( $obj_at ? ( $type => $df->sv_at( $obj_at ) ) : () ),
                ( $ptr_at ? ( $type => $df->sv_at( $ptr_at ) ) : () ) } @$magic;
}

=head2 $av_or_rv = $sv->backrefs

Returns backrefs SV, which may be an AV containing the back references, or
if there is only one, the REF SV itself referring to this.

=cut

sub backrefs
{
   my $self = shift;

   return undef unless my $magic = $self->{magic};

   foreach my $mg ( @$magic ) {
      my ( $type, undef, $obj_at ) = @$mg;
      # backrefs list uses "<" magic type
      return $self->df->sv_at( $obj_at ) if $type eq "<";
   }

   return undef;
}

# internal
sub more_magic
{
   my $self = shift;
   my ( $type, $flags, $obj_at, $ptr_at ) = @_;

   push @{ $self->{magic} }, [ $type => $flags, $obj_at, $ptr_at ];
}

=head2 @refs = $sv->outrefs

Returns a list of Reference objects for each of the SVs that this one refers
to, either directly by strong or weak reference, indirectly via RV, or
inferred by C<Devel::MAT> itself.

Each object is a structure of three fields:

=over 4

=item name => STRING

A human-readable string for identification purposes.

=item strength => "strong"|"weak"|"indirect"|"inferred"

Identifies what kind of reference it is. C<strong> references contribute to
the C<refcount> of the referrant, others do not. C<strong> and C<weak>
references are SV addresses found directly within the referring SV structure;
C<indirect> and C<inferred> references are extra return values added here for
convenience by examining the surrounding structure.

=item sv => SV

The referrant SV itself.

=back

=cut

# Each outref name starts with one of four characters to indicate its type
my %STRENGTH_FROM_PREFIX = (
   "+" => "strong", # direct strong
   "-" => "weak",   # direct weak
   ";" => "indirect",
   "." => "inferred",
);

sub _outrefs_matching
{
   my $self = shift;
   my ( $match ) = @_;

   my @outrefs = pairgrep { defined $b } $self->_outrefs;

   push @outrefs, "-the bless package", $self->blessed if $self->blessed;

   foreach my $mg ( @{ $self->{magic} || [] } ) {
      my ( $type, $flags, $obj_at, $ptr_at ) = @$mg;

      if( my $obj = $self->df->sv_at( $obj_at ) ) {
         my $reftype = ( $flags & 0x01 ) ? "+" : "-";
         push @outrefs, "$reftype'$type' magic object" => $obj;
      }
      if( my $ptr = $self->df->sv_at( $ptr_at ) ) {
         push @outrefs, "+'$type' magic pointer" => $ptr;
      }
   }

   @outrefs = pairgrep { $a =~ m/^$match/ } @outrefs if $match;

   return @outrefs / 2 if !wantarray;

   return pairmap {
      my $prefix = substr( $a, 0, 1, "" );
      Reference( $a, $STRENGTH_FROM_PREFIX{$prefix}, $b )
   } @outrefs;
}

sub outrefs { shift->_outrefs_matching( undef ) }

=head2 @refs = $sv->outrefs_strong

Returns the subset of C<outrefs> that are direct strong references.

=head2 @refs = $sv->outrefs_weak

Returns the subset of C<outrefs> that are direct weak references.

=head2 @refs = $sv->outrefs_direct

Returns the subset of C<outrefs> that are direct strong or weak references.

=head2 @refs = $sv->outrefs_indirect

Returns the subset of C<outrefs> that are indirect references via RVs.

=head2 @refs = $sv->outrefs_inferred

Returns the subset of C<outrefs> that are not directly stored in the SV
structure, but instead inferred by C<Devel::MAT> itself.

=cut

sub outrefs_strong   { shift->_outrefs_matching( qr/\+/   ) }
sub outrefs_weak     { shift->_outrefs_matching( qr/-/    ) }
sub outrefs_direct   { shift->_outrefs_matching( qr/[+-]/ ) }
sub outrefs_indirect { shift->_outrefs_matching( qr/;/    ) }
sub outrefs_inferred { shift->_outrefs_matching( qr/\./   ) }

=head1 IMMORTAL SVs

Three special SV objects exist outside of the heap, to represent C<undef> and
boolean true and false. They are

=over 4

=item * Devel::MAT::SV::UNDEF

=item * Devel::MAT::SV::YES

=item * Devel::MAT::SV::NO

=back

=cut

package Devel::MAT::SV::Immortal;
use base qw( Devel::MAT::SV );
our $VERSION = '0.19';
use constant immortal => 1;
sub new {
   my $class = shift;
   my ( $df, $addr ) = @_;
   my $self = bless {}, $class;
   $self->_set_core_fields( 0, $df, $addr, 0, 0, 0 );
   return $self;
}
sub _outrefs { () }

package Devel::MAT::SV::UNDEF;
use base qw( Devel::MAT::SV::Immortal );
our $VERSION = '0.19';
sub desc { "UNDEF" }
sub type { "UNDEF" }

package Devel::MAT::SV::YES;
use base qw( Devel::MAT::SV::Immortal );
our $VERSION = '0.19';
sub desc { "YES" }
sub type { "SCALAR" }

# Pretend to be 1 / "1"
sub uv { 1 }
sub iv { 1 }
sub nv { 1.0 }
sub pv { "1" }
sub rv { undef }
sub is_weak { '' }
sub name {}

package Devel::MAT::SV::NO;
use base qw( Devel::MAT::SV::Immortal );
our $VERSION = '0.19';
sub desc { "NO" }
sub type { "SCALAR" }

# Pretend to be 0 / ""
sub uv { 0 }
sub iv { 0 }
sub nv { 0.0 }
sub pv { "0" }
sub rv { undef }
sub is_weak { '' }
sub name {}

package Devel::MAT::SV::Unknown;
use base qw( Devel::MAT::SV );
our $VERSION = '0.19';
__PACKAGE__->register_type( 0xff );

sub desc { "UNKNOWN" }

sub _outrefs {}

package Devel::MAT::SV::GLOB;
use base qw( Devel::MAT::SV );
our $VERSION = '0.19';
__PACKAGE__->register_type( 1 );

=head1 Devel::MAT::SV::GLOB

Represents a glob; an SV of type C<SVt_PVGV>.

=cut

sub load
{
   my $self = shift;
   my ( $header, $ptrs, $strs ) = @_;
   my $df = $self->df;

   my ( $line ) =
      unpack "$df->{uint_fmt}", $header;

   $self->_set_glob_fields(
      @{$ptrs}[0..7],
      $line, $strs->[1],
      $strs->[0],
   );
}

sub _fixup
{
   my $self = shift;

   $_ and $_->_set_glob_at( $self->addr ) for $self->scalar, $self->array, $self->hash, $self->code;
}

=head2 $file = $gv->file

=head2 $line = $gv->line

=head2 $location = $gv->location

Returns the filename, line number, or combined location (C<FILE line LINE>)
that the GV first appears at.

=cut

# XS accessors

sub location
{
   my $self = shift;
   my $file = $self->file;
   my $line = $self->line;
   defined $file ? "$file line $line" : undef
}

=head2 $stash = $gv->stash

Returns the stash to which the GV belongs.

=cut

sub stash  { my $self = shift; $self->df->sv_at( $self->stash_at  ) }

=head2 $sv = $gv->scalar

=head2 $av = $gv->array

=head2 $hv = $gv->hash

=head2 $cv = $gv->code

=head2 $gv = $gv->egv

=head2 $io = $gv->io

=head2 $form = $gv->form

Return the SV in the various glob slots.

=cut

sub scalar { my $self = shift; $self->df->sv_at( $self->scalar_at ) }
sub array  { my $self = shift; $self->df->sv_at( $self->array_at  ) }
sub hash   { my $self = shift; $self->df->sv_at( $self->hash_at   ) }
sub code   { my $self = shift; $self->df->sv_at( $self->code_at   ) }
sub egv    { my $self = shift; $self->df->sv_at( $self->egv_at    ) }
sub io     { my $self = shift; $self->df->sv_at( $self->io_at     ) }
sub form   { my $self = shift; $self->df->sv_at( $self->form_at   ) }

sub stashname
{
   my $self = shift;
   my $name = $self->name;
   $name =~ s(^([\x00-\x1f])){"^" . chr(64 + ord $1)}e;
   return $self->stash->stashname . "::" . $name;
}

sub desc
{
   my $self = shift;
   my $sigils = "";
   $sigils .= '$' if $self->scalar;
   $sigils .= '@' if $self->array;
   $sigils .= '%' if $self->hash;
   $sigils .= '&' if $self->code;
   $sigils .= '*' if $self->egv;
   $sigils .= 'I' if $self->io;
   $sigils .= 'F' if $self->form;

   return "GLOB($sigils)";
}

sub _outrefs
{
   my $self = shift;


   return (
      "+the scalar" => $self->scalar,
      "+the array"  => $self->array,
      "+the hash"   => $self->hash,
      "+the code"   => $self->code,
      "+the io"     => $self->io,
      "+the form"   => $self->form,

      # the egv is weakref if if it points back to itself
      ( $self->egv and $self->egv == $self ) ? "-the egv" : "+the egv" =>
         $self->egv,
   );
}

package Devel::MAT::SV::SCALAR;
use base qw( Devel::MAT::SV );
our $VERSION = '0.19';
__PACKAGE__->register_type( 2 );

=head1 Devel::MAT::SV::SCALAR

Represents a non-referential scalar value; an SV of any of the types up to and
including C<SVt_PVMV> (that is, C<IV>, C<NV>, C<PV>, C<PVIV>, C<PVNV> or
C<PVMG>). This includes all numbers, integers and floats, strings, and dualvars
containing multiple parts.

=cut

sub load
{
   my $self = shift;
   my ( $header, $ptrs, $strs ) = @_;
   my $df = $self->df;

   my ( $flags, $uv, $nvbytes, $pvlen ) =
      unpack "C $df->{uint_fmt} A$df->{nv_len} $df->{uint_fmt}", $header;
   my $nv = unpack "$df->{nv_fmt}", $nvbytes;

   # $strs->[0] will be swiped

   $self->_set_scalar_fields( $flags, $uv, $nv,
      $strs->[0], $pvlen,
      $ptrs->[0], # OURSTASH
   );

   # $strs->[0] is now undef

   $flags &= ~0x1f;
   $flags and die sprintf "Unrecognised SCALAR flags %02x\n", $flags;
}

=head2 $uv = $sv->uv

Returns the integer numeric portion as an unsigned value, if valid, or C<undef>.

=head2 $iv = $sv->iv

Returns the integer numeric portion as a signed value, if valid, or C<undef>.

=head2 $nv = $sv->nv

Returns the floating numeric portion, if valid, or C<undef>.

=head2 $pv = $sv->pv

Returns the string portion, if valid, or C<undef>.

=head2 $pvlen = $sv->pvlen

Returns the length of the string portion, if valid, or C<undef>.

=cut

# XS accessors

=head2 $str = $sv->qq_pv( $maxlen )

Returns the PV string, if defined, suitably quoted. If C<$maxlen> is defined
and the PV is longer than this, it is truncated and C<...> is appended after
the containing quote marks.

=cut

sub qq_pv
{
   my $self = shift;
   my ( $maxlen ) = @_;

   defined( my $pv = $self->pv ) or return undef;
   $pv = substr( $pv, 0, $maxlen ) if defined $maxlen and $maxlen < length $pv;

   my $truncated = $self->pvlen > length $pv;

   if( $pv =~ m/^[\x20-\x7e]*$/ ) {
      $pv =~ s/(['\\])/\\$1/g;
      $pv = qq('$pv');
   }
   else {
      $pv =~ s((\")     | (\r)     | (\n)     | ([\x00-\x1f\x80-\xff]))
              {$1?'\\"' : $2?"\\r" : $3?"\\n" : sprintf "\\x%02x", ord $4}egx;
      $pv = qq("$pv");
   }
   $pv .= "..." if $truncated;

   return $pv;
}

=head2 $stash = $sv->ourstash

Returns the stash of the SCALAR, if it is an 'C<our>' variable.

=cut

sub ourstash { my $self = shift; return $self->df->sv_at( $self->ourstash_at ) }

sub name
{
   my $self = shift;
   return unless my $glob_at = $self->glob_at;
   return '$' . $self->df->sv_at( $glob_at )->stashname;
}

sub desc
{
   my $self = shift;

   my @flags;
   push @flags, "UV" if defined $self->uv;
   push @flags, "IV" if defined $self->iv;
   push @flags, "NV" if defined $self->nv;
   push @flags, "PV" if defined $self->pv;
   local $" = ",";
   return "SCALAR(@flags)";
}

sub _outrefs
{
   my $self = shift;

   return (
      "+the our stash" => $self->ourstash,
   );
}

package Devel::MAT::SV::REF;
use base qw( Devel::MAT::SV );
our $VERSION = '0.19';
__PACKAGE__->register_type( 3 );

=head1 Devel::MAT::SV::REF

Represents a referential scalar; any SCALAR-type SV with the C<SvROK> flag
set.

=cut

sub load
{
   my $self = shift;
   my ( $header, $ptrs, $strs ) = @_;

   ( my $flags ) =
      unpack "C", $header;

   $self->_set_ref_fields(
      @{$ptrs}[0,1], # RV, OURSTASH
      $flags & 0x01, # RV_IS_WEAK
   );

   $flags &= ~0x01;
   $flags and die sprintf "Unrecognised REF flags %02x\n", $flags;
}

=head2 $svrv = $sv->rv

Returns the SV referred to by the reference.

=cut

sub rv { my $self = shift; return $self->df->sv_at( $self->rv_at ) }

=head2 $weak = $sv->is_weak

Returns true if the SV is a weakened RV reference.

=cut

# XS accessor

=head2 $stash = $sv->ourstash

Returns the stash of the SCALAR, if it is an 'C<our>' variable.

=cut

sub ourstash { my $self = shift; return $self->df->sv_at( $self->ourstash_at ) }

sub desc
{
   my $self = shift;

   return sprintf "REF(%s)", $self->is_weak ? "W" : "";
}

*name = \&Devel::MAT::SV::SCALAR::name;

sub _outrefs
{
   my $self = shift;
   return (
      ( $self->is_weak ? "-" : "+" ) . "the referrant" => $self->rv,
      "+the our stash" => $self->ourstash,
   );
}

package Devel::MAT::SV::ARRAY;
use base qw( Devel::MAT::SV );
our $VERSION = '0.19';
__PACKAGE__->register_type( 4 );

=head1 Devel::MAT::SV::ARRAY

Represents an array; an SV of type C<SVt_PVAV>.

=cut

sub refcount_adjusted
{
   my $self = shift;
   # AVs that are backrefs lists have an SvREFCNT artificially high
   return $self->refcnt - ( $self->is_backrefs ? 1 : 0 );
}

sub load
{
   my $self = shift;
   my ( $header, $ptrs, $strs ) = @_;
   my $df = $self->df;

   my ( $n, $flags ) =
      unpack "$df->{uint_fmt} C", $header;

   $self->_set_array_fields( $flags || 0, [ $n ? $df->_read_ptrs($n) : () ] );
}

=head2 $unreal = $av->is_unreal

Returns true if the C<AvREAL()> flag is not set on the array - i.e. that its
SV pointers do not contribute to the C<SvREFCNT> of the SVs it points at.

=head2 $backrefs = $av->is_backrefs

Returns true if the array contains the backrefs list of a hash or
weakly-referenced object.

=cut

# XS accessors

sub name
{
   my $self = shift;
   return unless my $glob_at = $self->glob_at;
   return '@' . $self->df->sv_at( $glob_at )->stashname;
}

=head2 @svs = $av->elems

Returns all of the element SVs in a list

=cut

sub elems
{
   my $self = shift;

   my $n = $self->n_elems;
   return $n unless wantarray;

   my $df = $self->df;
   return map { $df->sv_at( $self->elem_at( $_ ) ) } 0 .. $n-1;
}

=head2 $sv = $av->elem( $index )

Returns the SV at the given index

=cut

sub elem
{
   my $self = shift;
   return $self->df->sv_at( $self->elem_at( $_[0] ) );
}

sub desc
{
   my $self = shift;

   my @flags =
      scalar($self->elems);

   push @flags, "!REAL" if $self->is_unreal;

   $" = ",";
   return "ARRAY(@flags)";
}

sub _outrefs
{
   my $self = shift;
   my $df = $self->df;

   my $n = $self->n_elems;

   if( $self->is_unreal ) {
      return map {
         +"-element [$_]" => $df->sv_at( $self->elem_at( $_ ) ),
      } 0 .. $n-1;
   }

   return map {
      $direct_or_rv->( "element [$_]" => $df->sv_at( $self->elem_at( $_ ) ) ),
   } 0 .. $n-1;
}

package Devel::MAT::SV::PADLIST;
# Synthetic type
use base qw( Devel::MAT::SV::ARRAY );
our $VERSION = '0.19';
use constant type => "PADLIST";

=head1 Devel::MAT::SV::PADLIST

A subclass of ARRAY, this is used to represent the PADLIST of a CODE SV.

=cut

sub padcv { my $self = shift; return $self->df->sv_at( $self->padcv_at ) }

sub desc
{
   my $self = shift;
   return "PADLIST(" . $self->n_elems . ")";
}

# Totally different outrefs format
sub _outrefs
{
   my $self = shift;
   my $df = $self->df;

   my $n = $self->n_elems;

   return (
      "+the padnames" => $df->sv_at( $self->elem_at( 0 ) ),

      map { +"+pad at depth $_" => $df->sv_at( $self->elem_at( $_ ) ) }
         1 .. $n-1
   );
}

package Devel::MAT::SV::PADNAMES;
# Synthetic type
use base qw( Devel::MAT::SV::ARRAY );
our $VERSION = '0.19';
use constant type => "PADNAMES";

=head1 Devel::MAT::SV::PADNAMES

A subclass of ARRAY, this is used to represent the PADNAMES of a CODE SV.

=cut

sub padcv { my $self = shift; return $self->df->sv_at( $self->padcv_at ) }

=head2 $padname = $padnames->padname( $padix )

Returns the name of the lexical at the given index, or C<undef>

=cut

sub padname
{
   my $self = shift;
   my ( $padix ) = @_;
   my $namepv = $self->elem( $padix ) or return undef;
   $namepv->type eq "SCALAR" or return undef;
   return $namepv->pv;
}

sub desc
{
   my $self = shift;
   return "PADNAMES(" . scalar($self->elems) . ")";
}

# Totally different outrefs format
sub _outrefs
{
   my $self = shift;
   my $df = $self->df;

   my $n = $self->n_elems;

   return (
      # [0] is always UNDEF

      map { +"+padname [$_]" => $df->sv_at( $self->elem_at( $_ ) ) }
         1 .. $n-1
   );
}

package Devel::MAT::SV::PAD;
# Synthetic type
use base qw( Devel::MAT::SV::ARRAY );
our $VERSION = '0.19';
use constant type => "PAD";

use List::Util qw( pairmap );

=head1 Devel::MAT::SV::PAD

A subclass of ARRAY, this is used to represent a PAD of a CODE SV.

=cut

sub desc
{
   my $self = shift;
   return "PAD(" . scalar($self->elems) . ")";
}

=head2 ( $name, $sv, $name, $sv, ... ) = $pad->lexvars

Returns a name/value list of the lexical variables in the pad.

=cut

sub padcv { my $self = shift; return $self->df->sv_at( $self->padcv_at ) }

sub lexvars
{
   my $self = shift;
   my $padcv = $self->padcv;

   my @svs = $self->elems;
   return map {
      my $name = $padcv->padname( $_ );
      $name ? ( $name => $svs[$_] ) : ()
   } 1 .. $#svs;
}

# Totally different outrefs format
sub _outrefs
{
   my $self = shift;
   my $padcv = $self->padcv;

   my @svs = $self->elems;

   return (
      '+the @_ av' => $svs[0],
      map {
         my $sv = $svs[$_];
         my $name = $padcv->padname( $_ );
         $name ? ( $direct_or_rv->( "the lexical $name" => $sv ) )
               : ( $direct_or_rv->( "elem [$_]" => $sv ) )
      } 1 .. $#svs,
   );
}

package Devel::MAT::SV::HASH;
use base qw( Devel::MAT::SV );
our $VERSION = '0.19';
__PACKAGE__->register_type( 5 );

=head1 Devel::MAT::SV::HASH

Represents a hash; an SV of type C<SVt_PVHV>. The C<Devel::MAT::SV::STASH>
subclass is used to represent hashes that are used as stashes.

=cut

sub load
{
   my $self = shift;
   my ( $header, $ptrs, $strs ) = @_;
   my $df = $self->df;

   ( my $n ) =
      unpack "$df->{uint_fmt} a*", $header;

   my %values_at;
   foreach ( 1 .. $n ) {
      my $key = $df->_read_str;
      $values_at{$key} = $df->_read_ptr;
   }

   $self->_set_hash_fields(
      $ptrs->[0], # BACKREFS
      \%values_at,
   );

}

# Back-compat. for loading old .pmat files that didn't store AvREAL
sub _fixup
{
   my $self = shift;

   if( my $backrefs = $self->backrefs ) {
      $backrefs->_set_backrefs( 1 ) if $backrefs->type eq "ARRAY";
   }
}

sub name
{
   my $self = shift;
   return unless my $glob_at = $self->glob_at;
   return '%' . $self->df->sv_at( $glob_at )->stashname;
}

# HVs have a backrefs field directly, rather than using magic
sub backrefs
{
   my $self = shift;
   return $self->df->sv_at( $self->backrefs_at );
}

=head2 @keys = $hv->keys

Returns the set of keys present in the hash, as plain perl strings, in no
particular order.

=cut

# XS accessor

=head2 $sv = $hv->value( $key )

Returns the SV associated with the given key

=cut

sub value
{
   my $self = shift;
   my ( $key ) = @_;
   return $self->df->sv_at( $self->value_at( $key ) );
}

=head2 @svs = $hv->values

Returns all of the SVs stored as values, in no particular order.

=cut

sub values
{
   my $self = shift;
   return $self->n_values if !wantarray;

   my $df = $self->df;
   return map { $df->sv_at( $_ ) } $self->values_at;
}

sub desc
{
   my $self = shift;
   my $named = $self->{name} ? " named $self->{name}" : "";
   return "HASH(" . $self->n_values . ")";
}

sub _outrefs
{
   my $self = shift;
   my $df = $self->df;

   my @keys = $self->keys;

   return (
      # backrefs are optimised so if there's only one backref, it is stored
      # in the backrefs slot directly
      ( $self->backrefs && $self->backrefs->type eq "ARRAY" ) ?
         ( "+the backrefs list" => $self->backrefs,
           map { +";a backref" => $_ } $self->backrefs->elems ) :
         ( "-a backref" => $self->backrefs ),

      map {
         $direct_or_rv->( "value {$_}" => $df->sv_at( $self->value_at( $_ ) ) )
      } @keys
   );
}

package Devel::MAT::SV::STASH;
use base qw( Devel::MAT::SV::HASH );
our $VERSION = '0.19';
__PACKAGE__->register_type( 6 );

=head1 Devel::MAT::SV::STASH

Represents a hash used as a stash; an SV of type C<SVt_PVHV> whose C<HvNAME()>
is non-NULL. This is a subclass of C<Devel::MAT::SV::HASH>.

=cut

sub load
{
   my $self = shift;
   my ( $header, $ptrs, $strs ) = @_;
   my $df = $self->df;

   my ( $hash_bytes, $hash_ptrs, $hash_strs ) = @{ $df->{sv_sizes}[5] };

   $self->SUPER::load(
      substr( $header, 0, $hash_bytes, "" ),
      [ splice @$ptrs, 0, $hash_ptrs ],
      [ splice @$strs, 0, $hash_strs ],
   );

   @{$self}{qw( mro_linearall_at mro_linearcurrent_at mro_nextmethod_at mro_isa_at )} =
      @$ptrs;

   ( $self->{name} ) =
      @$strs;
}

=head2 $hv = $stash->mro_linear_all

=head2 $sv = $stash->mro_linearcurrent

=head2 $sv = $stash->mro_nextmethod

=head2 $av = $stash->mro_isa

Returns the fields from the MRO structure

=cut

sub mro_linearall     { my $self = shift; return $self->df->sv_at( $self->{mro_linearall_at} ) }
sub mro_linearcurrent { my $self = shift; return $self->df->sv_at( $self->{mro_linearcurrent_at} ) }
sub mro_nextmethod    { my $self = shift; return $self->df->sv_at( $self->{mro_nextmethod_at} ) }
sub mro_isa           { my $self = shift; return $self->df->sv_at( $self->{mro_isa_at} ) }

=head2 $name = $stash->stashname

Returns the name of the stash

=cut

sub stashname
{
   my $self = shift;
   return $self->{name};
}

sub desc
{
   my $self = shift;
   my $desc = $self->SUPER::desc;
   $desc =~ s/^HASH/STASH/;
   return $desc;
}

sub _outrefs
{
   my $self = shift;
   return $self->SUPER::_outrefs,
      "+the mro linear all HV"  => $self->mro_linearall,
      "+the mro linear current" => $self->mro_linearcurrent,
      "+the mro next::method"   => $self->mro_nextmethod,
      "+the mro ISA cache"      => $self->mro_isa,
}

package Devel::MAT::SV::CODE;
use base qw( Devel::MAT::SV );
our $VERSION = '0.19';
__PACKAGE__->register_type( 7 );

use List::MoreUtils qw( uniq );

=head1 Devel::MAT::SV::CODE

Represents a function or closure; an SV of type C<SVt_PVCV>.

=cut

sub load
{
   my $self = shift;
   my ( $header, $ptrs, $strs ) = @_;
   my $df = $self->df;

   my ( $line, $flags, $oproot ) =
      unpack "$df->{uint_fmt} C $df->{ptr_fmt}", $header;

   $self->_set_code_fields( $line, $flags, $oproot,
      @{$ptrs}[0, 2..4], # STASH, OUTSIDE, PADLIST, CONSTVAL
      $strs->[0],        # FILE
   );
   $self->_set_glob_at( $ptrs->[1] );

   while( my $type = $df->_read_u8 ) {
      given( $type ) {
         when( 1 ) { push @{ $self->{consts_at} }, $df->_read_ptr }
         when( 2 ) { push @{ $self->{constix} }, $df->_read_uint }
         when( 3 ) { push @{ $self->{gvs_at} }, $df->_read_ptr }
         when( 4 ) { push @{ $self->{gvix} }, $df->_read_uint }
         when( 5 ) { # ignore - used to be padname
                     $df->_read_uint; $df->_read_str }
         when( 6 ) { # ignore - used to be padsvs_at
                     $df->_read_uint; $df->_read_uint; $df->_read_ptr; }
         when( 7 ) { $self->_set_padnames_at( $df->_read_ptr ); }
         when( 8 ) { my $depth = $df->_read_uint;
                     $self->{pads_at}[$depth] = $df->_read_ptr; }
         default   { die "TODO: unhandled CODEx type $type"; }
      }
   }
}

sub _fixup
{
   my $self = shift;
   return unless $self->padlist_at;

   my $df = $self->df;

   my $padlist = $self->padlist;
   bless $padlist, "Devel::MAT::SV::PADLIST" if $padlist;
   $padlist->_set_padcv_at( $self->addr ) if $padlist;

   my $padnames;
   my @pads;

   # 5.18.0 onwards has a totally different padlist arrangement
   if( $df->{perlver} >= ( ( 5 << 24 ) | ( 18 << 16 ) ) ) {
      $padnames = $self->padnames;

      @pads = map { $df->sv_at( $_ ) } @{ $self->{pads_at} };
      shift @pads; # always zero
   }
   else {
      # PADLIST[0] stores the names of the lexicals
      # The rest stores the actual pads
      ( $padnames, @pads ) = $padlist->elems;
      $self->_set_padnames_at( $padnames->addr );
   }

   bless $padnames, "Devel::MAT::SV::PADNAMES";
   $padnames->_set_padcv_at( $self->addr );

   foreach my $pad ( @pads ) {
      next unless $pad;

      bless $pad, "Devel::MAT::SV::PAD";
      $pad->_set_padcv_at( $self->addr );
   }

   $self->{pads} = \@pads;

   # Under ithreads, constants are actually stored in the first padlist
   if( $df->ithreads ) {
      my $pad0 = $pads[0];

      foreach my $type (qw( const gv )) {
         my $idxes  = $self->{"${type}ix"} or next;
         my $svs_at = $self->{"${type}s_at"} ||= [];

         @$svs_at = map { my $e = $pad0->elem($_);
                          $e ? $e->addr : undef } uniq @$idxes;

         # Clear the obviously unused elements of lexnames and padlists
         foreach my $ix ( @$idxes ) {
            $padnames->_clear_elem( $ix );
            $_ and $_->_clear_elem( $ix ) for @pads;
         }
      }
   }
}

=head2 $stash = $cv->stash

=head2 $gv = $cv->glob

=head2 $filename = $cv->file

=head2 $line = $cv->line

=head2 $scope_cv = $cv->scope

=head2 $av = $cv->padlist

=head2 $sv = $cv->constval

=head2 $addr = $cv->oproot

Returns the stash, glob, filename, line number, scope, padlist, constant value
or oproot of the code.

=cut

sub stash    { my $self = shift; return $self->df->sv_at( $self->stash_at ) }
sub glob     { my $self = shift; return $self->df->sv_at( $self->glob_at ) }
# XS accessors: file, line
sub scope    { my $self = shift; return $self->df->sv_at( $self->outside_at ) }
sub padlist  { my $self = shift; return $self->df->sv_at( $self->padlist_at ) }
sub constval { my $self = shift; return $self->df->sv_at( $self->constval_at ) }
# XS accessor: oproot

=head2 $location = $cv->location

Returns C<FILE line LINE> if the line is defined, or C<FILE> if not.

=cut

sub location
{
   my $self = shift;
   my $line = $self->line;
   my $file = $self->file;
   # line 0 is invalid
   return $line ? "$file line $line" : $file;
}

=head2 $clone = $cv->is_clone

=head2 $cloned = $cv->is_cloned

=head2 $xsub = $cv->is_xsub

=head2 $weak = $cv->is_weakoutside

=head2 $rc = $cv->is_cvgv_rc

Returns the C<CvCLONE()>, C<CvCLONED()>, C<CvISXSUB()>, C<CvWEAKOUTSIDE()> and
C<CvCVGV_RC()> flags.

=cut

# XS accessors

=head2 $protosub = $cv->protosub

Returns the protosub CV, if known, for a closure CV.

=cut

sub protosub { my $self = shift; return $self->df->sv_at( $self->protosub_at ); }

=head2 @svs = $cv->constants

Returns a list of the SVs used as constants or method names in the code. On
ithreads perl the constants are part of the padlist structure so this list is
constructed from parts of the padlist at loading time.

=cut

sub constants
{
   my $self = shift;
   my $df = $self->df;
   return map { $df->sv_at($_) } @{ $self->{consts_at} || [] };
}

=head2 @svs = $cv->globrefs

Returns a list of the SVs used as GLOB references in the code. On ithreads
perl the constants are part of the padlist structure so this list is
constructed from parts of the padlist at loading time.

=cut

sub globrefs
{
   my $self = shift;
   my $df = $self->df;
   return map { $df->sv_at($_) } @{ $self->{gvs_at} };
}

sub stashname { my $self = shift; return $self->stash ? $self->stash->stashname : undef }

sub name
{
   my $self = shift;
   return unless my $glob_at = $self->glob_at;
   return '&' . $self->df->sv_at( $glob_at )->stashname;
}

=head2 $name = $cv->padname( $padix )

Returns the name of the $padix'th lexical variable, or C<undef> if it doesn't
have a name

=cut

sub padname
{
   my $self = shift;
   my ( $padix ) = @_;

   return $self->padnames->padname( $padix );
}

=head2 $padnames = $cv->padnames

Returns the AV reference directly which stores the pad names.

=cut

sub padnames
{
   my $self = shift;
   return $self->df->sv_at( $self->padnames_at );
}

=head2 @pads = $cv->pads

Returns a list of the actual pad AVs.

=cut

sub pads
{
   my $self = shift;
   return $self->{pads} ? @{ $self->{pads} } : ();
}

=head2 $pad = $cv->pad( $depth )

Returns the PAD at the given depth

=cut

sub pad
{
   my $self = shift;
   my ( $depth ) = @_;
   return $self->{pads} ? $self->{pads}[$depth] : undef;
}

sub desc
{
   my $self = shift;

   my @flags;
   push @flags, "PP"    if $self->oproot;
   push @flags, "CONST" if $self->constval;
   push @flags, "XS"    if $self->is_xsub;

   push @flags, "C" if $self->is_cloned; # C for Closure
   push @flags, "P" if $self->is_clone;  # P for Protosub

   local $" = ",";
   return "CODE(@flags)";
}

sub _outrefs
{
   my $self = shift;
   my $pads = $self->{pads};

   my $maxdepth = $pads ? scalar @$pads : 0;

   my $padlist = $self->padlist;

   # If we have a PADLIST then its contents are indirect; if not then they are direct strong
   my $padnames_desc = $padlist ? ";the padnames"
                                : "+the padnames";
   my $pad_descf     = $padlist ? ";pad at depth %d"
                                : "+pad at depth %d";

   return (
      ( $self->is_weakoutside ? "-the scope" : "+the scope" ) =>
         $self->scope,

      "-the stash" => $self->stash,

      ( $self->is_cvgv_rc ? "+the glob" : "-the glob" ) =>
         $self->glob,

      "+the constant value" => $self->constval,
      ".the protosub" => $self->protosub,

      ( map { +"+a constant" => $_ } $self->constants ),
      ( map { +"+a referenced glob" => $_ } $self->globrefs ),

      "+the padlist" => $padlist,
      $padnames_desc => $self->padnames,

      ( map {
            my $depth = $_;
            sprintf( $pad_descf, $depth ) => $pads->[$depth-1],
         } 1 .. $maxdepth ),
   );
}

package Devel::MAT::SV::IO;
use base qw( Devel::MAT::SV );
our $VERSION = '0.19';
__PACKAGE__->register_type( 8 );

sub load
{
   my $self = shift;
   my ( $header, $ptrs, $strs ) = @_;

   @{$self}{qw( topgv_at formatgv_at bottomgv_at )} =
      @$ptrs;
}

sub topgv    { my $self = shift; $self->df->sv_at( $self->{topgv_at}    ) }
sub formatgv { my $self = shift; $self->df->sv_at( $self->{formatgv_at} ) }
sub bottomgv { my $self = shift; $self->df->sv_at( $self->{bottomgv_at} ) }

sub desc { "IO()" }

sub _outrefs
{
   my $self = shift;
   return (
      "+the top GV" => $self->topgv,
      "+the format GV" => $self->formatgv,
      "+the bottom GV" => $self->bottomgv,
   );
}

package Devel::MAT::SV::LVALUE;
use base qw( Devel::MAT::SV );
our $VERSION = '0.19';
__PACKAGE__->register_type( 9 );

sub load
{
   my $self = shift;
   my ( $header, $ptrs, $strs ) = @_;
   my $df = $self->df;

   ( $self->{type}, $self->{off}, $self->{len} ) =
      unpack "a1 $df->{uint_fmt}2", $header;

   ( $self->{targ_at} ) =
      @$ptrs;
}

sub lvtype { my $self = shift; return $self->{type} }
sub off    { my $self = shift; return $self->{off} }
sub len    { my $self = shift; return $self->{len} }
sub target { my $self = shift; return $self->df->sv_at( $self->{targ_at} ) }

sub desc { "LVALUE()" }

sub _outrefs
{
   my $self = shift;
   return (
      "+the target" => $self->target,
   );
}

package Devel::MAT::SV::REGEXP;
use base qw( Devel::MAT::SV );
our $VERSION = '0.19';
__PACKAGE__->register_type( 10 );

sub load {}

sub desc { "REGEXP()" }

sub _outrefs { () }

package Devel::MAT::SV::FORMAT;
use base qw( Devel::MAT::SV );
our $VERSION = '0.19';
__PACKAGE__->register_type( 11 );

sub load {}

sub desc { "FORMAT()" }

sub _outrefs { () }

package Devel::MAT::SV::INVLIST;
use base qw( Devel::MAT::SV );
our $VERSION = '0.19';
__PACKAGE__->register_type( 12 );

sub load {}

sub desc { "INVLIST()" }

sub _outrefs { () }

=head1 AUTHOR

Paul Evans <leonerd@leonerd.org.uk>

=cut

0x55AA;
