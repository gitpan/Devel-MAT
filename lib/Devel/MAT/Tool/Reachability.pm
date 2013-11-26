#  You may distribute under the terms of either the GNU General Public License
#  or the Artistic License (the same terms as Perl itself)
#
#  (C) Paul Evans, 2013 -- leonerd@leonerd.org.uk

package Devel::MAT::Tool::Reachability;

use strict;
use warnings;
use feature qw( switch );
no if $] >= 5.017011, warnings => 'experimental::smartmatch';

our $VERSION = '0.10';

use constant FOR_UI => 1;

use List::Util qw( pairvalues pairmap );

=head1 NAME

C<Devel::MAT::Tool::Reachability> - analyse how SVs are reachable

=head1 DESCRIPTION

This C<Devel::MAT> tool determines which SVs are reachable via any known roots
and which are not. For reachable SVs, they are classified into several broad
categories:

=over 2

=item *

SVs that directly make up the symbol table.

=item *

SVs that form the padlist of functions or store the names of lexical
variables.

=item *

SVs that hold the value of lexical variables.

=item *

User data stored in package globals, lexical variables, or referenced
recursively via structures stored in them.

=item *

Miscellaneous other SVs that are used to implement the internals of the
interpreter.

=back

=cut

use constant {
   REACH_SYMTAB   => 1,
   REACH_USER     => 2,
   REACH_PADLIST  => 3,
   REACH_LEXICAL  => 4,
   REACH_INTERNAL => 5,
};

sub new
{
   my $class = shift;
   my ( $pmat, %args ) = @_;

   *Devel::MAT::SV::reachable = sub {
      my $sv = shift;
      return $sv->{tool_reachable};
   };

   $class->mark_reachable( $pmat->dumpfile, progress => $args{progress} );

   return $class;
}

my @ICONS = (
   "none", "symtab", "user", "padlist", "lexical", "internal"
);
sub _reach2icon
{
   my ( $sv ) = @_;
   my $reach = $sv->{tool_reachable} // 0;

   my $icon = $ICONS[$reach] // die "Unknown reachability value $reach";
   return "reachable-$icon";
}

sub init_ui
{
   my $self = shift;
   my ( $ui ) = @_;

   foreach ( @ICONS ) {
      $ui->register_icon(
         name => "reachable-$_",
         svg  => "icons/reachable-$_.svg"
      );
   }

   my $column = $ui->provides_svlist_column(
      title => "R",
      type  => "icon",
   );

   $ui->provides_sv_detail(
      title  => "Reachable",
      type   => "icon",
      render => \&_reach2icon,
   );

   $ui->set_svlist_column_values(
      column => $column,
      from   => \&_reach2icon,
   );
}

