#  You may distribute under the terms of either the GNU General Public License
#  or the Artistic License (the same terms as Perl itself)
#
#  (C) Paul Evans, 2013 -- leonerd@leonerd.org.uk

package Devel::MAT::SV;

use strict;
use warnings;
use feature qw( switch );
no if $] >= 5.017011, warnings => 'experimental::smartmatch';

our $VERSION = '0.02';

use Carp;
use Scalar::Util qw( weaken );
use List::Util qw( pairgrep pairmap pairs );

use constant immortal => 0;

=head1 NAME

=head1 DESCRIPTION

Objects in this class represent individual SV variables found in the arena
during a heap dump. Individual SVs are represented by subclasses, which are
documented below.

=cut

our $ELIDE_RVS = 1;
# Lexical sub, so all inline subclasses can see it
my $direct_or_rv = sub {
   my ( $name, $sv ) = @_;
   if( defined $sv and $sv->desc eq "REF()" and !@{ $sv->{magic} } ) {
      return ( "$name via RV" => $sv->rv );
   }
   else {
      return ( "$name directly" => $sv );
   }
};

my %types;
sub register_type { $types{$_[1]} = $_[0] }

sub _new
{
   my $class = shift;
   my ( $df, $addr ) = @_;

   my $self = bless { addr => $addr, magic => [], inrefs_at => [] }, $class;
   weaken( $self->{df} = $df );
   return $self;
}

sub load
{
   my $class = shift;
   my ( $type, $df ) = @_;

   $types{$type} or croak "Cannot load unknown SV type $type";

   my $self = $types{$type}->_new( $df, $df->_read_ptr );

   # Standard fields all SVs have
   $self->{refcnt}     = $df->_read_u32;
   $self->{blessed_at} = $df->_read_ptr;

   $self->_load( $df );

   return $self;
}

=head1 COMMON METHODS

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

=head2 $padlist = $sv->is_padlist

Returns true if the SV is part of the padlist structure of a CV.

=cut

sub is_padlist
{
   my $self = shift;
   ( $self->{is_padlist} ) = @_ if @_;
   return $self->{is_padlist};
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
SVs that this one directly refs to.

=cut

sub outrefs
{
   my $self = shift;
   my @outrefs = pairgrep { defined $b } $self->_outrefs;

   push @outrefs, "the bless package", $self->blessed if $self->blessed;

   foreach my $mg ( @{ $self->{magic} } ) {
      my ( $type, $obj_at ) = @$mg;
      my $obj = $self->{df}->sv_at( $obj_at );
      push @outrefs, "'$type' magic" => $obj if $obj;
   }

   return @outrefs if wantarray;
   return @outrefs / 2;
}

sub _push_inref_at
{
   my $self = shift;
   my ( $addr ) = @_;

   push @{ $self->{inrefs_at} }, $addr;
}

=head2 %refs = $sv->inrefs

Returns a name/value list giving names and other SV objects for each of the
SVs that refer to this one. This is formed by the inverse mapping along the SV
graph from C<outrefs>.

=cut

sub inrefs
{
   my $self = shift;
   return @{ $self->{inrefs_at} } if !wantarray;

   my $df = $self->{df};
   my %seen;
   my @inrefs;
   foreach ( @{ $self->{inrefs_at} } ) {
      next if $seen{$_}++;

      if( m/^\d+$/ ) {
         my $sv = $df->sv_at( $_ );
         push @inrefs, pairmap { $b == $self ? ( $a => $sv ) : () } $sv->outrefs;
      }
      else {
         push @inrefs, $_ => undef;
      }
   }
   return @inrefs;
}

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
use constant immortal => 1;
sub _outrefs { () }

package Devel::MAT::SV::UNDEF;
use base qw( Devel::MAT::SV::Immortal );
sub desc { "UNDEF" }

package Devel::MAT::SV::YES;
use base qw( Devel::MAT::SV::Immortal );
sub desc { "YES" }

package Devel::MAT::SV::NO;
use base qw( Devel::MAT::SV::Immortal );
sub desc { "NO" }

package Devel::MAT::SV::Unknown;
use base qw( Devel::MAT::SV );
__PACKAGE__->register_type( 0xff );
sub _load {}

sub desc { "UNKNOWN" }

sub _outrefs {}

package Devel::MAT::SV::GLOB;
use base qw( Devel::MAT::SV );
__PACKAGE__->register_type( 1 );

=head1 Devel::MAT::SV::GLOB

Represents a glob; an SV of type C<SVt_PVGV>.

=cut

sub _load
{
   my $self = shift;
   my ( $df ) = @_;

   $self->{name}      = $df->_read_str;
   $self->{stash_at}  = $df->_read_ptr;
   $self->{scalar_at} = $df->_read_ptr;
   $self->{array_at}  = $df->_read_ptr;
   $self->{hash_at}   = $df->_read_ptr;
   $self->{code_at}   = $df->_read_ptr;
   $self->{egv_at}    = $df->_read_ptr;
   $self->{io_at}     = $df->_read_ptr;
   $self->{form_at}   = $df->_read_ptr;
}

sub _fixup
{
   my $self = shift;

   $_ and $_->{glob_at} = $self->addr for $self->scalar, $self->array, $self->hash, $self->code;
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

sub stashname { my $self = shift; return $self->stash->stashname . "::" . $self->{name} }

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
      "the scalar" => $self->scalar,
      "the array"  => $self->array,
      "the hash"   => $self->hash,
      "the code"   => $self->code,
      "the egv"    => $self->egv,
      "the io"     => $self->io,
      "the form"   => $self->form,
   );
}

