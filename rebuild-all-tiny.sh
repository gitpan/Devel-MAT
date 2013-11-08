#!/bin/bash
for PERL in perl5.10.1 perl5.12.4 perl5.14.2 perl5.16.0 perl5.18.1; do
  echo -e "\n*** $PERL ***"

  $PERL Build.PL &&
    $PERL Build clean &&
    $PERL Build &&
    $PERL -Mblib -MDevel::MAT::Dumper -e 'Devel::MAT::Dumper::dump("tiny-$^V.pmat")'
done
