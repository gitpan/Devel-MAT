#!/usr/bin/perl

use strict;
use warnings;

use Test::More;

use Devel::MAT::Dumper;
use Devel::MAT;

use Config;

my $DUMPFILE = "test.pmat";

Devel::MAT::Dumper::dump( $DUMPFILE );
END { unlink $DUMPFILE; }

my $pmat = Devel::MAT->load( $DUMPFILE );
my $df = $pmat->dumpfile;

$pmat->available_tools;
$pmat->load_tool( "Inrefs" );

# Count the orphans
my $count = 0;
foreach my $sv ( $df->heap ) {
   $count++ unless $sv->inrefs;
}

# threaded and non-threaded perls differ a lot
my $perlver = $^V . ( $Config{usethreads} ? "-thread" : "" );

my %expect = (
   'v5.10.0'        => 1648,
   'v5.10.1'        => 175,
   'v5.12.4'        => 347,
   'v5.14.2'        => 234,
   'v5.14.4-thread' => 44,
   'v5.16.0'        => 538,
   'v5.18.0'        => 524,
   'v5.18.1-thread' => 276,
);

if( defined( my $expect = $expect{$perlver} ) ) {
   cmp_ok( $count, "<=", $expect, 'No more orphans than expected' );
   diag "Found only $count orphans, was expecting $expect on perl $perlver" if $count < $expect;
}
else {
   SKIP: { skip 'Not sure how many orphans to expect', 1; }
   diag "Found $count orphans on perl $perlver";
}

done_testing;
