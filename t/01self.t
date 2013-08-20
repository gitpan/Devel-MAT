#!/usr/bin/perl

use strict;
use warnings;

use Test::More;

use Devel::MAT::Dumper;
use Devel::MAT::Dumpfile;

my $ADDR = qr/0x[0-9a-f]+/;

my $DUMPFILE = "test.pmat";

Devel::MAT::Dumper::dumpfile( $DUMPFILE );
END { unlink $DUMPFILE; }

my $df = Devel::MAT::Dumpfile->load( $DUMPFILE );

ok( my $defstash = $df->defstash, '$df has default stash' );

BEGIN { our $PACKAGE_SCALAR = "some value" }
{
   ok( my $gv = $defstash->value( "PACKAGE_SCALAR" ), 'default stash has PACKAGE_SCALAR GV' );
   ok( my $sv = $gv->scalar, 'PACKAGE_SCALAR GV has SCALAR' );

   is( $sv->name, '$main::PACKAGE_SCALAR', 'PACKAGE_SCALAR SV has a name' );

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

   is( $av->elem(1)->pv, "B", 'PACKAGE_ARRAY AV has elements' );
}

BEGIN { our %PACKAGE_HASH = ( one => 1, two => 2 ) }
{
   ok( my $gv = $defstash->value( "PACKAGE_HASH" ), 'default stash hash PACKAGE_HASH GV' );
   ok( my $hv = $gv->hash, 'PACKAGE_HASH GV has HASH' );

   is( $hv->name, '%main::PACKAGE_HASH', 'PACKAGE_HASH hv has a name' );

   is( $hv->value("one")->uv, 1, 'PACKAGE_HASH HV has elements' );
}

sub PACKAGE_CODE { my $lexvar = "An unlikely scalar value"; }
{
   ok( my $gv = $defstash->value( "PACKAGE_CODE" ), 'default stash has PACKAGE_CODE' );
   ok( my $cv = $gv->code, 'PACKAGE_CODE GV has CODE' );

   is( $cv->name, '&main::PACKAGE_CODE', 'PACKAGE_CODE CV has a name' );

   is( $cv->padname( 1 ), '$lexvar', 'PACKAGE_CODE CV has padname(1)' );

   is( ( $cv->constants )[0]->pv, "An unlikely scalar value", 'CV constants' );
}

BEGIN { our $LVREF = \substr our $TMPPV = "abc", 1, 2 }
{
   my $sv = $defstash->value( "LVREF" )->scalar;

   ok( my $rv = $sv->rv, 'LVREF SV has RV' );
   is( $rv->type, "x", '$rv->type is x' );
}

done_testing;
