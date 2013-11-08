#  You may distribute under the terms of either the GNU General Public License
#  or the Artistic License (the same terms as Perl itself)
#
#  (C) Paul Evans, 2013 -- leonerd@leonerd.org.uk

package Devel::MAT;

use strict;
use warnings;

our $VERSION = '0.07';

use Devel::MAT::Dumpfile;

use Module::Pluggable
   sub_name => "_available_tools",
   search_path => [ "Devel::MAT::Tool" ],
   require => 1;

=head1 NAME

C<Devel::MAT> - analyse perl memory usage

=head1 DESCRIPTION

A C<Devel::MAT> instance loads a heapdump file, and provides a container to
store analysis tools to work on it. Tools may be provided that conform to the
L<Devel::MAT::Tool> API, which can help analyse the data and interact with the
explorer user interface by using the methods in the L<Devel::MAT::UI> package.

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

sub available_tools
{
   return map { $_ =~ s/^Devel::MAT::Tool:://; $_ } shift->_available_tools;
}

=head2 $tool = $pmat->load_tool( $name )

Loads the named L<Devel::MAT::Tool> class.

=cut

sub load_tool
{
   my $self = shift;
   my ( $name, %args ) = @_;

   my $tool_class = "Devel::MAT::Tool::$name";
   return $self->{tools}{$name} ||= $tool_class->new( $self, %args );
}

=head1 AUTHOR

Paul Evans <leonerd@leonerd.org.uk>

=cut

0x55AA;