package Devel::MAT::SV::SCALAR;
use base qw( Devel::MAT::SV );
__PACKAGE__->register_type( 2 );

=head1 Devel::MAT::SV::SCALAR

Represents a scalar value; an SV of any of the types up to and including
C<SVt_PVMV> (that is, C<IV>, C<NV>, C<PV>, C<PVIV>, C<PVNV> or C<PVMG>). This
includes all numbers, integers and floats, strings, references, and dualvars
containing multiple parts.

=cut

sub _load
{
   my $self = shift;
   my ( $df ) = @_;

   my $flags = $df->_read_u8;

   $self->{uv}    = $df->_read_uint if $flags & 0x01;
   $self->{nv}    = $df->_read_nv   if $flags & 0x04;
   $self->{pv}    = $df->_read_str  if $flags & 0x08;
   $self->{rv_at} = $df->_read_ptr  if $flags & 0x10;
}

=head2 $uv = $sv->uv

Returns the integer numeric portion, if valid, or C<undef>.

=head2 $nv = $sv->nv

Returns the floating numeric portion, if valid, or C<undef>.

=head2 $pv = $sv->pv

Returns the string portion, if valid, or C<undef>.

=head2 $svrv = $sv->rv

Returns the SV referred to by the reference portion, if valid, or C<undef>.

=cut

sub uv { my $self = shift; return $self->{uv} }
sub nv { my $self = shift; return $self->{nv} }
sub pv { my $self = shift; return $self->{pv} }
sub rv { my $self = shift; return $self->{rv_at} ? $self->{df}->sv_at( $self->{rv_at} ) : undef }

sub name
{
   my $self = shift;
   return unless $self->{glob_at};
   return '$' . $self->{df}->sv_at( $self->{glob_at} )->stashname;
}

sub desc
{
   my $self = shift;

   return "REF()" if $self->rv;

   my $flags = "";
   $flags .= "U" if defined $self->{uv};
   $flags .= "N" if defined $self->{nv};
   $flags .= "P" if defined $self->{pv};
   return "SCALAR($flags)";
}

sub _outrefs
{
   my $self = shift;
   return (
      "the referrant" => $self->rv,
   );
}

package Devel::MAT::SV::ARRAY;
use base qw( Devel::MAT::SV );
__PACKAGE__->register_type( 3 );

=head1 Devel::MAT::SV::ARRAY

Represents an array; an SV of type C<SVt_PVAV>.

=cut

sub _load
{
   my $self = shift;
   my ( $df ) = @_;

   my $n = $df->_read_uint;
   $self->{elems_at} = [ map { $df->_read_ptr } 1 .. $n ];
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
   return "ARRAY(" . scalar($self->elems) . ")";
}

sub _outrefs
{
   my $self = shift;
   return map {
      $direct_or_rv->( "element [$_]" => $self->elem( $_ ) )
   } 0 .. $#{ $self->{elems_at} };
}

package Devel::MAT::SV::HASH;
use base qw( Devel::MAT::SV );
__PACKAGE__->register_type( 4 );

=head1 Devel::MAT::SV::HASH

Represents a hash; an SV of type C<SVt_PVHV>. The C<Devel::MAT::SV::STASH>
subclass is used to represent hashes that are used as stashes.

=cut

sub _load
{
   my $self = shift;
   my ( $df ) = @_;

   my $n = $df->_read_uint;
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
   return map {
      $direct_or_rv->( "value {$_}" => $self->value( $_ ) )
   } $self->keys;
}

