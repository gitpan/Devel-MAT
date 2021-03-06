#!/usr/bin/perl

use strict;
use warnings;

use Test::More;

use Devel::MAT::Dumper;
use Devel::MAT;

my $DUMPFILE = "test.pmat";

my $inner_l0 = __LINE__+1;
sub inner {
   Devel::MAT::Dumper::dump( $DUMPFILE )            # l0 + 1
}

my $outer_l0 = __LINE__+1;
sub outer {
   eval {                                           # l0 + 1
      inner( "C", "D" )                             # l0 + 2
   };
}

my $anon_l0 = __LINE__+1;
my $cv = sub {
   map { eval 'outer( "A", "B" );'; } "one";        # l0 + 1
};
$cv->();                                            # l0 + 3

END { unlink $DUMPFILE; }

my $pmat = Devel::MAT->load( $DUMPFILE );
my $df = $pmat->dumpfile;

my @ctxts = $df->contexts;
ok( scalar @ctxts, 'Found some call contexts' );

my ( $cinner, $ctry, $couter, $ceval, $canon ) = @ctxts;

{
   is( $cinner->type, "SUB", '$cinner type' );
   is( $cinner->file, __FILE__, '$cinner file' );
   is( $cinner->line, $outer_l0 + 2, '$cinner line' );
   is( $cinner->cv->name, '&main::inner', '$cinner CV name' );
   is_deeply( [ map { $_->pv } $cinner->args->elems ],
              [qw( C D )],
              '$cinner args' );
}

{
   is( $ctry->type, "TRY", '$ctry type' );
   is( $ctry->file, __FILE__, '$ctry file' );
   is( $ctry->line, $outer_l0 + 1, '$ctry line' );
}

{
   is( $couter->type, "SUB", '$couter type' );
   like( $couter->file, qr/^\(eval \d+\)/, '$couter file' );
   is( $couter->line, 1, '$couter line' );
   is( $couter->cv->name, '&main::outer', '$couter CV name' );
   is_deeply( [ map { $_->pv } $couter->args->elems ],
              [qw( A B )],
              '$couter args' );
}

{
   is( $ceval->type, "EVAL", '$ceval type' );
   is( $ceval->file, __FILE__, '$ceval file' );
   is( $ceval->line, $anon_l0 + 1, '$ceval line' );
   like( $ceval->code->pv, qr/^outer\( "A", "B" \);/, '$ceval code PV' );
}

{
   is( $canon->type, "SUB", '$canon type' );
   is( $canon->file, __FILE__, '$canon file' );
   is( $canon->line, $anon_l0 + 3, '$canon line' );
   is( $canon->cv->name, "&main::__ANON__", '$canon CV name' );
}

done_testing;
