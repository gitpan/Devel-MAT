#  You may distribute under the terms of either the GNU General Public License
#  or the Artistic License (the same terms as Perl itself)
#
#  (C) Paul Evans, 2013 -- leonerd@leonerd.org.uk

package Devel::MAT::SV;

use strict;
use warnings;
use feature qw( switch );
no if $] >= 5.017011, warnings => 'experimental::smartmatch';

our $VERSION = '0.12';

use Carp;
use Scalar::Util qw( weaken );
use List::Util qw( pairgrep pairmap pairs );

use constant immortal => 0;

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
   if( defined $sv and $sv->type eq "REF" and !@{ $sv->{magic} } ) {
      return ( "+$name directly" => $sv,
               ";$name via RV" => $sv->rv );
   }
   else {
      return ( "+$name directly" => $sv );
   }
};

my $indirect_or_rv = sub {
   my ( $name, $sv ) = @_;
   if( defined $sv and $sv->type eq "REF" and !@{ $sv->{magic} } ) {
      return ( ";$name indirectly" => $sv,
               ";$name via RV" => $sv->rv );
   }
   else {
      return ( ";$name indirectly" => $sv );
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

   my $self = bless { magic => [] }, $class;
   weaken( $self->{df} = $df );

   ( $self->{addr}, $self->{refcnt}, $self->{size} ) =
      unpack "$df->{ptr_fmt} $df->{u32_fmt} $df->{uint_fmt}", $header;

   ( $self->{blessed_at} ) = @$ptrs;

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

sub addr
{
   my $self = shift;
   return $self->{addr};
}

=head2 $count = $sv->refcnt

Returns the C<SvREFCNT> reference count of the SV

=cut

sub refcnt
{
   my $self = shift;
   return $self->{refcnt};
}

=head2 $stash = $sv->blessed

If the SV represents a blessed object, returns the stash SV. Otherwise returns
C<undef>.

=cut

sub blessed
{
   my $self = shift;
   return $self->{df}->sv_at( $self->{blessed_at} );
}

=head2 $size = $sv->size

Returns the (approximate) size in bytes of the SV

=cut

sub size
{
   my $self = shift;
   return $self->{size};
}

=head2 ( $type, $sv, $type, $sv, ... ) = $sv->magic

Returns a pair list of magic applied to the SV; each giving the type and
target SV.

=cut

sub magic
{
   my $self = shift;
   my $df = $self->{df};
   return map { my ( $type, $addr ) = @$_; $type => $df->sv_at( $addr ) } @{ $self->{magic} };
}

# internal
sub more_magic
{
   my $self = shift;
   my ( $type, $obj_at ) = @_;

   push @{ $self->{magic} }, [ $type => $obj_at ];
}

=head2 %refs = $sv->outrefs

Returns a name/value list giving names and other SV objects for each of the
SVs that this one refers to, either directly by strong or weak reference,
indirectly via RV, or inferred by C<Devel::MAT> itself.

=cut

# Each outref name starts with one of four characters to indicate its type
#   +name = direct strong
#   -name = direct weak
#   ;name = indirect
#   .name = inferred


# $no_mangle is used by the Inrefs tool
sub _outrefs_matching
{
   my $self = shift;
   my ( $match, $no_mangle ) = @_;

   my @outrefs = pairgrep { defined $b } $self->_outrefs;

   push @outrefs, "-the bless package", $self->blessed if $self->blessed;

   foreach my $mg ( @{ $self->{magic} } ) {
      my ( $type, $obj_at ) = @$mg;
      my $obj = $self->{df}->sv_at( $obj_at );
      push @outrefs, "+'$type' magic" => $obj if $obj;
   }

   @outrefs = pairgrep { $a =~ m/^$match/ } @outrefs if $match;

   return @outrefs / 2 if !wantarray;

   # Strip type prefixes
   @outrefs = pairmap { substr( $a, 1 ) => $b } @outrefs unless $no_mangle;
   return @outrefs;
}

sub outrefs { shift->_outrefs_matching( undef ) }

=head2 %refs = $sv->outrefs_strong

Returns the subset of C<outrefs> that are direct strong references.

=head2 %refs = $sv->outrefs_weak

Returns the subset of C<outrefs> that are direct weak references.

=head2 %refs = $sv->outrefs_direct

Returns the subset of C<outrefs> that are direct strong or weak references.

=head2 %refs = $sv->outrefs_indirect

Returns the subset of C<outrefs> that are indirect references via RVs.

=head2 %refs = $sv->outrefs_inferred

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
our $VERSION = '0.12';
use constant immortal => 1;
sub new {
   my $class = shift;
   my ( $df, $addr ) = @_;
   my $self = bless { addr => $addr }, $class;
   Scalar::Util::weaken( $self->{df} = $df );
   return $self;
}
sub _outrefs { () }

package Devel::MAT::SV::UNDEF;
use base qw( Devel::MAT::SV::Immortal );
our $VERSION = '0.12';
sub desc { "UNDEF" }
sub type { "UNDEF" }

package Devel::MAT::SV::YES;
use base qw( Devel::MAT::SV::Immortal );
our $VERSION = '0.12';
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
our $VERSION = '0.12';
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
our $VERSION = '0.12';
__PACKAGE__->register_type( 0xff );

sub desc { "UNKNOWN" }

sub _outrefs {}

package Devel::MAT::SV::GLOB;
use base qw( Devel::MAT::SV );
our $VERSION = '0.12';
__PACKAGE__->register_type( 1 );

=head1 Devel::MAT::SV::GLOB

Represents a glob; an SV of type C<SVt_PVGV>.

=cut

sub load
{
   my $self = shift;
   my ( $header, $ptrs, $strs ) = @_;
   my $df = $self->{df};

   ( $self->{line} ) =
      unpack "$df->{uint_fmt}", $header;

   @{$self}{qw( stash_at scalar_at array_at hash_at code_at egv_at io_at form_at )} =
      @$ptrs;

   @{$self}{qw( name file )} =
      @$strs;
}

sub _fixup
{
   my $self = shift;

   $_ and $_->{glob_at} = $self->addr for $self->scalar, $self->array, $self->hash, $self->code;
}

=head2 $file = $gv->file

=head2 $line = $gv->line

=head2 $location = $gv->location

Returns the filename, line number, or combined location (C<FILE line LINE>)
that the GV first appears at.

=cut

sub file { my $self = shift; $self->{file} }
sub line { my $self = shift; $self->{line} }

sub location
{
   my $self = shift;
   defined $self->{file} ? "$self->{file} line $self->{line}"
                         : undef
}

=head2 $stash = $gv->stash

Returns the stash to which the GV belongs.

=cut

sub stash  { my $self = shift; $self->{df}->sv_at( $self->{stash_at}  ) }

=head2 $sv = $gv->scalar

=head2 $av = $gv->array

=head2 $hv = $gv->hash

=head2 $cv = $gv->code

=head2 $gv = $gv->egv

=head2 $io = $gv->io

=head2 $form = $gv->form

Return the SV in the various glob slots.

=cut

sub scalar { my $self = shift; $self->{df}->sv_at( $self->{scalar_at} ) }
sub array  { my $self = shift; $self->{df}->sv_at( $self->{array_at}  ) }
sub hash   { my $self = shift; $self->{df}->sv_at( $self->{hash_at}   ) }
sub code   { my $self = shift; $self->{df}->sv_at( $self->{code_at}   ) }
sub egv    { my $self = shift; $self->{df}->sv_at( $self->{egv_at}    ) }
sub io     { my $self = shift; $self->{df}->sv_at( $self->{io_at}     ) }
sub form   { my $self = shift; $self->{df}->sv_at( $self->{form_at}   ) }

sub stashname
{
   my $self = shift;
   my $name = $self->{name};
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
our $VERSION = '0.12';
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
   my $df = $self->{df};

   ( my $flags, $self->{uv}, my $nvbytes, $self->{pvlen} ) =
      unpack "C $df->{uint_fmt} A$df->{nv_len} $df->{uint_fmt}", $header;
   $self->{nv} = unpack "$df->{nv_fmt}", $nvbytes;

   ( $self->{ourstash_at} ) =
      @$ptrs if $ptrs;

   ( $self->{pv} ) =
      @$strs;

   # Body
   undef $self->{uv} unless $flags & 0x01;
   undef $self->{nv} unless $flags & 0x04;
   undef $self->{pv} unless $flags & 0x08;

   if( $flags & 0x02 ) {
      # UV is IV
      $self->{iv} = unpack "j", pack "J", delete $self->{uv};
   }

   $flags &= ~0x0f;
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

=head2 $svrv = $sv->rv

Returns the SV referred to by the reference portion, if valid, or C<undef>.

=cut

sub uv { my $self = shift; return $self->{uv} }
sub iv { my $self = shift; return $self->{iv} }
sub nv { my $self = shift; return $self->{nv} }
sub pv    { my $self = shift; return $self->{pv} }
sub pvlen { my $self = shift; return $self->{pvlen} }

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

sub ourstash { my $self = shift; return $self->{df}->sv_at( $self->{ourstash_at} ) }

sub name
{
   my $self = shift;
   return unless $self->{glob_at};
   return '$' . $self->{df}->sv_at( $self->{glob_at} )->stashname;
}

sub desc
{
   my $self = shift;

   my @flags;
   push @flags, "UV" if defined $self->{uv};
   push @flags, "IV" if defined $self->{iv};
   push @flags, "NV" if defined $self->{nv};
   push @flags, "PV" if defined $self->{pv};
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
our $VERSION = '0.12';
__PACKAGE__->register_type( 3 );

=head1 Devel::MAT::SV::REF

Represents a referential scalar; any SCALAR-type SV with the C<SvROK> flag
set.

=cut

sub load
{
   my $self = shift;
   my ( $header, $ptrs, $strs ) = @_;
   my $df = $self->{df};

   ( my $flags ) =
      unpack "C", $header;

   # PTRs
   ( $self->{rv_at}, $self->{ourstash_at} ) =
      @$ptrs;

   $self->{rv_is_weak} = $flags & 0x01;

   $flags &= ~0x01;
   $flags and die sprintf "Unrecognised REF flags %02x\n", $flags;
}

sub rv { my $self = shift; return $self->{rv_at} ? $self->{df}->sv_at( $self->{rv_at} ) : undef }

=head2 $weak = $sv->is_weak

Returns true if the SV is a weakened RV reference.

=cut

sub is_weak
{
   my $self = shift;
   return $self->{rv_is_weak};
}

=head2 $stash = $sv->ourstash

Returns the stash of the SCALAR, if it is an 'C<our>' variable.

=cut

*ourstash = \&Devel::MAT::SV::SCALAR::ourstash;

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
our $VERSION = '0.12';
__PACKAGE__->register_type( 4 );

=head1 Devel::MAT::SV::ARRAY

Represents an array; an SV of type C<SVt_PVAV>.

=cut

sub load
{
   my $self = shift;
   my ( $header, $ptrs, $strs ) = @_;
   my $df = $self->{df};

   ( my $n, $self->{flags} ) =
      unpack "$df->{uint_fmt} C", $header;

   $self->{flags} ||= 0;

   # Body
   $self->{elems_at} = [ $n ? $df->_read_ptrs($n) : () ];
}

=head2 $unreal = $av->is_unreal

Returns true if the C<AvREAL()> flag is not set on the array - i.e. that its
SV pointers do not contribute to the C<SvREFCNT> of the SVs it points at.

=cut

sub is_unreal
{
   my $self = shift;
   return $self->{flags} & 0x01;
}

sub name
{
   my $self = shift;
   return unless $self->{glob_at};
   return '@' . $self->{df}->sv_at( $self->{glob_at} )->stashname;
}

=head2 @svs = $av->elems

Returns all of the element SVs in a list

=cut

sub elems
{
   my $self = shift;
   return scalar @{ $self->{elems_at} } unless wantarray;
   return map { $self->{df}->sv_at( $_ ) } @{ $self->{elems_at} };
}

=head2 $sv = $av->elem( $index )

Returns the SV at the given index

=cut

sub elem
{
   my $self = shift;
   return $self->{df}->sv_at( $self->{elems_at}[$_[0]] );
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
   my $df = $self->{df};

   my $elems = $self->{elems_at};

   if( $self->is_unreal ) {
      return map {
         +"-element [$_] directly" => $df->sv_at( $elems->[$_] ),
      } 0 .. $#$elems;
   }

   return map {
      $direct_or_rv->( "element [$_]" => $df->sv_at( $elems->[$_] ) ),
   } 0 .. $#$elems;
}

package Devel::MAT::SV::PADLIST;
# Synthetic type
use base qw( Devel::MAT::SV::ARRAY );
our $VERSION = '0.12';
use constant type => "PADLIST";

=head1 Devel::MAT::SV::PADLIST

A subclass of ARRAY, this is used to represent the PADLIST of a CODE SV.

=cut

sub desc
{
   my $self = shift;
   return "PADLIST(" . scalar($self->elems) . ")";
}

# Totally different outrefs format
sub _outrefs
{
   my $self = shift;
   my $df = $self->{df};

   my $elems = $self->{elems_at};

   return (
      "+the padnames directly" => $df->sv_at( $elems->[0] ),

      map { +"+pad at depth $_ directly" => $df->sv_at( $elems->[$_] ) }
         1 .. $#$elems
   );
}

package Devel::MAT::SV::PADNAMES;
# Synthetic type
use base qw( Devel::MAT::SV::ARRAY );
our $VERSION = '0.12';
use constant type => "PADNAMES";

=head1 Devel::MAT::SV::PADNAMES

A subclass of ARRAY, this is used to represent the PADNAMES of a CODE SV.

=cut

sub desc
{
   my $self = shift;
   return "PADNAMES(" . scalar($self->elems) . ")";
}

# Totally different outrefs format
sub _outrefs
{
   my $self = shift;
   my $df = $self->{df};

   my $elems = $self->{elems_at};

   return (
      # [0] is always UNDEF

      map { +"+padname [$_]" => $df->sv_at( $elems->[$_] ) }
         1 .. $#$elems
   );
}

package Devel::MAT::SV::PAD;
# Synthetic type
use base qw( Devel::MAT::SV::ARRAY );
our $VERSION = '0.12';
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

sub lexvars
{
   my $self = shift;
   my $cv = $self->{cv};

   my @svs = $self->elems;
   return map {
      my $name = $cv->padname( $_ );
      $name ? ( $name => $svs[$_] ) : ()
   } 1 .. $#svs;
}

# Totally different outrefs format
sub _outrefs
{
   my $self = shift;

   return (
      pairmap { $direct_or_rv->( "the lexical $a" => $b ) } $self->lexvars
   );
}

package Devel::MAT::SV::HASH;
use base qw( Devel::MAT::SV );
our $VERSION = '0.12';
__PACKAGE__->register_type( 5 );

=head1 Devel::MAT::SV::HASH

Represents a hash; an SV of type C<SVt_PVHV>. The C<Devel::MAT::SV::STASH>
subclass is used to represent hashes that are used as stashes.

=cut

sub load
{
   my $self = shift;
   my ( $header, $ptrs, $strs ) = @_;
   my $df = $self->{df};

   ( my $n ) =
      unpack "$df->{uint_fmt} a*", $header;

   ( $self->{backrefs_at} ) =
      @$ptrs;

   foreach ( 1 .. $n ) {
      my $key = $df->_read_str;
      $self->{values_at}{$key} = $df->_read_ptr;
   }
}

sub name
{
   my $self = shift;
   return unless $self->{glob_at};
   return '%' . $self->{df}->sv_at( $self->{glob_at} )->stashname;
}

=head2 $av = $hv->backrefs

Returns the AV containing weak reference backrefs

=cut

sub backrefs
{
   my $self = shift;
   return $self->{df}->sv_at( $self->{backrefs_at} );
}

=head2 @keys = $hv->keys

Returns the set of keys present in the hash, as plain perl strings, in no
particular order.

=cut

sub keys
{
   my $self = shift;
   return keys %{ $self->{values_at} };
}

=head2 $sv = $hv->value( $key )

Returns the SV associated with the given key

=cut

sub value
{
   my $self = shift;
   my ( $key ) = @_;
   return $self->{df}->sv_at( $self->{values_at}{$key} );
}

=head2 @svs = $hv->values

Returns all of the SVs stored as values, in no particular order.

=cut

sub values
{
   my $self = shift;
   return map { $self->{df}->sv_at( $_ ) } values %{ $self->{values_at} };
}

sub desc
{
   my $self = shift;
   my $named = $self->{name} ? " named $self->{name}" : "";
   return "HASH(" . scalar($self->keys) . ")";
}

sub _outrefs
{
   my $self = shift;
   my $df = $self->{df};

   my $values = $self->{values_at};

   return (
      # backrefs are optimised so if there's only one backref, it is stored
      # in the backrefs slot directly
      ( $self->backrefs && $self->backrefs->type eq "ARRAY" ) ?
         ( "+the backrefs list" => $self->backrefs,
           map { +";a backref indirectly" => $_ } $self->backrefs->elems ) :
         ( "-a backref" => $self->backrefs ),

      map {
         $direct_or_rv->( "value {$_}" => $df->sv_at( $values->{$_} ) )
      } CORE::keys %$values
   );
}

package Devel::MAT::SV::STASH;
use base qw( Devel::MAT::SV::HASH );
our $VERSION = '0.12';
__PACKAGE__->register_type( 6 );

=head1 Devel::MAT::SV::STASH

Represents a hash used as a stash; an SV of type C<SVt_PVHV> whose C<HvNAME()>
is non-NULL. This is a subclass of C<Devel::MAT::SV::HASH>.

=cut

sub load
{
   my $self = shift;
   my ( $header, $ptrs, $strs ) = @_;
   my $df = $self->{df};

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

sub mro_linearall     { my $self = shift; return $self->{df}->sv_at( $self->{mro_linearall_at} ) }
sub mro_linearcurrent { my $self = shift; return $self->{df}->sv_at( $self->{mro_linearcurrent_at} ) }
sub mro_nextmethod    { my $self = shift; return $self->{df}->sv_at( $self->{mro_nextmethod_at} ) }
sub mro_isa           { my $self = shift; return $self->{df}->sv_at( $self->{mro_isa_at} ) }

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
our $VERSION = '0.12';
__PACKAGE__->register_type( 7 );

=head1 Devel::MAT::SV::CODE

Represents a function or closure; an SV of type C<SVt_PVCV>.

=cut

sub load
{
   my $self = shift;
   my ( $header, $ptrs, $strs ) = @_;
   my $df = $self->{df};

   ( $self->{line}, $self->{flags}, $self->{oproot} ) =
      unpack "$df->{uint_fmt} C $df->{ptr_fmt}", $header;

   @{$self}{qw( stash_at glob_at outside_at padlist_at constval_at )} =
      @$ptrs;

   ( $self->{file} ) = 
      @$strs;

   $self->{consts_at} = \my @consts;
   $self->{constix}   = \my @constix;
   $self->{gvs_at} = \my @gvs;
   $self->{gvix}   = \my @gvix;
   $self->{padnames} = \my @padnames;
   $self->{padsvs_at} = \my @padsvs_at; # [depth][idx]

   while( my $type = $df->_read_u8 ) {
      given( $type ) {
         when( 1 ) { push @consts, $df->_read_ptr }
         when( 2 ) { push @constix, $df->_read_uint }
         when( 3 ) { push @gvs, $df->_read_ptr }
         when( 4 ) { push @gvix, $df->_read_uint }
         when( 5 ) { my $idx = $df->_read_uint;
                     $padnames[$idx] = $df->_read_str }
         when( 6 ) { my $depth = $df->_read_uint;
                     my $idx = $df->_read_uint;
                     $padsvs_at[$depth][$idx] = $df->_read_ptr; }
         when( 7 ) { $self->{padnames_at} = $df->_read_ptr; }
         when( 8 ) { my $depth = $df->_read_uint;
                     $self->{pads_at}[$depth] = $df->_read_ptr; }
         default   { die "TODO: unhandled CODEx type $type"; }
      }
   }
}

sub _fixup
{
   my $self = shift;
   return unless $self->{padlist_at};

   my $df = $self->{df};

   # 5.18.0 onwards has a totally different padlist arrangement
   if( $df->{perlver} >= ( ( 5 << 24 ) | ( 18 << 16 ) ) ) {
      my $padlist = $self->padlist;
      bless $padlist, "Devel::MAT::SV::PADLIST" if $padlist;

      if( my $padnames = $self->{padnames_av} = $df->sv_at( $self->{padnames_at} ) ) {
         bless $padnames, "Devel::MAT::SV::PADNAMES";
      }

      my @pads = map { $df->sv_at( $_ ) } @{ $self->{pads_at} };
      shift @pads; # always zero

      bless $_, "Devel::MAT::SV::PAD" for @pads;
      Scalar::Util::weaken( $_->{cv} = $self ) for @pads;

      $self->{pads} = \@pads;

      if( $df->ithreads ) {
         my $pad0_at = $self->{padsvs_at}[1]; # Yes, 1

         @{$self->{consts_at}} = map { $pad0_at->[$_] } @{ $self->{constix} };
         @{$self->{gvs_at}}    = map { $pad0_at->[$_] } @{ $self->{gvix} };
      }
   }
   else {
      my $padlist = $self->padlist;
      bless $padlist, "Devel::MAT::SV::PADLIST";

      # PADLIST[0] stores the names of the lexicals
      # The rest stores the actual pads
      my ( $padnames, @pads ) = $padlist->elems;
      bless $padnames, "Devel::MAT::SV::PADNAMES";

      bless $_, "Devel::MAT::SV::PAD" for @pads;
      Scalar::Util::weaken( $_->{cv} = $self ) for @pads;
      $_->{cv} = $self for @pads;

      $self->{pads} = \@pads;

      $self->{padnames_av} = $padnames;

      $self->{padsvs_at} = \my @padsvs_at;
      foreach my $i ( 0 .. $#pads ) {
         my $pad = $pads[$i];
         $padsvs_at[$i+1] = [ map { $_ ? $_->addr : undef } $pad->elems ];
      }

      # Under ithreads, constants are actually stored in the first padlist
      if( $df->ithreads ) {
         my $pad0 = $pads[0];

         @{$self->{consts_at}} = map { my $e = $pad0->elem($_); $e ? $e->addr : undef } @{ $self->{constix} };
         @{$self->{gvs_at}}    = map { my $e = $pad0->elem($_); $e ? $e->addr : undef } @{ $self->{gvix} };

         # Clear the obviously unused elements of lexnames and padlists
         foreach my $ix ( @{ delete $self->{constix} }, @{ delete $self->{gvix} } ) {
            undef $self->{padnames_av}->{elems_at}[$ix];
            undef $_->{elems_at}[$ix] for @pads;
         }
      }

      @{$self->{padnames}} = map { $_ and $_->isa( "Devel::MAT::SV::SCALAR" ) ? $_->pv : undef } $padnames->elems;
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

sub stash    { my $self = shift; return $self->{df}->sv_at( $self->{stash_at} ) }
sub glob     { my $self = shift; return $self->{df}->sv_at( $self->{glob_at} ) }
sub file     { my $self = shift; return $self->{file} }
sub line     { my $self = shift; return $self->{line} }
sub scope    { my $self = shift; return $self->{df}->sv_at( $self->{outside_at} ) }
sub padlist  { my $self = shift; return $self->{df}->sv_at( $self->{padlist_at} ) }
sub constval { my $self = shift; return $self->{df}->sv_at( $self->{constval_at} ) }
sub oproot   { my $self = shift; return $self->{oproot} }

=head2 $location = $cv->location

Returns C<FILE line LINE> if the line is defined, or C<FILE> if not.

=cut

sub location
{
   my $self = shift;
   # line 0 is invalid
   $self->{line} ? "$self->{file} line $self->{line}"
                 : $self->{file};
}

=head2 $clone = $cv->is_clone

=head2 $cloned = $cv->is_cloned

=head2 $xsub = $cv->is_xsub

=head2 $weak = $cv->is_weakoutside

=head2 $rc = $cv->is_cvgv_rc

Returns the C<CvCLONE()>, C<CvCLONED()>, C<CvISXSUB()>, C<CvWEAKOUTSIDE()> and
C<CvCVGV_RC()> flags.

=cut

sub is_clone       { my $self = shift; ( $self->{flags} // 0 ) & 0x01 }
sub is_cloned      { my $self = shift; ( $self->{flags} // 0 ) & 0x02 }
sub is_xsub        { my $self = shift; ( $self->{flags} // 0 ) & 0x04 }
sub is_weakoutside { my $self = shift; ( $self->{flags} // 0 ) & 0x08 }
sub is_cvgv_rc     { my $self = shift; ( $self->{flags} // 0 ) & 0x10 }

=head2 $protosub = $cv->protosub

Returns the protosub CV, if known, for a closure CV.

=cut

sub _set_protosub
{
   my $self = shift;
   ( $self->{protosub_at} ) = @_;
}

sub protosub { my $self = shift; return $self->{df}->sv_at( $self->{protosub_at} ); }

=head2 @svs = $cv->constants

Returns a list of the SVs used as constants or method names in the code. On
ithreads perl the constants are part of the padlist structure so this list is
constructed from parts of the padlist at loading time.

=cut

sub constants
{
   my $self = shift;
   my $df = $self->{df};
   return map { $df->sv_at($_) } @{ $self->{consts_at} };
}

=head2 @svs = $cv->globrefs

Returns a list of the SVs used as GLOB references in the code. On ithreads
perl the constants are part of the padlist structure so this list is
constructed from parts of the padlist at loading time.

=cut

sub globrefs
{
   my $self = shift;
   my $df = $self->{df};
   return map { $df->sv_at($_) } @{ $self->{gvs_at} };
}

sub stashname { my $self = shift; return $self->stash ? $self->stash->stashname : undef }

sub name
{
   my $self = shift;
   return unless $self->{glob_at};
   return '&' . $self->{df}->sv_at( $self->{glob_at} )->stashname;
}

sub depth
{
   my $self = shift;
   return scalar @{ $self->{padsvs_at} };
}

=head2 $name = $cv->padname( $padix )

Returns the name of the $padix'th lexical variable, or C<undef> if it doesn't
have a name

=cut

sub padname
{
   my $self = shift;
   my ( $padix ) = @_;

   for( my $scope = $self; $scope; $scope = $scope->scope ) {
      my $padnames = $scope->{padnames};
      return $padnames->[$padix] if $padnames->[$padix];
   }

   return undef;
}

=head2 $padnames = $cv->padnames

Returns the AV reference directly which stores the pad names.

=cut

sub padnames
{
   my $self = shift;
   return $self->{padnames_av};
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

   my $maxdepth = $pads ? $#{ $self->{padsvs_at} } : 0;

   my $padlist = $self->padlist;

   # If we have a PADLIST then its contents are indirect; if not then they are direct strong
   my $padnames_desc = $padlist ? ";the padnames indirectly"
                                : "+the padnames directly";
   my $pad_descf     = $padlist ? ";pad at depth %d indirectly"
                                : "+pad at depth %d directly";

   return (
      ( $self->is_weakoutside ? "-the scope" : "+the scope" ) =>
         $self->scope,

      "-the stash" => $self->stash,

      ( $self->is_cvgv_rc ? "+the glob" : "-the glob" ) =>
         $self->glob,

      "+the constant value" => $self->constval,
      ".the protosub" => $self->protosub,

      ( map { +";a constant" => $_ } $self->constants ),
      ( map { +";a referenced glob" => $_ } $self->globrefs ),

      "+the padlist" => $padlist,
      $padnames_desc => $self->{padnames_av},

      ( map {
            my $depth = $_;
            sprintf( $pad_descf, $depth ) => $pads->[$depth-1],
         } 1 .. $maxdepth ),
   );
}

package Devel::MAT::SV::IO;
use base qw( Devel::MAT::SV );
our $VERSION = '0.12';
__PACKAGE__->register_type( 8 );

sub load
{
   my $self = shift;
   my ( $header, $ptrs, $strs ) = @_;

   @{$self}{qw( topgv_at formatgv_at bottomgv_at )} =
      @$ptrs;
}

sub topgv    { my $self = shift; $self->{df}->sv_at( $self->{topgv_at}    ) }
sub formatgv { my $self = shift; $self->{df}->sv_at( $self->{formatgv_at} ) }
sub bottomgv { my $self = shift; $self->{df}->sv_at( $self->{bottomgv_at} ) }

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
our $VERSION = '0.12';
__PACKAGE__->register_type( 9 );

sub load
{
   my $self = shift;
   my ( $header, $ptrs, $strs ) = @_;
   my $df = $self->{df};

   ( $self->{type}, $self->{off}, $self->{len} ) =
      unpack "a1 $df->{uint_fmt}2", $header;

   ( $self->{targ_at} ) =
      @$ptrs;
}

sub lvtype { my $self = shift; return $self->{type} }
sub off    { my $self = shift; return $self->{off} }
sub len    { my $self = shift; return $self->{len} }
sub target { my $self = shift; return $self->{df}->sv_at( $self->{targ_at} ) }

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
our $VERSION = '0.12';
__PACKAGE__->register_type( 10 );

sub load {}

sub desc { "REGEXP()" }

sub _outrefs { () }

package Devel::MAT::SV::FORMAT;
use base qw( Devel::MAT::SV );
our $VERSION = '0.12';
__PACKAGE__->register_type( 11 );

sub load {}

sub desc { "FORMAT()" }

sub _outrefs { () }

package Devel::MAT::SV::INVLIST;
use base qw( Devel::MAT::SV );
our $VERSION = '0.12';
__PACKAGE__->register_type( 12 );

sub load {}

sub desc { "INVLIST()" }

sub _outrefs { () }

=head1 AUTHOR

Paul Evans <leonerd@leonerd.org.uk>

=cut

0x55AA;
