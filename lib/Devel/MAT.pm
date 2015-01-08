#  You may distribute under the terms of either the GNU General Public License
#  or the Artistic License (the same terms as Perl itself)
#
#  (C) Paul Evans, 2013-2014 -- leonerd@leonerd.org.uk

package Devel::MAT;

use strict;
use warnings;

our $VERSION = '0.20';

use Carp;
use List::Util qw( pairs );
use List::UtilsBy qw( sort_by );

use Devel::MAT::Dumpfile;
use Devel::MAT::Graph;

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
      my $self = shift;

      return @TOOLS if $TOOLS_LOADED;

      $TOOLS_LOADED++;
      @TOOLS = map { $_ =~ s/^Devel::MAT::Tool:://; $_ } $self->_available_tools;

      foreach my $name ( @TOOLS ) {
         my $tool_class = "Devel::MAT::Tool::$name";
         next unless $tool_class->can( "AUTOLOAD_TOOL" ) and $tool_class->AUTOLOAD_TOOL( $self );

         $self->{tools}{$name} ||= $tool_class->new( $self );
      }

      return @TOOLS;
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

=head2 $node = $pmat->inref_graph( $sv, %opts )

Traces the tree of inrefs from C<$sv> back towards the known roots, returning
a L<Devel::MAT::Graph> node object representing it, within a graph of reverse
references back to the known roots.

This method will load L<Devel::MAT::Tool::Inrefs> if it isn't yet loaded.

The following named options are recognised:

=over 4

=item depth => INT

If specified, stop recursing after the specified count. A depth of 1 will only
include immediately referring SVs, 2 will print the referrers of those, etc.
Nodes with inrefs that were trimmed because of this limit will appear to be
roots with a special name of C<EDEPTH>.

=item strong => BOOL

=item direct => BOOL

Specifies the type of inrefs followed. By default all inrefs are followed.
Passing C<strong> will follow only strong direct inrefs. Passing C<direct>
will follow only direct inrefs.

=back

=cut

sub inref_graph
{
   my $self = shift;
   my ( $sv, %opts ) = @_;

   my $graph = $opts{graph} //= Devel::MAT::Graph->new( $self->dumpfile );

   $self->load_tool( "Inrefs" );

   if( $sv->immortal ) {
      my $desc = $sv->type eq "UNDEF" ? "undef" :
                 $sv->uv              ? "true" :
                                        "false";
      $graph->add_root( $sv, $desc );
      return $graph->get_sv_node( $sv );
   }

   my $svaddr = $sv->addr;

   foreach ( pairs $self->dumpfile->roots ) {
      my ( $name, $root ) = @$_;
      $root and $svaddr == $root->addr and
         $graph->add_root( $sv, $name ), return $graph->get_sv_node( $sv );
   }

   $graph->add_sv( $sv );

   my @ret = ();
   my @inrefs = $opts{strong} ? $sv->inrefs_strong :
                $opts{direct} ? $sv->inrefs_direct :
                                $sv->inrefs;
   foreach my $ref ( sort_by { $_->name } @inrefs ) {
      if( !defined $ref->sv ) {
         # e.g. "a value on the stack"
         $graph->add_root( $sv, $ref->name );
         push @ret, $ref->name;
         next;
      }

      if( defined $opts{depth} and not $opts{depth} ) {
         $graph->add_root( $sv, "EDEPTH" );
         last;
      }

      my @me;
      if( $graph->has_sv( $ref->sv ) ) {
         $graph->add_ref( $ref->sv, $sv, $ref );
         # Don't recurse into it as it was already found
      }
      else {
         $graph->add_sv( $ref->sv ); # add first to stop inf. loops

         defined $opts{depth} ? $self->inref_graph( $ref->sv, %opts, depth => $opts{depth}-1 )
                              : $self->inref_graph( $ref->sv, %opts );
         $graph->add_ref( $ref->sv, $sv, $ref );
      }
   }

   return $graph->get_sv_node( $sv );
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