package Devel::MAT::SV::STASH;
use base qw( Devel::MAT::SV::HASH );
__PACKAGE__->register_type( 5 );

=head1 Devel::MAT::SV::STASH

Represents a hash used as a stash; an SV of type C<SVt_PVHV> whose C<HvNAME()>
is non-NULL. This is a subclass of C<Devel::MAT::SV::HASH>.

=cut

sub _load
{
   my $self = shift;
   my ( $df ) = @_;

   $self->{name} = $df->_read_str;
   $self->{backrefs_at} = $df->_read_ptr;
   $self->{mro_isa_at} = $df->_read_ptr;

   $self->SUPER::_load( @_ );
}

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
   my $df = $self->{df};
   return $self->SUPER::_outrefs,
      "the backrefs list" => $df->sv_at( $self->{backrefs_at} ),
      "the mro ISA cache" => $df->sv_at( $self->{mro_isa_at} );
}

package Devel::MAT::SV::CODE;
use base qw( Devel::MAT::SV );
__PACKAGE__->register_type( 6 );

=head1 Devel::MAT::SV::CODE

Represents a function or closure; an SV of type C<SVt_PVCV>.

=cut

sub _load
{
   my $self = shift;
   my ( $df ) = @_;

   $self->{stash_at}    = $df->_read_ptr;
   $self->{glob_at}     = $df->_read_ptr;
   $self->{file}        = $df->_read_str;
   $self->{scope_at}    = $df->_read_ptr;
   $self->{padlist_at}  = $df->_read_ptr;
   $self->{constval_at} = $df->_read_ptr;

   $self->{consts_at} = \my @consts;
   $self->{constix}   = \my @constix;
   $self->{gvs_at} = \my @gvs;
   $self->{gvix}   = \my @gvix;

   while( my $type = $df->_read_u8 ) {
      given( $type ) {
         when( 1 ) { push @consts, $df->_read_ptr }
         when( 2 ) { push @constix, $df->_read_uint }
         when( 3 ) { push @gvs, $df->_read_ptr }
         when( 4 ) { push @gvix, $df->_read_uint }
         default   { die "TODO: unhandled CODEx type $type"; }
      }
   }
}

sub _fixup
{
   my $self = shift;
   return unless $self->{padlist_at};

   my $df = $self->{df};

   my $padlist = $self->padlist;
   $padlist->is_padlist(1);

   $_->is_padlist(1) for $padlist->elems;

   # PADLIST[0] stores the names of the lexicals
   # The rest stores the actual pads
   my ( $lexnames, @pads ) = $padlist->elems;

   $self->{lexnames} = [ map { $_->is_padlist(1); $_ } $lexnames->elems ];

   foreach my $pad ( @pads ) {
      $pad = [ map { $_->is_padlist(1) if $_; $_ } $pad->elems ];
   }
   $self->{pads} = \@pads;

   # Under ithreads, constants are actually stored in the first padlist
   if( $df->ithreads ) {
      my $pad0 = $pads[0];

      my %constix = map { $_ => 1 } @{ $self->{constix} };
      my %gvix    = map { $_ => 1 } @{ $self->{gvix} };

      @{$self->{consts_at}} = map { $pad0->[$_] ? $pad0->[$_]->addr : undef } @{ $self->{constix} };
      @{$self->{gvs_at}}    = map { $pad0->[$_] ? $pad0->[$_]->addr : undef } @{ $self->{gvix} };

      # Clear the obviously unused elements of lexnames and padlists
      foreach my $ix ( @{ delete $self->{constix} }, @{ delete $self->{gvix} } ) {
         undef $self->{lexnames}[$ix];
         undef $_->[$ix] for @pads;
      }
   }
}

=head2 $stash = $cv->stash

=head2 $gv = $cv->glob

=head2 $filename = $cv->file

=head2 $scope_cv = $cv->scope

=head2 $av = $cv->padlist

=head2 $sv = $cv->constval

Returns the stash, glob, filename, scope, padlist or constant value of the
code.

=cut

sub stash    { my $self = shift; return $self->{df}->sv_at( $self->{stash_at} ) }
sub glob     { my $self = shift; return $self->{df}->sv_at( $self->{glob_at} ) }
sub file     { my $self = shift; return $self->{file} }
sub scope    { my $self = shift; return $self->{df}->sv_at( $self->{scope_at} ) }
sub padlist  { my $self = shift; return $self->{df}->sv_at( $self->{padlist_at} ) }
sub constval { my $self = shift; return $self->{df}->sv_at( $self->{constval_at} ) }

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