sub mark_reachable
{
   my $self = shift;
   my ( $df, %args ) = @_;

   my $progress = $args{progress};

   my @user;
   my @internal;

   # First, walk the symbol table
   {
      my @queue = ( $df->defstash );
      my $count = 0;
      while( @queue ) {
         my $stash = shift @queue;
         $stash->type eq "STASH" or die "ARGH! Encountered non-stash ".$stash->desc_addr;

         $stash->{tool_reachable} = REACH_SYMTAB;

         foreach my $key ( $stash->keys ) {
            my $value = $stash->value( $key );

            # Keys ending :: signify sub-stashes
            if( $key =~ m/::$/ ) {
               $value->{tool_reachable} = REACH_SYMTAB;
               push @queue, $value->hash unless $value->hash->{tool_reachable};
            }
            # Otherwise it might be a glob
            elsif( $value->type eq "GLOB" ) {
               my $gv = $value;
               $gv->{tool_reachable} = REACH_SYMTAB;

               defined $_ and push @user, $_ for
                  $gv->scalar, $gv->array, $gv->hash, $gv->code, $gv->io, $gv->form;
            }
            # Otherwise it might be a SCALAR/ARRAY/HASH directly in the STASH
            else {
               push @user, $value;
            }

            $count++;
            $progress->( sprintf "Walking symbol table %d...", $count ) if $progress and $count % 1000 == 0;
         }

         push @internal,
            $stash->backrefs;
            grep { defined } pairvalues $stash->magic;

         $count++;
         $progress->( sprintf "Walking symbol table %d...", $count ) if $progress and $count % 1000 == 0;
      }
   }

   # Next the reachable user data, recursively
   {
      my @queue = ( @user, $df->main_cv );
      my $count = 0;
      while( @queue ) {
         my $sv = shift @queue or next;
         $sv->{tool_reachable} ||= REACH_USER;

         my @more;
         given( $sv->type ) {
            when( "SCALAR" ) { push @more, $sv->rv if $sv->rv }
            when( "ARRAY" )  { push @more, $sv->elems; }
            when( "HASH" )   { push @more, $sv->values; }
            when( "GLOB" ) {
               # Any user GLOBs we find should just be IO refs
               my $gv = $sv;
               $gv->io or warn "Found a user GLOB that isn't an IO ref";
               $gv->{tool_reachable} = REACH_USER;
            }
            when( "CODE" ) {
               my $cv = $sv;

               $cv->padlist and $cv->padlist->{tool_reachable} = REACH_PADLIST;

               my $padnames = $cv->padnames_av;
               if( $padnames ) {
                  $_ and $_->{tool_reachable} = REACH_PADLIST for $padnames, $padnames->elems;
               }

               foreach my $pad ( $cv->pads ) {
                  $pad or next;
                  $pad->{tool_reachable} = REACH_PADLIST;

                  # PAD slot 0 is always @_
                  if( my $argsav = $pad->elem( 0 ) ) {
                     $argsav->{tool_reachable} = REACH_INTERNAL;
                  }

                  foreach my $padix ( 1 .. $pad->elems-1 ) {
                     my $padname_sv = $padnames ? $padnames->elem( $padix ) : undef;
                     my $padname = $padname_sv && $padname_sv->type eq "SCALAR" ?
                        $padname_sv->pv : undef;

                     my $sv = $pad->elem( $padix ) or next;
                     $sv->immortal and next;

                     if( $padname and $padname ne "&" ) {
                        # Named slots are lexical vars, but pad name "&" is used
                        # for closure prototype subs.
                        $sv->{tool_reachable} = REACH_LEXICAL;
                        push @queue, $sv;
                     }
                     else {
                        # Unnamed slots are just part of the padlist
                        $sv->{tool_reachable} = REACH_INTERNAL;
                        push @internal, $sv;
                     }
                  }
               }

               $_ and push @more, $_ for
                  $cv->scope, $cv->constval, $cv->constants, $cv->globrefs;
            }
            when( "LVALUE" ) {
               my $lv = $sv;

               push @internal, $lv->target if $lv->target;
            }
            when([ "IO", "REGEXP", "FORMAT" ]) { } # ignore

            default { warn "Not sure what to do with user data item ".$sv->desc_addr."\n"; }
         }

         push @queue, grep { $_ and !$_->{tool_reachable} and !$_->immortal } @more;

         push @internal, grep { defined } pairvalues $sv->magic;

         $count++;
         $progress->( sprintf "Marking user reachability %d...", $count ) if $progress and $count % 1000 == 0;
      }
   }

   # Finally internals
   {
      my @queue = ( @internal, pairvalues $df->roots );
      my $count = 0;
      while( @queue ) {
         my $sv = shift @queue or next;
         next if $sv->{tool_reachable};

         $sv->{tool_reachable} = REACH_INTERNAL;

         push @queue, grep { defined } pairvalues $sv->_outrefs;

         $count++;
         $progress->( sprintf "Marking internal reachability %d...", $count ) if $progress and $count % 1000 == 0;
      }
   }
}

=head1 SV METHODS

This tool adds the following SV methods.

=head2 $r = $sv->reachable

Returns true if the SV is reachable from a known root.

=cut

=head1 AUTHOR

Paul Evans <leonerd@leonerd.org.uk>

=cut

0x55AA;
