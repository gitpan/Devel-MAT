#  You may distribute under the terms of either the GNU General Public License
#  or the Artistic License (the same terms as Perl itself)
#
#  (C) Paul Evans, 2013 -- leonerd@leonerd.org.uk

package Devel::MAT;

use strict;
use warnings;

our $VERSION = '0.15';

use Carp;
use List::Util qw( pairs );

use Devel::MAT::Dumpfile;

use Module::Pluggable
   sub_name => "_available_tools",
   search_path => [ "Devel::MAT::Tool" ],
   require => 1;

require XSLoader;
XSLoader::load( __PACKAGE__, $VERSION );

=head1 NAME

C<Devel::MAT> - Perl Memory Analysis Tool

=head1 DESCRIPTION

A C<Devel::MAT> instance loads a heapdump file, and provides a container to
store analysis tools to work on it. Tools may be provided that conform to the
L<Devel::MAT::Tool> API, which can help analyse the data and interact with the
explorer user interface by using the methods in the L<Devel::MAT::UI> package.

=head2 File Format

The dump file format is still under development, so at present no guarantees
are made on whether files can be loaded over mismatching versions of
C<Devel::MAT>. However, as of version 0.11 the format should be more
extensible, allowing new SV fields to be added without breaking loading - older
tools will ignore new fields and newer tools will just load undef for fields
absent in older files. As the distribution approaches maturity the format will
be made more stable.

=cut

=head1 CONSTRUCTOR

=cut

=head2 $pmat = Devel::MAT->load( $path, %args )

Loads a heap dump file from the given path, and returns a new C<Devel::MAT>
instance wrapping it.

=cut

sub load
{
   my $class = shift;

   my $df = Devel::MAT::Dumpfile->load( @_ );

   return bless {
      df => $df,
   }, $class;
}

=head1 METHODS

=cut

=head2 $df = $pmat->dumpfile

Returns the underlying L<Devel::MAT::Dumpfile> instance backing this analysis
object.

=cut

sub dumpfile
{
   my $self = shift;
   return $self->{df};
}

=head2 @tools = $pmat->available_tools

Lists the L<Devel::MAT::Tool> classes that are installed and available.

=cut

{
   my @TOOLS;
   my $TOOLS_LOADED;

   sub available_tools
   {
      return @TOOLS if $TOOLS_LOADED;

      $TOOLS_LOADED++;
      return @TOOLS = map { $_ =~ s/^Devel::MAT::Tool:://; $_ } shift->_available_tools;
   }
}

=head2 $tool = $pmat->load_tool( $name )

Loads the named L<Devel::MAT::Tool> class.

=cut

sub load_tool
{
   my $self = shift;
   my ( $name, %args ) = @_;

   # Ensure tools are 'require'd
   $self->available_tools;

   my $tool_class = "Devel::MAT::Tool::$name";
   return $self->{tools}{$name} ||= $tool_class->new( $self, %args );
}

=head2 @text = $pmat->identify( $sv, %opts )

Traces the tree of inrefs from C<$sv> back towards the known roots, returning
a textual description as a list of lines of text.

The lines of text, when printed, will form a reverse reference tree, showing
the paths from the given SV back to the roots.

This method will load L<Devel::MAT::Tool::Inrefs> if it isn't yet loaded.

The following named options are recognised:

=over 4

=item depth => INT

If specified, stop recursing after the specified count. A depth of 1 will only
print immediately referring SVs, 2 will print the referrers of those, etc.

=item strong => BOOL

=item direct => BOOL

Specifies the type of inrefs followed. By default all inrefs are followed.
Passing C<strong> will follow only strong direct inrefs. Passing C<direct>
will follow only direct inrefs.

=back

=cut

sub identify
{
   my $self = shift;
   my ( $sv, %opts ) = @_;

   my $seen = $opts{seen} //= {};

   $self->load_tool( "Inrefs" );

   if( $sv->immortal ) {
      return ( "undef" ) if $sv->type eq "UNDEF";
      return $sv->uv ? "true" : "false";
   }

   my $svaddr = $sv->addr;

   foreach ( pairs $self->dumpfile->roots ) {
      my ( $name, $root ) = @$_;
      return $name if $root and $svaddr == $root->addr;
   }

   $seen->{$svaddr} = 1;

   my @ret = ();
   my %inrefs = $opts{strong} ? $sv->inrefs_strong :
                $opts{direct} ? $sv->inrefs_direct :
                                $sv->inrefs;
   foreach my $desc ( sort keys %inrefs ) {
      my $ref = $inrefs{$desc};

      if( !defined $ref ) {
         push @ret, $desc; # e.g. "a value on the stack"
         next;
      }

      my @me;
      if( $ref == $sv ) {
         @me = "itself";
      }
      elsif( $seen->{$ref->addr} ) {
         @me = "already found";
      }
      elsif( !defined $opts{depth} or $opts{depth} ) {
         $seen->{$ref->addr}++;
         @me = ( defined $opts{depth} ) ? $self->identify( $ref, %opts, depth => $opts{depth}-1 )
                                        : $self->identify( $ref, %opts );
      }
      else {
         @me = "not found at this depth";
      }

      push @ret,
         sprintf( "%s of %s, which is:", $desc, $ref->desc_addr ),
         map { "  $_" } @me;
   }

   return "not found" unless @ret;
   return @ret;
}

=head2 $sv = $pmat->find_symbol( $name )

Attempts to walk the symbol table looking for a symbol of the given name,
which must include the sigil.

 $Package::Name::symbol_name => to return a SCALAR SV
 @Package::Name::symbol_name => to return an ARRAY SV
 %Package::Name::symbol_name => to return a HASH SV
 &Package::Name::symbol_name => to return a CODE SV

=cut

sub find_symbol
{
   my $self = shift;
   my ( $name ) = @_;

   my ( $sigil, $globname ) = $name =~ m/^([\$\@%&])(.*)$/ or
      croak "Could not parse sigil from $name";

   my $glob = $self->find_glob( $globname );

   my $slot = ( $sigil eq '$' ) ? "scalar" :
              ( $sigil eq '@' ) ? "array"  :
              ( $sigil eq '%' ) ? "hash"   :
              ( $sigil eq '&' ) ? "code"   :
                                  die "ARGH"; # won't happen

   my $sv = $glob->$slot or
      croak "\*$globname has no $slot slot";
   return $sv;
}

=head2 $gv = $pmat->find_glob( $name )

Attempts to walk to the symbol table looking for a symbol of the given name,
returning the C<GLOB> object if found.

=cut

sub find_glob
{
   my $self = shift;
   my ( $name ) = @_;

   my ( $parent, $shortname ) = $name =~ m/^(?:(.*)::)?(.+?)$/;

   my $stash;
   if( defined $parent and length $parent ) {
      my $parentgv = $self->find_glob( $parent . "::" );
      $stash = $parentgv->hash or croak "$parent has no hash";
   }
   else {
      $stash = $self->dumpfile->defstash;
   }

   my $gv = $stash->value( $shortname ) or
      croak $stash->stashname . " has no symbol $shortname";
   return $gv;
}

=head1 AUTHOR

Paul Evans <leonerd@leonerd.org.uk>

=cut

0x55AA;
