#!./perl -w

# Verify that all files generated by perl scripts are up to date.

my ($in_t, $lib);

BEGIN {
    $in_t = -f 'TEST' && -f '../regen.pl';
    $lib = $in_t ? '../lib' : 'lib';
    unshift @INC, $lib;
}

use strict;

use File::Spec::Functions 'rel2abs';
$^X = rel2abs($^X);
$ENV{PERL5LIB} = rel2abs($lib);

chdir '..' if $in_t;

print "1..17\n"; # I can't see a clean way to calculate this automatically.

system "$^X regen.pl --tap";