sub lexnames { my $self = shift; return $self->padlist ? $self->padlist->elem(0) : undef }

sub depth
{
   my $self = shift;
   return scalar @{ $self->{pads} };
}

sub lexvars
{
   my $self = shift;
   my ( $depth ) = @_;

   my $names = $self->{lexnames};
   my $pad = $self->{pads}[$depth];

   my @ret;
   foreach my $i ( 1 .. $#$pad ) {
      my $name = "<unknown>";
      for( my $scope = $self; $scope; $scope = $scope->scope ) {
         my $namepv = $scope->{lexnames}->[$i];
         $name = $namepv->pv, last if $namepv and $namepv->isa( "Devel::MAT::SV::SCALAR" );
      }

      push @ret, [ $name, $pad->[$i] ];
   }
   return @ret;
}

sub desc
{
   my $self = shift;
   return "CODE(stash)" if $self->stash;
   return "CODE()";
}

sub _outrefs
{
   my $self = shift;
   my $lexnames = $self->lexnames;
   my $pads     = $self->{pads};

   return (
      "the scope" => $self->scope,
      "the stash" => $self->stash,
      "the glob"  => $self->glob,
      "the padlist" => $self->padlist,
      "the lexnames" => $lexnames,
      ( $lexnames ?
         map { +"a lexical variable name" => $_ } $lexnames->elems :
         () ),
      "the constant value" => $self->constval,
      ( map { +"a constant" => $_ } $self->constants ),
      ( map { +"a referenced glob" => $_ } $self->globrefs ),
      ( map {
            my $pad = $_;
            map {
               my $sv = $pad->[$_];
               my $lexname = $lexnames->elem( $_ );
               my $name = ( ref $lexname eq "Devel::MAT::SV::SCALAR" and $lexname->pv ) ?
                  "the lexical " . $lexname->pv : "a lexical";
               $direct_or_rv->( $name => $sv )
            } 1 .. $#$pad
         } @$pads ),
      ( map { $direct_or_rv->( "an argument" => $_ ) }
         map { my $args = $_->[0];
              $args && $args->isa( "Devel::MX::SV::ARRAY" ) ? $args->elems : ()
            } @$pads ),
   );
}

package Devel::MAT::SV::IO;
use base qw( Devel::MAT::SV );
__PACKAGE__->register_type( 7 );

sub _load
{
   my $self = shift;
   my ( $df ) = @_;

   $self->{topgv_at}    = $df->_read_ptr;
   $self->{formatgv_at} = $df->_read_ptr;
   $self->{bottomgv_at} = $df->_read_ptr;
}

sub topgv    { my $self = shift; $self->{df}->sv_at( $self->{topgv_at}    ) }
sub formatgv { my $self = shift; $self->{df}->sv_at( $self->{formatgv_at} ) }
sub bottomgv { my $self = shift; $self->{df}->sv_at( $self->{bottomgv_at} ) }

sub desc { "IO()" }

sub _outrefs
{
   my $self = shift;
   return (
      "the top GV" => $self->topgv,
      "the format GV" => $self->formatgv,
      "the bottom GV" => $self->bottomgv,
   );
}

package Devel::MAT::SV::LVALUE;
use base qw( Devel::MAT::SV );
__PACKAGE__->register_type( 8 );

sub _load
{
   my $self = shift;
   my ( $df ) = @_;

   $self->{type} = chr $df->_read_u8;
   $self->{off}  = $df->_read_uint;
   $self->{len}  = $df->_read_uint;
   $self->{targ_at} = $df->_read_ptr;
}

sub type   { my $self = shift; return $self->{type} }
sub off    { my $self = shift; return $self->{off} }
sub len    { my $self = shift; return $self->{len} }
sub target { my $self = shift; return $self->{df}->sv_at( $self->{targ_at} ) }

sub desc { "LVALUE()" }

sub _outrefs
{
   my $self = shift;
   return (
      "the target" => $self->target,
   );
}

package Devel::MAT::SV::REGEXP;
use base qw( Devel::MAT::SV );
__PACKAGE__->register_type( 9 );

sub _load {}

sub desc { "REGEXP()" }

sub _outrefs { () }

package Devel::MAT::SV::FORMAT;
use base qw( Devel::MAT::SV );
__PACKAGE__->register_type( 10 );

sub _load {}

sub desc { "FORMAT()" }

sub _outrefs { () }

=head1 AUTHOR

Paul Evans <leonerd@leonerd.org.uk>

=cut

0x55AA;
