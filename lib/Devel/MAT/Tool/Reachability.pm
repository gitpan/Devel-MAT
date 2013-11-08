#  You may distribute under the terms of either the GNU General Public License
#  or the Artistic License (the same terms as Perl itself)
#
#  (C) Paul Evans, 2013 -- leonerd@leonerd.org.uk

package Devel::MAT::Tool::Reachability;

use strict;
use warnings;

our $VERSION = '0.07';

use constant FOR_UI => 1;

use List::Util qw( pairvalues pairmap );

sub new
{
   my $class = shift;
   my ( $pmat, %args ) = @_;

   # Declare UI elements
   my $column = Devel::MAT::UI->provides_svlist_column(
      title => "Reach",
      type  => "text",
   );

   $class->mark_reachable( $pmat->dumpfile, \my %reachable, progress => $args{progress} );

   Devel::MAT::UI->set_svlist_column_values(
      column => $column,
      from   => sub { $reachable{$_[0]} ? "R" : "u" },
   );

   return $class;
}

sub mark_reachable
{
   my $self = shift;
   my ( $df, $reachable, %args ) = @_;

   my $progress = $args{progress};

   my @queue = pairvalues $df->roots;
   my $count = 0;
   while( @queue ) {
      my $sv = shift @queue or next;
      $reachable->{$sv->addr} = 1;

      push @queue, pairmap { $reachable->{$b->addr} ? () : $b } $sv->outrefs;

      $count++;
      $progress->( sprintf "Marking reachability %d...", $count ) if $progress and $count % 1000 == 0;
   }
}

0x55AA;
