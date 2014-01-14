#  You may distribute under the terms of either the GNU General Public License
#  or the Artistic License (the same terms as Perl itself)
#
#  (C) Paul Evans, 2013 -- leonerd@leonerd.org.uk

package Devel::MAT::Context;

use strict;
use warnings;

our $VERSION = '0.15';

use Carp;
use Scalar::Util qw( weaken );

=head1 NAME

C<Devel::MAT::Context> - represent a single call context state

=head1 DESCRIPTION

Objects in this class represent a single level of state from the call context.
These contexts represent function calls between perl functions.

=cut

my %types;
sub register_type
{
   $types{$_[1]} = $_[0];
   # generate the ->type constant method
   ( my $typename = $_[0] ) =~ s/^Devel::MAT::Context:://;
   no strict 'refs';
   *{"$_[0]::type"} = sub () { $typename };
}

sub _new
{
   my $class = shift;
   my ( $df ) = @_;

   my $self = bless {}, $class;
   weaken( $self->{df} = $df );
   return $self;
}

sub load
{
   my $class = shift;
   my ( $type, $df ) = @_;

   $types{$type} or croak "Cannot load unknown CTX type $type";

   my $self = $types{$type}->_new( $df );

   # Standard fields all Contexts have
   $self->{gimme} = $df->_read_u8;
   $self->{file}  = $df->_read_str;
   $self->{line}  = $df->_read_uint;

   $self->_load( $df );

   return $self;
}

=head1 COMMON METHODS

=cut

=head2 $gimme = $ctx->gimme

Returns the gimme value of the call context.

=cut

my @GIMMES = ( undef, qw( void scalar array ) );
sub gimme
{
   my $self = shift;
   return $GIMMES[ $self->{gimme} ];
}

=head2 $file = $ctx->file

=head2 $line = $ctx->line

=head2 $location = $ctx->location

Returns the file, line or location as (C<FILE line LINE>).

=cut

sub file  { my $self = shift; return $self->{file} }
sub line  { my $self = shift; return $self->{line} }

sub location
{
   my $self = shift;
   return "$self->{file} line $self->{line}";
}

package Devel::MAT::Context::SUB;
use base qw( Devel::MAT::Context );
our $VERSION = '0.15';
__PACKAGE__->register_type( 1 );

=head1 Devel::MAT::Context::SUB

Represents a context which is a subroutine call.

=cut

sub _load
{
   my $self = shift;
   my ( $df ) = @_;

   $self->{cv_at}   = $df->_read_ptr;
   $self->{args_at} = $df->_read_ptr;
}

=head2 $cv = $ctx->cv

Returns the CV which this call is to.

=head2 $args = $ctx->args

Returns the arguments AV which represents the C<@_> argument array.

=cut

sub cv   { my $self = shift; return $self->{df}->sv_at( $self->{cv_at} ) }
sub args { my $self = shift; return $self->{df}->sv_at( $self->{args_at} ) }

package Devel::MAT::Context::TRY;
use base qw( Devel::MAT::Context );
our $VERSION = '0.15';
__PACKAGE__->register_type( 2 );

=head1 Devel::MAT::Context::TRY

Represents a context which is a block C<eval {}> call.

=cut

sub _load {}

package Devel::MAT::Context::EVAL;
use base qw( Devel::MAT::Context );
our $VERSION = '0.15';
__PACKAGE__->register_type( 3 );

=head1 Devel::MAT::Context::EVAL

Represents a context which is a string C<eval EXPR> call.

=cut

sub _load
{
   my $self = shift;
   my ( $df ) = @_;

   $self->{code_at} = $df->_read_ptr;
}

=head2 $sv = $ctx->code

Returns the SV containing the text string being evaluated.

=cut

sub code { my $self = shift; return $self->{df}->sv_at( $self->{code_at} ) }

=head1 AUTHOR

Paul Evans <leonerd@leonerd.org.uk>

=cut

0x55AA;
