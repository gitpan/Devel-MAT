#!/usr/bin/perl

use strict;
use warnings;

use Test::More;
use Test::Identity;

use List::Util qw( pairgrep );

use Devel::MAT::Dumper;
use Devel::MAT;

my $ADDR = qr/0x[0-9a-f]+/;

my $DUMPFILE = "test.pmat";

Devel::MAT::Dumper::dump( $DUMPFILE );
END { unlink $DUMPFILE; }

my $pmat = Devel::MAT->load( $DUMPFILE );
my $df = $pmat->dumpfile;

$pmat->available_tools;
$pmat->load_tool( "Inrefs" );

BEGIN { our @AofA = ( [] ); }
{
   my $av = $pmat->find_symbol( '@AofA' );

   my $rv  = $av->elem(0);
   my $av2 = $rv->rv;

   my @inrefs_direct = $av2->inrefs_direct;
   is( scalar @inrefs_direct, 1, '$av2->inrefs_direct is 1' );
   is( $inrefs_direct[0]->sv,       $rv,             'AV inref[0] SV is $rv' );
   is( $inrefs_direct[0]->strength, "strong",        'AV inref[0] strength is strong' );
   is( $inrefs_direct[0]->name,     "the referrant", 'AV inref[0] name' );

   my @av2_inrefs = $av2->inrefs;
   is( ( grep { $_->name eq "element [0] via RV" } @av2_inrefs )[0]->sv, $av,
      '$av2 is referred to as element[0] via RV of $av' );

   is_deeply( [ map { $_->sv } $av2->inrefs_indirect ], [ $av ],
      '$av2->inrefs_indirect' );
}

{
   my @pvs = grep { $_->desc =~ m/^SCALAR/ and
                    defined $_->pv and
                    $_->pv eq "test.pmat" } $df->heap;

   # There's likely 3 items in this list:
   #   2 constants within the main code
   #   1 value of the $DUMPFILE lexical itself
   my @constants   = grep {
      grep { $_->name eq 'a constant' } $_->inrefs
   } @pvs;

   my ( $lexical ) = grep {
      grep { $_->name eq 'the lexical $DUMPFILE directly' } $_->inrefs
   } @pvs;

   ok( scalar @constants, 'Found some constants' );
   ok( $lexical, 'Found the $DUMPFILE lexical' );
}

BEGIN { our $PACKAGE_SCALAR = "some value" }
{
   my $sv = $pmat->find_symbol( '$PACKAGE_SCALAR' );

   is_deeply( [ map { s/$ADDR/ADDR/g; s/\d+/NNN/g; $_ } $pmat->identify( $sv ) ],
              [ "the scalar of GLOB(\$*) at ADDR, which is:",
                "  a backref indirectly of STASH(NNN) at ADDR, which is:",
                "    the default stash",
                "  element [NNN] directly of ARRAY(NNN,!REAL) at ADDR, which is:",
                "    the backrefs list of STASH(NNN) at ADDR, which is:",
                "      already found",
                "  the egv of GLOB(\$*) at ADDR, which is:",
                "    itself",
                "  value {PACKAGE_SCALAR} directly of STASH(NNN) at ADDR, which is:",
                "    already found" ],
              '$pmat can identify PACKAGE_SCALAR SV' );
}

done_testing;
