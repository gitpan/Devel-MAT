use strict;
use warnings;

use Module::Build;

my $build = Module::Build->new(
   module_name => 'Devel::MAT',
   build_requires => {
      'Test::Identity' => 0,
      'Test::More' => '0.88', # done_testing
   },
   requires => {
      'File::ShareDir' => 0,
      'List::Util' => '1.29', # pair* functions
      'List::UtilsBy' => 0,   # sort_by
      'Module::Pluggable' => 0,
      'perl' => '5.010',      # various XS failures on 5.8
   },
   auto_configure_requires => 0, # Don't add M::B to configure_requires
   share_dir => {
      module => { "Devel::MAT::UI" => "share" },
   },
   license => 'perl',
   create_makefile_pl => 'small',
   create_license => 1,
   create_readme  => 1,
);

if( $build->args( "DEBUG" ) ) {
   $build->extra_compiler_flags( @{ $build->extra_compiler_flags }, "-ggdb" );
}

$build->create_build_script;
