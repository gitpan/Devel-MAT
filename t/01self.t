#!/usr/bin/perl

use strict;
use warnings;

use Test::More;
use Test::Identity;

use List::Util qw( pairgrep );
use Scalar::Util qw( weaken );

use Devel::MAT::Dumper;
use Devel::MAT::Dumpfile;

my $ADDR = qr/0x[0-9a-f]+/;

my $DUMPFILE = "test.pmat";

Devel::MAT::Dumper::dump( $DUMPFILE );
END { unlink $DUMPFILE; }

my $df = Devel::MAT::Dumpfile->load( $DUMPFILE );

ok( my $defstash = $df->defstash, '$df has default stash' );

BEGIN { our $PACKAGE_SCALAR = "some value" }
{
   ok( my $gv = $defstash->value( "PACKAGE_SCALAR" ), 'default stash has PACKAGE_SCALAR GV' );
   ok( my $sv = $gv->scalar, 'PACKAGE_SCALAR GV has SCALAR' );

   is( $sv->name, '$main::PACKAGE_SCALAR', 'PACKAGE_SCALAR SV has a name' );

   identical( $df->find_symbol( '$PACKAGE_SCALAR' ), $sv,
      '$df->find_symbol $PACKAGE_SCALAR' );

   identical( $df->find_symbol( '$::PACKAGE_SCALAR' ), $sv,
      '$df->find_symbol $::PACKAGE_SCALAR' );

   identical( $df->find_symbol( '$main::PACKAGE_SCALAR' ), $sv,
      '$df->find_symbol $main::PACKAGE_SCALAR' );

   is( $sv->pv, "some value", 'PACKAGE_SCALAR SV has PV' );

   is_deeply( [ map { s/$ADDR/ADDR/g; s/\d+/NNN/g; $_ } $df->identify( $sv ) ],
              [ "the scalar of GLOB(\$*) at ADDR, which is:",
                "  element [NNN] directly of ARRAY(NNN) at ADDR, which is:",
                "    the backrefs list of STASH(NNN) at ADDR, which is:",
                "      the default stash",
                "  the egv of GLOB(\$*) at ADDR, which is:",
                "    itself",
                "  value {PACKAGE_SCALAR} directly of STASH(NNN) at ADDR, which is:",
                "    already found" ],
              '$df can identify PACKAGE_SCALAR SV' );
}

BEGIN { our @PACKAGE_ARRAY = qw( A B C ) }
{
   ok( my $gv = $defstash->value( "PACKAGE_ARRAY" ), 'default stash hash PACKAGE_ARRAY GV' );
   ok( my $av = $gv->array, 'PACKAGE_ARRAY GV has ARRAY' );

   is( $av->name, '@main::PACKAGE_ARRAY', 'PACKAGE_ARRAY AV has a name' );

   identical( $df->find_symbol( '@PACKAGE_ARRAY' ), $av,
      '$df->find_symbol @PACKAGE_ARRAY' );

   is( $av->elem(1)->pv, "B", 'PACKAGE_ARRAY AV has elements' );
}

BEGIN { our %PACKAGE_HASH = ( one => 1, two => 2 ) }
{
   ok( my $gv = $defstash->value( "PACKAGE_HASH" ), 'default stash hash PACKAGE_HASH GV' );
   ok( my $hv = $gv->hash, 'PACKAGE_HASH GV has HASH' );

   is( $hv->name, '%main::PACKAGE_HASH', 'PACKAGE_HASH hv has a name' );

   identical( $df->find_symbol( '%PACKAGE_HASH' ), $hv,
      '$df->find_symbol %PACKAGE_HASH' );

   is( $hv->value("one")->uv, 1, 'PACKAGE_HASH HV has elements' );
}

sub PACKAGE_CODE { my $lexvar = "An unlikely scalar value"; }
{
   ok( my $gv = $defstash->value( "PACKAGE_CODE" ), 'default stash has PACKAGE_CODE' );
   ok( my $cv = $gv->code, 'PACKAGE_CODE GV has CODE' );

   is( $cv->name, '&main::PACKAGE_CODE', 'PACKAGE_CODE CV has a name' );

   identical( $df->find_symbol( '&PACKAGE_CODE' ), $cv,
      '$df->find_symbol &PACKAGE_CODE' );

   is( $cv->padname( 1 ), '$lexvar', 'PACKAGE_CODE CV has padname(1)' );

   my @constants = $cv->constants;
   ok( @constants, 'CV has constants' );
   is( $constants[0]->pv, "An unlikely scalar value", 'CV constants' );
}

BEGIN { our @AofA = ( [] ); }
{
   my $av = $df->find_symbol( '@AofA' );

   ok( my $rv = $av->elem(0), 'AofA AV has elem[0]' );
   ok( my $av2 = $rv->rv, 'RV has rv' );

   my %av_outrefs = $av->outrefs;
   is( $av_outrefs{"element [0] directly"}, $rv, '$rv is element[0] directly of $av' );
   is( $av_outrefs{"element [0] via RV"}, $av2, '$av2 is element [0] via RV of $av' );

   my %av2_inrefs = $av2->inrefs;
   is( $av2_inrefs{"the referrant"}, $rv, '$av2 is referred to as the referrant of $rv' );
   is( $av2_inrefs{"element [0] via RV"}, $av, '$av2 is referred to as element[0] via RV of $av' );
}

BEGIN { our $LVREF = \substr our $TMPPV = "abc", 1, 2 }
{
   my $sv = $df->find_symbol( '$LVREF' );

   ok( my $rv = $sv->rv, 'LVREF SV has RV' );
   is( $rv->type, "x", '$rv->type is x' );
}

{
   my @pvs = grep { $_->desc =~ m/^SCALAR/ and
                    defined $_->pv and
                    $_->pv eq "test.pmat" } $df->heap;

   # There's likely 3 items in this list:
   #   2 constants within the main code
   #   1 value of the $DUMPFILE lexical itself
   my @constants   = grep { pairgrep { $a eq 'a constant' }
                                     $_->inrefs } @pvs;

   my ( $lexical ) = grep { pairgrep { $a eq 'the lexical $DUMPFILE directly' }
                                     $_->inrefs } @pvs;

   ok( scalar @constants, 'Found some constants' );
   ok( $lexical, 'Found the $DUMPFILE lexical' );
}

BEGIN { our $strongref = []; weaken( our $weakref = $strongref ) }
{
   my $rv_strong = $df->find_symbol( '$strongref' );
   my $rv_weak   = $df->find_symbol( '$weakref' );

   identical( $rv_strong->rv, $rv_weak->rv, '$strongref and $weakref have same referrant' );

   ok( !$rv_strong->is_weak, '$strongref is not weak' );
   ok(  $rv_weak->is_weak,   '$weakref is weak'       ); # and longcat is long
}

done_testing;
