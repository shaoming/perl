#!/usr/bin/perl

use strict;
use Test::More tests => 11;
use Config;
use DynaLoader;
use ExtUtils::CBuilder;

my ($source_file, $obj_file, $lib_file);

require_ok( 'ExtUtils::ParseXS' );
ExtUtils::ParseXS->import('process_file');

chdir 't' or die "Can't chdir to t/, $!";

use Carp; $SIG{__WARN__} = \&Carp::cluck;

#########################

# Try sending to filehandle
tie *FH, 'Foo';
process_file( filename => 'XSTest.xs', output => \*FH, prototypes => 1 );
like tied(*FH)->content, '/is_even/', "Test that output contains some text";

$source_file = 'XSTest.c';

# Try sending to file
process_file(filename => 'XSTest.xs', output => $source_file, prototypes => 0);
ok -e $source_file, "Create an output file";

my $quiet = $ENV{PERL_CORE} && !$ENV{HARNESS_ACTIVE};
my $b = ExtUtils::CBuilder->new(quiet => $quiet);

SKIP: {
  skip "no compiler available", 2
    if ! $b->have_compiler;
  $obj_file = $b->compile( source => $source_file );
  ok $obj_file, "ExtUtils::CBuilder::compile() returned true value";
  ok -e $obj_file, "Make sure $obj_file exists";
}

SKIP: {
  skip "no dynamic loading", 5
    if !$b->have_compiler || !$Config{usedl};
  my $module = 'XSTest';
  $lib_file = $b->link( objects => $obj_file, module_name => $module );
  ok $lib_file, "ExtUtils::CBuilder::link() returned true value";
  ok -e $lib_file,  "Make sure $lib_file exists";

  eval {require XSTest};
  is $@, '', "No error message recorded, as expected";
  ok  XSTest::is_even(8),
    "Function created thru XS returned expected true value";
  ok !XSTest::is_even(9),
    "Function created thru XS returned expected false value";

  # Win32 needs to close the DLL before it can unlink it, but unfortunately
  # dl_unload_file was missing on Win32 prior to perl change #24679!
  if ($^O eq 'MSWin32' and defined &DynaLoader::dl_unload_file) {
    for (my $i = 0; $i < @DynaLoader::dl_modules; $i++) {
      if ($DynaLoader::dl_modules[$i] eq $module) {
        DynaLoader::dl_unload_file($DynaLoader::dl_librefs[$i]);
        last;
      }
    }
  }
}

my $seen = 0;
open my $IN, '<', $source_file
  or die "Unable to open $source_file: $!";
while (my $l = <$IN>) {
  $seen++ if $l =~ m/#line\s1\s/;
}
close $IN or die "Unable to close $source_file: $!";
is( $seen, 1, "Linenumbers created in output file, as intended" ); 

unless ($ENV{PERL_NO_CLEANUP}) {
  for ( $obj_file, $lib_file, $source_file) {
    next unless defined $_;
    1 while unlink $_;
  }
}

#####################################################################

sub Foo::TIEHANDLE { bless {}, 'Foo' }
sub Foo::PRINT { shift->{buf} .= join '', @_ }
sub Foo::content { shift->{buf} }
