#!/usr/bin/perl

use strict;
use warnings;

use Test::More;
use Test::Identity;

use Scalar::Util qw( weaken );

use Devel::MAT::Dumper;
use Devel::MAT;

my $ADDR = qr/0x[0-9a-f]+/;

my $DUMPFILE = "test.pmat";

Devel::MAT::Dumper::dump( $DUMPFILE );
#END { unlink $DUMPFILE; }

my $pmat = Devel::MAT->load( $DUMPFILE );
my $df = $pmat->dumpfile;

ok( my $defstash = $df->defstash, '$df has default stash' );

BEGIN { our $PACKAGE_SCALAR = "some value" }
{
   ok( my $gv = $defstash->value( "PACKAGE_SCALAR" ), 'default stash has PACKAGE_SCALAR GV' );
   ok( my $sv = $gv->scalar, 'PACKAGE_SCALAR GV has SCALAR' );

   is( $sv->name, '$main::PACKAGE_SCALAR', 'PACKAGE_SCALAR SV has a name' );

   identical( $pmat->find_symbol( '$PACKAGE_SCALAR' ), $sv,
      '$pmat->find_symbol $PACKAGE_SCALAR' );

   identical( $pmat->find_symbol( '$::PACKAGE_SCALAR' ), $sv,
      '$pmat->find_symbol $::PACKAGE_SCALAR' );

   identical( $pmat->find_symbol( '$main::PACKAGE_SCALAR' ), $sv,
      '$pmat->find_symbol $main::PACKAGE_SCALAR' );

   is( $sv->pv, "some value", 'PACKAGE_SCALAR SV has PV' );
}

BEGIN { our @PACKAGE_ARRAY = qw( A B C ) }
{
   ok( my $gv = $defstash->value( "PACKAGE_ARRAY" ), 'default stash hash PACKAGE_ARRAY GV' );
   ok( my $av = $gv->array, 'PACKAGE_ARRAY GV has ARRAY' );

   is( $av->name, '@main::PACKAGE_ARRAY', 'PACKAGE_ARRAY AV has a name' );

   identical( $pmat->find_symbol( '@PACKAGE_ARRAY' ), $av,
      '$pmat->find_symbol @PACKAGE_ARRAY' );

   is( $av->elem(1)->pv, "B", 'PACKAGE_ARRAY AV has elements' );
}

BEGIN { our %PACKAGE_HASH = ( one => 1, two => 2 ) }
{
   ok( my $gv = $defstash->value( "PACKAGE_HASH" ), 'default stash hash PACKAGE_HASH GV' );
   ok( my $hv = $gv->hash, 'PACKAGE_HASH GV has HASH' );

   is( $hv->name, '%main::PACKAGE_HASH', 'PACKAGE_HASH hv has a name' );

   identical( $pmat->find_symbol( '%PACKAGE_HASH' ), $hv,
      '$pmat->find_symbol %PACKAGE_HASH' );

   is( $hv->value("one")->uv, 1, 'PACKAGE_HASH HV has elements' );
}

sub PACKAGE_CODE { my $lexvar = "An unlikely scalar value"; }
{
   ok( my $gv = $defstash->value( "PACKAGE_CODE" ), 'default stash has PACKAGE_CODE' );
   ok( my $cv = $gv->code, 'PACKAGE_CODE GV has CODE' );

   is( $cv->name, '&main::PACKAGE_CODE', 'PACKAGE_CODE CV has a name' );

   identical( $pmat->find_symbol( '&PACKAGE_CODE' ), $cv,
      '$pmat->find_symbol &PACKAGE_CODE' );

   is( $cv->padname( 1 ), '$lexvar', 'PACKAGE_CODE CV has padname(1)' );

   my @constants = $cv->constants;
   ok( @constants, 'CV has constants' );
   is( $constants[0]->pv, "An unlikely scalar value", 'CV constants' );
}

BEGIN { our @AofA = ( [] ); }
{
   my $av = $pmat->find_symbol( '@AofA' );

   ok( my $rv = $av->elem(0), 'AofA AV has elem[0]' );
   ok( my $av2 = $rv->rv, 'RV has rv' );

   my %av_outrefs = $av->outrefs;
   is( $av_outrefs{"element [0] directly"}, $rv, '$rv is element[0] directly of $av' );
   is( $av_outrefs{"element [0] via RV"}, $av2, '$av2 is element [0] via RV of $av' );
}

BEGIN { our $LVREF = \substr our $TMPPV = "abc", 1, 2 }
{
   my $sv = $pmat->find_symbol( '$LVREF' );

   ok( my $rv = $sv->rv, 'LVREF SV has RV' );
   is( $rv->lvtype, "x", '$rv->lvtype is x' );
}

BEGIN { our $strongref = []; weaken( our $weakref = $strongref ) }
{
   my $rv_strong = $pmat->find_symbol( '$strongref' );
   my $rv_weak   = $pmat->find_symbol( '$weakref' );

   identical( $rv_strong->rv, $rv_weak->rv, '$strongref and $weakref have same referrant' );

   ok( !$rv_strong->is_weak, '$strongref is not weak' );
   ok(  $rv_weak->is_weak,   '$weakref is weak'       ); # and longcat is long
}

# Code hidden in a BEGIN block wouldn't be seen
sub make_closure
{
   my $env; sub { $env };
}
BEGIN { our $CLOSURE = make_closure(); }
{
   my $closure = $pmat->find_symbol( '$CLOSURE' )->rv;

   ok( $closure->is_cloned, '$closure is cloned' );

   my $protosub = $closure->protosub;
   ok( defined $protosub, '$closure has a protosub' );

   ok( $protosub->is_clone,  '$protosub is a clone' );
}

BEGIN { our @QUOTING = ( "1\\2", "don't", "do\0this", "at\x9fhome", "LONG"x100 ); }
{
   my $av = $pmat->find_symbol( '@QUOTING' );

   is_deeply( [ map { $_->qq_pv( 20 ) } $av->elems ],
              [ "'1\\\\2'", "'don\\'t'", '"do\\x00this"', '"at\\x9fhome"', "'LONGLONGLONGLONGLONG'..." ],
              '$sv->qq_pv quotes correctly' );
}

done_testing;
