
BEGIN {
    unless ("A" eq pack('U', 0x41)) {
	print "1..0 # Unicode::Collate " .
	    "cannot stringify a Unicode code point\n";
	exit 0;
    }
    if ($ENV{PERL_CORE}) {
	chdir('t') if -d 't';
	@INC = $^O eq 'MacOS' ? qw(::lib) : qw(../lib);
    }
}

use Test;
BEGIN { plan tests => 23 };

use strict;
use warnings;
use Unicode::Collate::Locale;

ok(1);

#########################

my $objLn = Unicode::Collate::Locale->
    new(locale => 'LN', normalization => undef);

ok($objLn->getlocale, 'ln');

$objLn->change(level => 1);

ok($objLn->gt("\x{25B}", "E"));
ok($objLn->lt("\x{25B}", "F"));

ok($objLn->eq("\x{254}", "O"));

# 5

$objLn->change(level => 2);

ok($objLn->gt("\x{254}", "O"));

ok($objLn->eq("\x{25B}", "\x{190}"));
ok($objLn->eq("\x{254}", "\x{186}"));

ok($objLn->eq("\x{25B}", "\x{2107}"));
ok($objLn->eq("\x{25B}", "\x{1D4B}"));
ok($objLn->eq("\x{254}", "\x{1D53}"));

# 11

$objLn->change(level => 3);

ok($objLn->lt("\x{25B}", "\x{190}"));
ok($objLn->lt("\x{25B}", "\x{2107}"));
ok($objLn->lt("\x{254}", "\x{186}"));

$objLn->change(upper_before_lower => 1);

ok($objLn->gt("\x{25B}", "\x{190}"));
ok($objLn->gt("\x{25B}", "\x{2107}"));
ok($objLn->gt("\x{254}", "\x{186}"));

for my $up_lo (0, 1) {
  $objLn->change(upper_before_lower => $up_lo);
  ok($objLn->lt("\x{190}", "\x{2107}"));
  ok($objLn->lt("\x{25B}", "\x{1D4B}"));
  ok($objLn->lt("\x{254}", "\x{1D53}"));
}

# 23
