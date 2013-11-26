#  You may distribute under the terms of either the GNU General Public License
#  or the Artistic License (the same terms as Perl itself)
#
#  (C) Paul Evans, 2013 -- leonerd@leonerd.org.uk

package Devel::MAT::Tool::Inrefs;

use strict;
use warnings;

our $VERSION = '0.10';

use List::Util qw( pairmap pairs pairkeys pairvalues );

=head1 NAME

C<Devel::MAT::Tool::Inrefs> - annotate which SVs are referred to by others

=head1 DESCRIPTION

This C<Devel::MAT> tool annotates each SV with back-references from other SVs
that refer to it. It follows the C<outrefs> method of every heap SV and
annotates the referred SVs with back-references pointing back to the SVs that
refer to them.

=cut

sub new
{
   my $class = shift;
   my ( $pmat, %args ) = @_;

   *Devel::MAT::SV::inrefs = \&sv_inrefs;

   $class->patch_inrefs( $pmat->dumpfile, progress => $args{progress} );

   return $class;
}

sub patch_inrefs
{
   my $self = shift;
   my ( $df, %args ) = @_;

   my $progress = $args{progress};

   my $heap_total = scalar $df->heap;
   my $count = 0;
   foreach my $sv ( $df->heap ) {
      foreach my $ref ( pairvalues $sv->outrefs ) {
         push @{ $ref->{tool_inrefs} }, $sv->addr if !$ref->immortal;
      }

      $count++;
      $progress->( sprintf "Patching refs in %d of %d (%.2f%%)",
         $count, $heap_total, 100*$count / $heap_total ) if $progress and ($count % 200) == 0
   }

   foreach ( pairs $df->roots ) {
      my ( $name, $sv ) = @$_;
      push @{ $sv->{tool_inrefs} }, $name if defined $sv;
   }

   foreach my $addr ( @{ $df->{stack_at} } ) { # TODO
      my $sv = $df->sv_at( $addr ) or next;
      push @{ $sv->{tool_inrefs} }, "a value on the stack";
   }
}

=head1 SV METHODS

This tool adds the following SV methods.

=head2 ( $name, $sv, $name, $sv, ... ) = $sv->inrefs

Returns a name/value list giving names and other SV objects for each of the
SVs that refer to this one. This is formed by the inverse mapping along the SV
graph from C<outrefs>.

=cut

sub sv_inrefs
{
   my $self = shift;

   $self->{tool_inrefs} ||= [];

   return @{ $self->{tool_inrefs} } if !wantarray;

   my $df = $self->{df};
   my %seen;
   my @inrefs;
   foreach ( @{ $self->{tool_inrefs} } ) {
      next if $seen{$_}++;

      if( m/^\d+$/ ) {
         my $sv = $df->sv_at( $_ );
         if( $sv ) {
            push @inrefs, pairmap { $b == $self ? ( $a => $sv ) : () } $sv->outrefs;
         }
         else {
            warn "Unable to find SV at $_ for $sv inref\n";
         }
      }
      else {
         push @inrefs, $_ => undef;
      }
   }

   return @inrefs;
}

=head1 AUTHOR

Paul Evans <leonerd@leonerd.org.uk>

=cut

0x55AA;
