#!/usr/bin/perl -w
use strict;

use Getopt::Long qw(:config bundling no_auto_abbrev);
use Pod::Usage;
use Config;
use Carp;

my @targets
    = qw(config.sh config.h miniperl lib/Config.pm Fcntl perl test_prep);

my $cpus;
if (open my $fh, '<', '/proc/cpuinfo') {
    while (<$fh>) {
        ++$cpus if /^processor\s+:\s+\d+$/;
    }
} elsif (-x '/sbin/sysctl') {
    $cpus = 1 + $1 if `/sbin/sysctl hw.ncpu` =~ /^hw\.ncpu: (\d+)$/;
} elsif (-x '/usr/bin/getconf') {
    $cpus = 1 + $1 if `/usr/bin/getconf _NPROCESSORS_ONLN` =~ /^(\d+)$/;
}

my %options =
    (
     jobs => defined $cpus ? $cpus + 1 : 2,
     'expect-pass' => 1,
     clean => 1, # mostly for debugging this
    );

my $linux64 = `uname -sm` eq "Linux x86_64\n" ? '64' : '';

my @paths;

if ($^O eq 'linux') {
    # This is the search logic for a multi-arch library layout
    # added to linux.sh in commits 40f026236b9959b7 and dcffd848632af2c7.
    my $gcc = -x '/usr/bin/gcc' ? '/usr/bin/gcc' : 'gcc';

    foreach (`$gcc -print-search-dirs`) {
        next unless /^libraries: =(.*)/;
        foreach (split ':', $1) {
            next if m/gcc/;
            next unless -d $_;
            s!/$!!;
            push @paths, $_;
        }
    }
}

push @paths, map {$_ . $linux64} qw(/usr/local/lib /lib /usr/lib);

my %defines =
    (
     usedevel => '',
     optimize => '-g',
     cc => 'ccache cc',
     ld => 'cc',
     ($linux64 ? (libpth => \@paths) : ()),
    );

unless(GetOptions(\%options,
                  'target=s', 'jobs|j=i', 'expect-pass=i',
                  'expect-fail' => sub { $options{'expect-pass'} = 0; },
                  'clean!', 'one-liner|e=s', 'match=s', 'force-manifest',
                  'force-regen', 'test-build', 'check-args', 'A=s@', 'l', 'w',
                  'usage|help|?',
                  'D=s@' => sub {
                      my (undef, $val) = @_;
                      if ($val =~ /\A([^=]+)=(.*)/s) {
                          $defines{$1} = length $2 ? $2 : "\0";
                      } else {
                          $defines{$val} = '';
                      }
                  },
                  'U=s@' => sub {
                      $defines{$_[1]} = undef;
                  },
		 )) {
    pod2usage(exitval => 255, verbose => 1);
}

my ($target, $j, $match) = @options{qw(target jobs match)};

pod2usage(exitval => 255, verbose => 1) if $options{usage};
pod2usage(exitval => 255, verbose => 1)
    unless @ARGV || $match || $options{'test-build'} || defined $options{'one-liner'};
pod2usage(exitval => 255, verbose => 1)
    if !$options{'one-liner'} && ($options{l} || $options{w});

exit 0 if $options{'check-args'};

=head1 NAME

bisect.pl - use git bisect to pinpoint changes

=head1 SYNOPSIS

    # When did this become an error?
    .../Porting/bisect.pl -e 'my $a := 2;'
    # When did this stop being an error?
    .../Porting/bisect.pl --expect-fail -e '1 // 2'
    # When did this stop matching?
    .../Porting/bisect.pl --match '\b(?:PL_)hash_seed_set\b'
    # When did this start matching?
    .../Porting/bisect.pl --expect-fail --match '\buseithreads\b'
    # When did this test program stop working?
    .../Porting/bisect.pl -- ./perl -Ilib ../test_prog.pl
    # When did this first become valid syntax?
    .../Porting/bisect.pl --target=miniperl --end=v5.10.0 \
         --expect-fail -e 'my $a := 2;'
    # What was the last revision to build with these options?
    .../Porting/bisect.pl --test-build -Dd_dosuid

=head1 DESCRIPTION

Together F<bisect.pl> and F<bisect-runner.pl> attempt to automate the use
of C<git bisect> as much as possible. With one command (and no other files)
it's easy to find out

=over 4

=item *

Which commit caused this example code to break?

=item *

Which commit caused this example code to start working?

=item *

Which commit added the first to match this regex?

=item *

Which commit removed the last to match this regex?

=back

usually without needing to know which versions of perl to use as start and
end revisions.

By default F<bisect.pl> will process all options, then use the rest of the
command line as arguments to list C<system> to run a test case. By default,
the test case should pass (exit with 0) on earlier perls, and fail (exit
non-zero) on I<blead>. F<bisect.pl> will use F<bisect-runner.pl> to find the
earliest stable perl version on which the test case passes, check that it
fails on blead, and then use F<bisect-runner.pl> with C<git bisect run> to
find the commit which caused the failure.

Because the test case is the complete argument to C<system>, it is easy to
run something other than the F<perl> built, if necessary. If you need to run
the perl built, you'll probably need to invoke it as C<./perl -Ilib ...>

You need a clean checkout to run a bisect, and you can't use the checkout
which contains F<Porting/bisect.pl> (because C<git bisect>) will check out
a revision before F<Porting/bisect-runner.pl> was added, which
C<git bisect run> needs). If your working checkout is called F<perl>, the
simplest solution is to make a local clone, and run from that. I<i.e.>:

    cd ..
    git clone perl perl2
    cd perl2
    ../perl/Porting/bisect.pl ...

By default, F<bisect-runner.pl> will automatically disable the build of
L<DB_File> for commits earlier than ccb44e3bf3be2c30, as it's not practical
to patch DB_File 1.70 and earlier to build with current Berkeley DB headers.
(ccb44e3bf3be2c30 was in September 1999, between 5.005_62 and 5.005_63.)
If your F<db.h> is old enough you can override this with C<-Unoextensions>.

=head1 OPTIONS

=over 4

=item *

--start I<commit-ish>

Earliest revision to test, as a I<commit-ish> (a tag, commit or anything
else C<git> understands as a revision). If not specified, F<bisect.pl> will
search stable perl releases from 5.002 to 5.14.0 until it finds one where
the test case passes.

=item *

--end I<commit-ish>

Most recent revision to test, as a I<commit-ish>. If not specified, defaults
to I<blead>.

=item *

--target I<target>

F<Makefile> target (or equivalent) needed, to run the test case. If specified,
this should be one of

=over 4

=item *

I<config.sh>

Just run F<./Configure>

=item *

I<config.h>

Run the various F<*.SH> files to generate F<Makefile>, F<config.h>, I<etc>.

=item *

I<miniperl>

Build F<miniperl>.

=item *

I<lib/Config.pm>

Use F<miniperl> to build F<lib/Config.pm>

=item *

I<Fcntl>

Build F<lib/auto/Fcntl/Fnctl.so> (strictly, C<.$Config{so}>). As L<Fcntl>
is simple XS module present since 5.000, this provides a fast test of
whether XS modules can be built. Note, XS modules are built by F<miniperl>,
hence this target will not build F<perl>.

=item *

I<perl>

Build F<perl>. This also builds pure-Perl modules in F<cpan>, F<dist> and
F<ext>. XS modules (such as L<Fcntl>) are not built.

=item *

I<test_prep>

Build everything needed to run the tests. This is the default if we're
running test code, but is time consuming, as it means building all
XS modules. For older F<Makefile>s, the previous name of C<test-prep>
is automatically substituted. For very old F<Makefile>s, C<make test> is
run, as there is no target provided to just get things ready, and for 5.004
and earlier the tests run very quickly.

=back

=item *

--one-liner 'code to run'

=item *

-e 'code to run'

Example code to run, just like you'd use with C<perl -e>.

This prepends C<./perl -Ilib -e 'code to run'> to the test case given,
or F<./miniperl> if I<target> is C<miniperl>.

(Usually you'll use C<-e> instead of providing a test case in the
non-option arguments to F<bisect.pl>)

C<-E> intentionally isn't supported, as it's an error in 5.8.0 and earlier,
which interferes with detecting errors in the example code itself.

=item *

-l

Add C<-l> to the command line with C<-e>

This will automatically append a newline to every output line of your testcase.
Note that you can't specify an argument to F<perl>'s C<-l> with this, as it's
not feasible to emulate F<perl>'s somewhat quirky switch parsing with
L<Getopt::Long>. If you need the full flexibility of C<-l>, you need to write
a full test case, instead of using C<bisect.pl>'s C<-e> shortcut.

=item *

-w

Add C<-w> to the command line with C<-e>

It's not valid to pass C<-l> or C<-w> to C<bisect.pl> unless you are also
using C<-e>

=item *

--expect-fail

The test case should fail for the I<start> revision, and pass for the I<end>
revision. The bisect run will find the first commit where it passes.

=item *

-Dnoextensions=Encode

=item *

-Uusedevel

=item *

-Accflags=-DNO_MATHOMS

Arguments to pass to F<Configure>. Repeated C<-A> arguments are passed
through as is. C<-D> and C<-U> are processed in order, and override
previous settings for the same parameter. F<bisect-runner.pl> emulates
C<-Dnoextensions> when F<Configure> itself does not provide it, as it's
often very useful to be able to disable some XS extensions.

=item *

--jobs I<jobs>

=item *

-j I<jobs>

Number of C<make> jobs to run in parallel. If F</proc/cpuinfo> exists and
can be parsed, or F</sbin/sysctl> exists and reports C<hw.ncpu>, or
F</usr/bin/getconf> exists and reports C<_NPROCESSORS_ONLN> defaults to 1 +
I<number of CPUs>. Otherwise defaults to 2.

=item *

--match pattern

Instead of running a test program to determine I<pass> or I<fail>, pass
if the given regex matches, and hence search for the commit that removes
the last matching file.

If no I<target> is specified, the match is against all files in the
repository (which is fast). If a I<target> is specified, that target is
built, and the match is against only the built files. C<--expect-fail> can
be used with C<--match> to search for a commit that adds files that match.

=item *

--test-build

Test that the build completes, without running any test case.

By default, if the build for the desired I<target> fails to complete,
F<bisect-runner.pl> reports a I<skip> back to C<git bisect>, the assumption
being that one wants to find a commit which changed state "builds && passes"
to "builds && fails". If instead one is interested in which commit broke the
build (possibly for particular F<Configure> options), use I<--test-build>
to treat a build failure as a failure, not a "skip".

Often this option isn't as useful as it first seems, because I<any> build
failure will be reported to C<git bisect> as a failure, not just the failure
that you're interested in. Generally, to debug a particular problem, it's
more useful to use a I<target> that builds properly at the point of interest,
and then a test case that runs C<make>. For example:

    .../Porting/bisect.pl --start=perl-5.000 --end=perl-5.002 \
        --expect-fail --force-manifest --target=miniperl make perl

will find the first revision capable of building L<DynaLoader> and then
F<perl>, without becoming confused by revisions where F<miniperl> won't
even link.

=item *

--force-manifest

By default, a build will "skip" if any files listed in F<MANIFEST> are not
present. Usually this is useful, as it avoids false-failures. However, there
are some long ranges of commits where listed files are missing, which can
cause a bisect to abort because all that remain are skipped revisions.

In these cases, particularly if the test case uses F<miniperl> and no modules,
it may be more useful to force the build to continue, even if files
F<MANIFEST> are missing.

=item *

--force-regen

Run C<make regen_headers> before building F<miniperl>. This may fix a build
that otherwise would skip because the generated headers at that revision
are stale. It's not the default because it conceals this error in the true
state of such revisions.

=item *

--expect-pass [0|1]

C<--expect-pass=0> is equivalent to C<--expect-fail>. I<1> is the default.

=item *

--no-clean

Tell F<bisect-runner.pl> not to clean up after the build. This allows one
to use F<bisect-runner.pl> to build the current particular perl revision for
interactive testing, or for debugging F<bisect-runner.pl>.

Passing this to F<bisect.pl> will likely cause the bisect to fail badly.

=item *

--validate

Test that all stable revisions can be built. By default, attempts to build
I<blead>, I<v5.14.0> .. I<perl-5.002>. Stops at the first failure, without
cleaning the checkout. Use I<--start> to specify the earliest revision to
test, I<--end> to specify the most recent. Useful for validating a new
OS/CPU/compiler combination. For example

    ../perl/Porting/bisect.pl --validate -le 'print "Hello from $]"'

If no testcase is specified, the default is to use F<t/TEST> to run
F<t/base/*.t>

=item *

--check-args

Validate the options and arguments, and exit silently if they are valid.

=item *

--usage

=item *

--help

=item *

-?

Display the usage information and exit.

=back

=cut

die "$0: Can't build $target" if defined $target && !grep {@targets} $target;

$j = "-j$j" if $j =~ /\A\d+\z/;

# Sadly, however hard we try, I don't think that it will be possible to build
# modules in ext/ on x86_64 Linux before commit e1666bf5602ae794 on 1999/12/29,
# which updated to MakeMaker 3.7, which changed from using a hard coded ld
# in the Makefile to $(LD). On x86_64 Linux the "linker" is gcc.

sub open_or_die {
    my $file = shift;
    my $mode = @_ ? shift : '<';
    open my $fh, $mode, $file or croak("Can't open $file: $!");
    ${*$fh{SCALAR}} = $file;
    return $fh;
}

sub close_or_die {
    my $fh = shift;
    return if close $fh;
    croak("Can't close: $!") unless ref $fh eq 'GLOB';
    croak("Can't close ${*$fh{SCALAR}}: $!");
}

sub extract_from_file {
    my ($file, $rx, $default) = @_;
    my $fh = open_or_die($file);
    while (<$fh>) {
	my @got = $_ =~ $rx;
	return wantarray ? @got : $got[0]
	    if @got;
    }
    return $default if defined $default;
    return;
}

sub edit_file {
    my ($file, $munger) = @_;
    local $/;
    my $fh = open_or_die($file);
    my $orig = <$fh>;
    die "Can't read $file: $!" unless defined $orig && close $fh;
    my $new = $munger->($orig);
    return if $new eq $orig;
    $fh = open_or_die($file, '>');
    print $fh $new or die "Can't print to $file: $!";
    close_or_die($fh);
}

sub apply_patch {
    my $patch = shift;

    my ($file) = $patch =~ qr!^--- a/(\S+)\n\+\+\+ b/\1!sm;
    open my $fh, '|-', 'patch', '-p1' or die "Can't run patch: $!";
    print $fh $patch;
    return if close $fh;
    print STDERR "Patch is <<'EOPATCH'\n${patch}EOPATCH\n";
    die "Can't patch $file: $?, $!";
}

sub apply_commit {
    my ($commit, @files) = @_;
    return unless system "git show $commit @files | patch -p1";
    die "Can't apply commit $commit to @files" if @files;
    die "Can't apply commit $commit";
}

sub revert_commit {
    my ($commit, @files) = @_;
    return unless system "git show -R $commit @files | patch -p1";
    die "Can't apply revert $commit from @files" if @files;
    die "Can't apply revert $commit";
}

sub checkout_file {
    my ($file, $commit) = @_;
    $commit ||= 'blead';
    system "git show $commit:$file > $file </dev/null"
        and die "Could not extract $file at revision $commit";
}

sub clean {
    if ($options{clean}) {
        # Needed, because files that are build products in this checked out
        # version might be in git in the next desired version.
        system 'git clean -dxf </dev/null';
        # Needed, because at some revisions the build alters checked out files.
        # (eg pod/perlapi.pod). Also undoes any changes to makedepend.SH
        system 'git reset --hard HEAD </dev/null';
    }
}

sub skip {
    my $reason = shift;
    clean();
    warn "skipping - $reason";
    exit 125;
}

sub report_and_exit {
    my ($ret, $pass, $fail, $desc) = @_;

    clean();

    my $got = ($options{'expect-pass'} ? !$ret : $ret) ? 'good' : 'bad';
    if ($ret) {
        print "$got - $fail $desc\n";
    } else {
        print "$got - $pass $desc\n";
    }

    exit($got eq 'bad');
}

sub match_and_exit {
    my $target = shift;
    my $matches = 0;
    my $re = qr/$match/;
    my @files;

    {
        local $/ = "\0";
        @files = defined $target ? `git ls-files -o -z`: `git ls-files -z`;
        chomp @files;
    }

    foreach my $file (@files) {
        my $fh = open_or_die($file);
        while (<$fh>) {
            if ($_ =~ $re) {
                ++$matches;
                if (tr/\t\r\n -~\200-\377//c) {
                    print "Binary file $file matches\n";
                } else {
                    $_ .= "\n" unless /\n\z/;
                    print "$file: $_";
                }
            }
        }
        close_or_die($fh);
    }
    report_and_exit(!$matches,
                    $matches == 1 ? '1 match for' : "$matches matches for",
                    'no matches for', $match);
}

# Not going to assume that system perl is yet new enough to have autodie
system 'git clean -dxf </dev/null' and die;

if (!defined $target) {
    match_and_exit() if $match;
    $target = 'test_prep';
}

skip('no Configure - is this the //depot/perlext/Compiler branch?')
    unless -f 'Configure';

# This changes to PERL_VERSION in 4d8076ea25903dcb in 1999
my $major
    = extract_from_file('patchlevel.h',
			qr/^#define\s+(?:PERL_VERSION|PATCHLEVEL)\s+(\d+)\s/,
			0);

patch_Configure();
patch_hints();

# if Encode is not needed for the test, you can speed up the bisect by
# excluding it from the runs with -Dnoextensions=Encode
# ccache is an easy win. Remove it if it causes problems.
# Commit 1cfa4ec74d4933da adds ignore_versioned_solibs to Configure, and sets it
# to true in hints/linux.sh
# On dromedary, from that point on, Configure (by default) fails to find any
# libraries, because it scans /usr/local/lib /lib /usr/lib, which only contain
# versioned libraries. Without -lm, the build fails.
# Telling /usr/local/lib64 /lib64 /usr/lib64 works from that commit onwards,
# until commit faae14e6e968e1c0 adds it to the hints.
# However, prior to 1cfa4ec74d4933da telling Configure the truth doesn't work,
# because it will spot versioned libraries, pass them to the compiler, and then
# bail out pretty early on. Configure won't let us override libswanted, but it
# will let us override the entire libs list.

unless (extract_from_file('Configure', 'ignore_versioned_solibs')) {
    # Before 1cfa4ec74d4933da, so force the libs list.

    my @libs;
    # This is the current libswanted list from Configure, less the libs removed
    # by current hints/linux.sh
    foreach my $lib (qw(sfio socket inet nsl nm ndbm gdbm dbm db malloc dl dld
			ld sun m crypt sec util c cposix posix ucb BSD)) {
	foreach my $dir (@paths) {
	    next unless -f "$dir/lib$lib.so";
	    push @libs, "-l$lib";
	    last;
	}
    }
    $defines{libs} = \@libs unless exists $defines{libs};
}

$defines{usenm} = undef
    if $major < 2 && !exists $defines{usenm};

my ($missing, $created_dirs);
($missing, $created_dirs) = force_manifest()
    if $options{'force-manifest'};

my @ARGS = '-dEs';
foreach my $key (sort keys %defines) {
    my $val = $defines{$key};
    if (ref $val) {
        push @ARGS, "-D$key=@$val";
    } elsif (!defined $val) {
        push @ARGS, "-U$key";
    } elsif (!length $val) {
        push @ARGS, "-D$key";
    } else {
        $val = "" if $val eq "\0";
        push @ARGS, "-D$key=$val";
    }
}
push @ARGS, map {"-A$_"} @{$options{A}};

# </dev/null because it seems that some earlier versions of Configure can
# call commands in a way that now has them reading from stdin (and hanging)
my $pid = fork;
die "Can't fork: $!" unless defined $pid;
if (!$pid) {
    open STDIN, '<', '/dev/null';
    # If a file in MANIFEST is missing, Configure asks if you want to
    # continue (the default being 'n'). With stdin closed or /dev/null,
    # it exits immediately and the check for config.sh below will skip.
    exec './Configure', @ARGS;
    die "Failed to start Configure: $!";
}
waitpid $pid, 0
    or die "wait for Configure, pid $pid failed: $!";

patch_SH();

if (-f 'config.sh') {
    # Emulate noextensions if Configure doesn't support it.
    fake_noextensions()
        if $major < 10 && $defines{noextensions};
    system './Configure -S </dev/null' and die;
}

if ($target =~ /config\.s?h/) {
    match_and_exit($target) if $match && -f $target;
    report_and_exit(!-f $target, 'could build', 'could not build', $target)
        if $options{'test-build'};

    my $ret = system @ARGV;
    report_and_exit($ret, 'zero exit from', 'non-zero exit from', "@ARGV");
} elsif (!-f 'config.sh') {
    # Skip if something went wrong with Configure

    skip('could not build config.sh');
}

force_manifest_cleanup($missing, $created_dirs)
        if $missing;

if($options{'force-regen'}
   && extract_from_file('Makefile', qr/\bregen_headers\b/)) {
    # regen_headers was added in e50aee73b3d4c555, patch.1m for perl5.001
    # It's not worth faking it for earlier revisions.
    system "make regen_headers </dev/null"
        and die;
}

patch_C();
patch_ext();

# Parallel build for miniperl is safe
system "make $j miniperl </dev/null";

my $expected = $target =~ /^test/ ? 't/perl'
    : $target eq 'Fcntl' ? "lib/auto/Fcntl/Fcntl.$Config{so}"
    : $target;
my $real_target = $target eq 'Fcntl' ? $expected : $target;

if ($target ne 'miniperl') {
    # Nearly all parallel build issues fixed by 5.10.0. Untrustworthy before that.
    $j = '' if $major < 10;

    if ($real_target eq 'test_prep') {
        if ($major < 8) {
            # test-prep was added in 5.004_01, 3e3baf6d63945cb6.
            # renamed to test_prep in 2001 in 5fe84fd29acaf55c.
            # earlier than that, just make test. It will be fast enough.
            $real_target = extract_from_file('Makefile.SH',
                                             qr/^(test[-_]prep):/,
                                             'test');
        }
    }

    system "make $j $real_target </dev/null";
}

my $missing_target = $expected =~ /perl$/ ? !-x $expected : !-r $expected;

if ($options{'test-build'}) {
    report_and_exit($missing_target, 'could build', 'could not build',
                    $real_target);
} elsif ($missing_target) {
    skip("could not build $real_target");
}

match_and_exit($real_target) if $match;

if (defined $options{'one-liner'}) {
    my $exe = $target =~ /^(?:perl$|test)/ ? 'perl' : 'miniperl';
    unshift @ARGV, '-e', $options{'one-liner'};
    unshift @ARGV, '-l' if $options{l};
    unshift @ARGV, '-w' if $options{w};
    unshift @ARGV, "./$exe", '-Ilib';
}

# This is what we came here to run:

if (exists $Config{ldlibpthname}) {
    require Cwd;
    my $varname = $Config{ldlibpthname};
    my $cwd = Cwd::getcwd();
    if (defined $ENV{$varname}) {
        $ENV{$varname} = $cwd . $Config{path_sep} . $ENV{$varname};
    } else {
        $ENV{$varname} = $cwd;
    }
}

my $ret = system @ARGV;

report_and_exit($ret, 'zero exit from', 'non-zero exit from', "@ARGV");

############################################################################
#
# Patching, editing and faking routines only below here.
#
############################################################################

sub fake_noextensions {
    edit_file('config.sh', sub {
                  my @lines = split /\n/, shift;
                  my @ext = split /\s+/, $defines{noextensions};
                  foreach (@lines) {
                      next unless /^extensions=/ || /^dynamic_ext/;
                      foreach my $ext (@ext) {
                          s/\b$ext( )?\b/$1/;
                      }
                  }
                  return join "\n", @lines;
              });
}

sub force_manifest {
    my (@missing, @created_dirs);
    my $fh = open_or_die('MANIFEST');
    while (<$fh>) {
        next unless /^(\S+)/;
        # -d is special case needed (at least) between 27332437a2ed1941 and
        # bf3d9ec563d25054^ inclusive, as manifest contains ext/Thread/Thread
        push @missing, $1
            unless -f $1 || -d $1;
    }
    close_or_die($fh);

    foreach my $pathname (@missing) {
        my @parts = split '/', $pathname;
        my $leaf = pop @parts;
        my $path = '.';
        while (@parts) {
            $path .= '/' . shift @parts;
            next if -d $path;
            mkdir $path, 0700 or die "Can't create $path: $!";
            unshift @created_dirs, $path;
        }
        $fh = open_or_die($pathname, '>');
        close_or_die($fh);
        chmod 0, $pathname or die "Can't chmod 0 $pathname: $!";
    }
    return \@missing, \@created_dirs;
}

sub force_manifest_cleanup {
    my ($missing, $created_dirs) = @_;
    # This is probably way too paranoid:
    my @errors;
    require Fcntl;
    foreach my $file (@$missing) {
        my (undef, undef, $mode, undef, undef, undef, undef, $size)
            = stat $file;
        if (!defined $mode) {
            push @errors, "Added file $file has been deleted by Configure";
            next;
        }
        if (Fcntl::S_IMODE($mode) != 0) {
            push @errors,
                sprintf 'Added file %s had mode changed by Configure to %03o',
                    $file, $mode;
        }
        if ($size != 0) {
            push @errors,
                "Added file $file had sized changed by Configure to $size";
        }
        unlink $file or die "Can't unlink $file: $!";
    }
    foreach my $dir (@$created_dirs) {
        rmdir $dir or die "Can't rmdir $dir: $!";
    }
    skip("@errors")
        if @errors;
}

sub patch_Configure {
    if ($major < 1) {
        if (extract_from_file('Configure',
                              qr/^\t\t\*=\*\) echo "\$1" >> \$optdef;;$/)) {
            # This is "        Spaces now allowed in -D command line options.",
            # part of commit ecfc54246c2a6f42
            apply_patch(<<'EOPATCH');
diff --git a/Configure b/Configure
index 3d3b38d..78ffe16 100755
--- a/Configure
+++ b/Configure
@@ -652,7 +777,8 @@ while test $# -gt 0; do
 			echo "$me: use '-U symbol=', not '-D symbol='." >&2
 			echo "$me: ignoring -D $1" >&2
 			;;
-		*=*) echo "$1" >> $optdef;;
+		*=*) echo "$1" | \
+				sed -e "s/'/'\"'\"'/g" -e "s/=\(.*\)/='\1'/" >> $optdef;;
 		*) echo "$1='define'" >> $optdef;;
 		esac
 		shift
EOPATCH
        }

        if (extract_from_file('Configure', qr/^if \$contains 'd_namlen' \$xinc\b/)) {
            # Configure's original simple "grep" for d_namlen falls foul of the
            # approach taken by the glibc headers:
            # #ifdef _DIRENT_HAVE_D_NAMLEN
            # # define _D_EXACT_NAMLEN(d) ((d)->d_namlen)
            #
            # where _DIRENT_HAVE_D_NAMLEN is not defined on Linux.
            # This is also part of commit ecfc54246c2a6f42
            apply_patch(<<'EOPATCH');
diff --git a/Configure b/Configure
index 3d3b38d..78ffe16 100755
--- a/Configure
+++ b/Configure
@@ -3935,7 +4045,8 @@ $rm -f try.c
 
 : see if the directory entry stores field length
 echo " "
-if $contains 'd_namlen' $xinc >/dev/null 2>&1; then
+$cppstdin $cppflags $cppminus < "$xinc" > try.c
+if $contains 'd_namlen' try.c >/dev/null 2>&1; then
 	echo "Good, your directory entry keeps length information in d_namlen." >&4
 	val="$define"
 else
EOPATCH
        }
    }

    if ($major < 2
        && !extract_from_file('Configure',
                              qr/Try to guess additional flags to pick up local libraries/)) {
        my $mips = extract_from_file('Configure',
                                     qr!(''\) if (?:\./)?mips; then)!);
        # This is part of perl-5.001n. It's needed, to add -L/usr/local/lib to
        # theld flags if libraries are found there. It shifts the code to set up
        # libpth earlier, and then adds the code to add libpth entries to
        # ldflags
        # mips was changed to ./mips in ecfc54246c2a6f42, perl5.000 patch.0g
        apply_patch(sprintf <<'EOPATCH', $mips);
diff --git a/Configure b/Configure
index 53649d5..0635a6e 100755
--- a/Configure
+++ b/Configure
@@ -2749,6 +2749,52 @@ EOM
 	;;
 esac
 
+: Set private lib path
+case "$plibpth" in
+'') if ./mips; then
+		plibpth="$incpath/usr/lib /usr/local/lib /usr/ccs/lib"
+	fi;;
+esac
+case "$libpth" in
+' ') dlist='';;
+'') dlist="$plibpth $glibpth";;
+*) dlist="$libpth";;
+esac
+
+: Now check and see which directories actually exist, avoiding duplicates
+libpth=''
+for xxx in $dlist
+do
+    if $test -d $xxx; then
+		case " $libpth " in
+		*" $xxx "*) ;;
+		*) libpth="$libpth $xxx";;
+		esac
+    fi
+done
+$cat <<'EOM'
+
+Some systems have incompatible or broken versions of libraries.  Among
+the directories listed in the question below, please remove any you
+know not to be holding relevant libraries, and add any that are needed.
+Say "none" for none.
+
+EOM
+case "$libpth" in
+'') dflt='none';;
+*)
+	set X $libpth
+	shift
+	dflt=${1+"$@"}
+	;;
+esac
+rp="Directories to use for library searches?"
+. ./myread
+case "$ans" in
+none) libpth=' ';;
+*) libpth="$ans";;
+esac
+
 : flags used in final linking phase
 case "$ldflags" in
 '') if ./venix; then
@@ -2765,6 +2811,23 @@ case "$ldflags" in
 	;;
 *) dflt="$ldflags";;
 esac
+
+: Possible local library directories to search.
+loclibpth="/usr/local/lib /opt/local/lib /usr/gnu/lib"
+loclibpth="$loclibpth /opt/gnu/lib /usr/GNU/lib /opt/GNU/lib"
+
+: Try to guess additional flags to pick up local libraries.
+for thislibdir in $libpth; do
+	case " $loclibpth " in
+	*" $thislibdir "*)
+		case "$dflt " in 
+		"-L$thislibdir ") ;;
+		*)  dflt="$dflt -L$thislibdir" ;;
+		esac
+		;;
+	esac
+done
+
 echo " "
 rp="Any additional ld flags (NOT including libraries)?"
 . ./myread
@@ -2828,52 +2891,6 @@ n) echo "OK, that should do.";;
 esac
 $rm -f try try.* core
 
-: Set private lib path
-case "$plibpth" in
-%s
-		plibpth="$incpath/usr/lib /usr/local/lib /usr/ccs/lib"
-	fi;;
-esac
-case "$libpth" in
-' ') dlist='';;
-'') dlist="$plibpth $glibpth";;
-*) dlist="$libpth";;
-esac
-
-: Now check and see which directories actually exist, avoiding duplicates
-libpth=''
-for xxx in $dlist
-do
-    if $test -d $xxx; then
-		case " $libpth " in
-		*" $xxx "*) ;;
-		*) libpth="$libpth $xxx";;
-		esac
-    fi
-done
-$cat <<'EOM'
-
-Some systems have incompatible or broken versions of libraries.  Among
-the directories listed in the question below, please remove any you
-know not to be holding relevant libraries, and add any that are needed.
-Say "none" for none.
-
-EOM
-case "$libpth" in
-'') dflt='none';;
-*)
-	set X $libpth
-	shift
-	dflt=${1+"$@"}
-	;;
-esac
-rp="Directories to use for library searches?"
-. ./myread
-case "$ans" in
-none) libpth=' ';;
-*) libpth="$ans";;
-esac
-
 : compute shared library extension
 case "$so" in
 '')
EOPATCH
    }

    if ($major < 5 && extract_from_file('Configure',
                                        qr!if \$cc \$ccflags try\.c -o try >/dev/null 2>&1; then!)) {
        # Analogous to the more general fix of dfe9444ca7881e71
        # Without this flags such as -m64 may not be passed to this compile,
        # which results in a byteorder of '1234' instead of '12345678', which
        # can then cause crashes.

        if (extract_from_file('Configure', qr/xxx_prompt=y/)) {
            # 8e07c86ebc651fe9 or later
            # ("This is my patch  patch.1n  for perl5.001.")
            apply_patch(<<'EOPATCH');
diff --git a/Configure b/Configure
index 62249dd..c5c384e 100755
--- a/Configure
+++ b/Configure
@@ -8247,7 +8247,7 @@ main()
 }
 EOCP
 	xxx_prompt=y
-	if $cc $ccflags try.c -o try >/dev/null 2>&1 && ./try > /dev/null; then
+	if $cc $ccflags $ldflags try.c -o try >/dev/null 2>&1 && ./try > /dev/null; then
 		dflt=`./try`
 		case "$dflt" in
 		[1-4][1-4][1-4][1-4]|12345678|87654321)
EOPATCH
        } else {
            apply_patch(<<'EOPATCH');
diff --git a/Configure b/Configure
index 53649d5..f1cd64a 100755
--- a/Configure
+++ b/Configure
@@ -6362,7 +6362,7 @@ main()
 	printf("\n");
 }
 EOCP
-	if $cc $ccflags try.c -o try >/dev/null 2>&1 ; then
+	if $cc $ccflags $ldflags try.c -o try >/dev/null 2>&1 ; then
 		dflt=`./try`
 		case "$dflt" in
 		????|????????) echo "(The test program ran ok.)";;
EOPATCH
        }
    }

    if ($major < 6 && !extract_from_file('Configure',
                                         qr!^\t-A\)$!)) {
        # This adds the -A option to Configure, which is incredibly useful
        # Effectively this is commits 02e93a22d20fc9a5, 5f83a3e9d818c3ad,
        # bde6b06b2c493fef, f7c3111703e46e0c and 2 lines of trailing whitespace
        # removed by 613d6c3e99b9decc, but applied at slightly different
        # locations to ensure a clean patch back to 5.000
        # Note, if considering patching to the intermediate revisions to fix
        # bugs in -A handling, f7c3111703e46e0c is from 2002, and hence
        # $major == 8

        # To add to the fun, early patches add -K and -O options, and it's not
        # trivial to get patch to put the C<. ./posthint.sh> in the right place
        edit_file('Configure', sub {
                      my $code = shift;
                      $code =~ s/(optstr = ")([^"]+";\s*# getopt-style specification)/$1A:$2/
                          or die "Substitution failed";
                      $code =~ s!^(: who configured the system)!
touch posthint.sh
. ./posthint.sh

$1!ms
                          or die "Substitution failed";
                      return $code;
                  });
        apply_patch(<<'EOPATCH');
diff --git a/Configure b/Configure
index 4b55fa6..60c3c64 100755
--- a/Configure
+++ b/Configure
@@ -1150,6 +1150,7 @@ set X `for arg in "$@"; do echo "X$arg"; done |
 eval "set $*"
 shift
 rm -f options.awk
+rm -f posthint.sh
 
 : set up default values
 fastread=''
@@ -1172,6 +1173,56 @@ while test $# -gt 0; do
 	case "$1" in
 	-d) shift; fastread=yes;;
 	-e) shift; alldone=cont;;
+	-A)
+	    shift
+	    xxx=''
+	    yyy="$1"
+	    zzz=''
+	    uuu=undef
+	    case "$yyy" in
+            *=*) zzz=`echo "$yyy"|sed 's!=.*!!'`
+                 case "$zzz" in
+                 *:*) zzz='' ;;
+                 *)   xxx=append
+                      zzz=" "`echo "$yyy"|sed 's!^[^=]*=!!'`
+                      yyy=`echo "$yyy"|sed 's!=.*!!'` ;;
+                 esac
+                 ;;
+            esac
+            case "$xxx" in
+            '')  case "$yyy" in
+                 *:*) xxx=`echo "$yyy"|sed 's!:.*!!'`
+                      yyy=`echo "$yyy"|sed 's!^[^:]*:!!'`
+                      zzz=`echo "$yyy"|sed 's!^[^=]*=!!'`
+                      yyy=`echo "$yyy"|sed 's!=.*!!'` ;;
+                 *)   xxx=`echo "$yyy"|sed 's!:.*!!'`
+                      yyy=`echo "$yyy"|sed 's!^[^:]*:!!'` ;;
+                 esac
+                 ;;
+            esac
+	    case "$xxx" in
+	    append)
+		echo "$yyy=\"\${$yyy}$zzz\""	>> posthint.sh ;;
+	    clear)
+		echo "$yyy=''"			>> posthint.sh ;;
+	    define)
+	        case "$zzz" in
+		'') zzz=define ;;
+		esac
+		echo "$yyy='$zzz'"		>> posthint.sh ;;
+	    eval)
+		echo "eval \"$yyy=$zzz\""	>> posthint.sh ;;
+	    prepend)
+		echo "$yyy=\"$zzz\${$yyy}\""	>> posthint.sh ;;
+	    undef)
+	        case "$zzz" in
+		'') zzz="$uuu" ;;
+		esac
+		echo "$yyy=$zzz"		>> posthint.sh ;;
+            *)  echo "$me: unknown -A command '$xxx', ignoring -A $1" >&2 ;;
+	    esac
+	    shift
+	    ;;
 	-f)
 		shift
 		cd ..
EOPATCH
    }

    if ($major < 8 && !extract_from_file('Configure',
                                         qr/^\t\tif test ! -t 0; then$/)) {
        # Before dfe9444ca7881e71, Configure would refuse to run if stdin was
        # not a tty. With that commit, the tty requirement was dropped for -de
        # and -dE
        # Commit aaeb8e512e8e9e14 dropped the tty requirement for -S
        # For those older versions, it's probably easiest if we simply remove
        # the sanity test.
        edit_file('Configure', sub {
                      my $code = shift;
                      $code =~ s/test ! -t 0/test Perl = rules/;
                      return $code;
                  });
    }

    if ($major == 8 || $major == 9) {
        # Fix symbol detection to that of commit 373dfab3839ca168 if it's any
        # intermediate version 5129fff43c4fe08c or later, as the intermediate
        # versions don't work correctly on (at least) Sparc Linux.
        # 5129fff43c4fe08c adds the first mention of mistrustnm.
        # 373dfab3839ca168 removes the last mention of lc=""
        edit_file('Configure', sub {
                      my $code = shift;
                      return $code
                          if $code !~ /\btc="";/; # 373dfab3839ca168 or later
                      return $code
                          if $code !~ /\bmistrustnm\b/; # before 5129fff43c4fe08c
                      my $fixed = <<'EOC';

: is a C symbol defined?
csym='tlook=$1;
case "$3" in
-v) tf=libc.tmp; tdc="";;
-a) tf=libc.tmp; tdc="[]";;
*) tlook="^$1\$"; tf=libc.list; tdc="()";;
esac;
tx=yes;
case "$reuseval-$4" in
true-) ;;
true-*) tx=no; eval "tval=\$$4"; case "$tval" in "") tx=yes;; esac;;
esac;
case "$tx" in
yes)
	tval=false;
	if $test "$runnm" = true; then
		if $contains $tlook $tf >/dev/null 2>&1; then
			tval=true;
		elif $test "$mistrustnm" = compile -o "$mistrustnm" = run; then
			echo "void *(*(p()))$tdc { extern void *$1$tdc; return &$1; } int main() { if(p()) return(0); else return(1); }"> try.c;
			$cc -o try $optimize $ccflags $ldflags try.c >/dev/null 2>&1 $libs && tval=true;
			$test "$mistrustnm" = run -a -x try && { $run ./try$_exe >/dev/null 2>&1 || tval=false; };
			$rm -f try$_exe try.c core core.* try.core;
		fi;
	else
		echo "void *(*(p()))$tdc { extern void *$1$tdc; return &$1; } int main() { if(p()) return(0); else return(1); }"> try.c;
		$cc -o try $optimize $ccflags $ldflags try.c $libs >/dev/null 2>&1 && tval=true;
		$rm -f try$_exe try.c;
	fi;
	;;
*)
	case "$tval" in
	$define) tval=true;;
	*) tval=false;;
	esac;
	;;
esac;
eval "$2=$tval"'

EOC
                      $code =~ s/\n: is a C symbol defined\?\n.*?\neval "\$2=\$tval"'\n\n/$fixed/sm
                          or die "substitution failed";
                      return $code;
                  });
    }

    if ($major < 10
        && extract_from_file('Configure', qr/^set malloc\.h i_malloc$/)) {
        # This is commit 01d07975f7ef0e7d, trimmed, with $compile inlined as
        # prior to bd9b35c97ad661cc Configure had the malloc.h test before the
        # definition of $compile.
        apply_patch(<<'EOPATCH');
diff --git a/Configure b/Configure
index 3d2e8b9..6ce7766 100755
--- a/Configure
+++ b/Configure
@@ -6743,5 +6743,22 @@ set d_dosuid
 
 : see if this is a malloc.h system
-set malloc.h i_malloc
-eval $inhdr
+: we want a real compile instead of Inhdr because some systems have a
+: malloc.h that just gives a compile error saying to use stdlib.h instead
+echo " "
+$cat >try.c <<EOCP
+#include <stdlib.h>
+#include <malloc.h>
+int main () { return 0; }
+EOCP
+set try
+if $cc $optimize $ccflags $ldflags -o try $* try.c $libs > /dev/null 2>&1; then
+    echo "<malloc.h> found." >&4
+    val="$define"
+else
+    echo "<malloc.h> NOT found." >&4
+    val="$undef"
+fi
+$rm -f try.c try
+set i_malloc
+eval $setvar
 
EOPATCH
    }
}

sub patch_hints {
    if ($^O eq 'freebsd') {
        # There are rather too many version-specific FreeBSD hints fixes to
        # patch individually. Also, more than once the FreeBSD hints file has
        # been written in what turned out to be a rather non-future-proof style,
        # with case statements treating the most recent version as the
        # exception, instead of treating previous versions' behaviour explicitly
        # and changing the default to cater for the current behaviour. (As
        # strangely, future versions inherit the current behaviour.)
        checkout_file('hints/freebsd.sh');
    } elsif ($^O eq 'darwin') {
        if ($major < 8) {
            # We can't build on darwin without some of the data in the hints
            # file. Probably less surprising to use the earliest version of
            # hints/darwin.sh and then edit in place just below, than use
            # blead's version, as that would create a discontinuity at
            # f556e5b971932902 - before it, hints bugs would be "fixed", after
            # it they'd resurface. This way, we should give the illusion of
            # monotonic bug fixing.
            my $faking_it;
            if (!-f 'hints/darwin.sh') {
                checkout_file('hints/darwin.sh', 'f556e5b971932902');
                ++$faking_it;
            }

            edit_file('hints/darwin.sh', sub {
                      my $code = shift;
                      # Part of commit 8f4f83badb7d1ba9, which mostly undoes
                      # commit 0511a818910f476c.
                      $code =~ s/^cppflags='-traditional-cpp';$/cppflags="\${cppflags} -no-cpp-precomp"/m;
                      # commit 14c11978e9b52e08/803bb6cc74d36a3f
                      # Without this, code in libperl.bundle links against op.o
                      # in preference to opmini.o on the linker command line,
                      # and hence miniperl tries to use File::Glob instead of
                      # csh
                      $code =~ s/^(lddlflags=)/ldflags="\${ldflags} -flat_namespace"\n$1/m;
                      # f556e5b971932902 also patches Makefile.SH with some
                      # special case code to deal with useshrplib for darwin.
                      # Given that post 5.8.0 the darwin hints default was
                      # changed to false, and it would be very complex to splice
                      # in that code in various versions of Makefile.SH back
                      # to 5.002, lets just turn it off.
                      $code =~ s/^useshrplib='true'/useshrplib='false'/m
                          if $faking_it;
                      return $code;
                  });
        }
    } elsif ($^O eq 'netbsd') {
        if ($major < 6) {
            # These are part of commit 099685bc64c7dbce
            edit_file('hints/netbsd.sh', sub {
                          my $code = shift;
                          my $fixed = <<'EOC';
case "$osvers" in
0.9|0.8*)
	usedl="$undef"
	;;
*)
	if [ -f /usr/libexec/ld.elf_so ]; then
		d_dlopen=$define
		d_dlerror=$define
		ccdlflags="-Wl,-E -Wl,-R${PREFIX}/lib $ccdlflags"
		cccdlflags="-DPIC -fPIC $cccdlflags"
		lddlflags="--whole-archive -shared $lddlflags"
	elif [ "`uname -m`" = "pmax" ]; then
# NetBSD 1.3 and 1.3.1 on pmax shipped an `old' ld.so, which will not work.
		d_dlopen=$undef
	elif [ -f /usr/libexec/ld.so ]; then
		d_dlopen=$define
		d_dlerror=$define
		ccdlflags="-Wl,-R${PREFIX}/lib $ccdlflags"
# we use -fPIC here because -fpic is *NOT* enough for some of the
# extensions like Tk on some netbsd platforms (the sparc is one)
		cccdlflags="-DPIC -fPIC $cccdlflags"
		lddlflags="-Bforcearchive -Bshareable $lddlflags"
	else
		d_dlopen=$undef
	fi
	;;
esac
EOC
                          $code =~ s/^case "\$osvers" in\n0\.9\|0\.8.*?^esac\n/$fixed/ms;
                          return $code;
                      });
        }
    } elsif ($^O eq 'openbsd') {
        if ($major < 8) {
            checkout_file('hints/openbsd.sh', '43051805d53a3e4c')
                unless -f 'hints/openbsd.sh';
            my $which = extract_from_file('hints/openbsd.sh',
                                          qr/# from (2\.8|3\.1) onwards/,
                                          '');
            if ($which eq '') {
                my $was = extract_from_file('hints/openbsd.sh',
                                            qr/(lddlflags="(?:-Bforcearchive )?-Bshareable)/);
                # This is commit 154d43cbcf57271c and parts of 5c75dbfa77b0949c
                # and 29b5585702e5e025
                apply_patch(sprintf <<'EOPATCH', $was);
diff --git a/hints/openbsd.sh b/hints/openbsd.sh
index a7d8bf2..5b79709 100644
--- a/hints/openbsd.sh
+++ b/hints/openbsd.sh
@@ -37,7 +37,25 @@ OpenBSD.alpha|OpenBSD.mips|OpenBSD.powerpc|OpenBSD.vax)
 	# we use -fPIC here because -fpic is *NOT* enough for some of the
 	# extensions like Tk on some OpenBSD platforms (ie: sparc)
 	cccdlflags="-DPIC -fPIC $cccdlflags"
-	%s $lddlflags"
+	case "$osvers" in
+	[01].*|2.[0-7]|2.[0-7].*)
+		lddlflags="-Bshareable $lddlflags"
+		;;
+	2.[8-9]|3.0)
+		ld=${cc:-cc}
+		lddlflags="-shared -fPIC $lddlflags"
+		;;
+	*) # from 3.1 onwards
+		ld=${cc:-cc}
+		lddlflags="-shared -fPIC $lddlflags"
+		libswanted=`echo $libswanted | sed 's/ dl / /'`
+		;;
+	esac
+
+	# We need to force ld to export symbols on ELF platforms.
+	# Without this, dlopen() is crippled.
+	ELF=`${cc:-cc} -dM -E - </dev/null | grep __ELF__`
+	test -n "$ELF" && ldflags="-Wl,-E $ldflags"
 	;;
 esac
 
EOPATCH
            } elsif ($which eq '2.8') {
                # This is parts of 5c75dbfa77b0949c and 29b5585702e5e025, and
                # possibly eb9cd59d45ad2908
                my $was = extract_from_file('hints/openbsd.sh',
                                            qr/lddlflags="(-shared(?: -fPIC)?) \$lddlflags"/);

                apply_patch(sprintf <<'EOPATCH', $was);
--- a/hints/openbsd.sh	2011-10-21 17:25:20.000000000 +0200
+++ b/hints/openbsd.sh	2011-10-21 16:58:43.000000000 +0200
@@ -44,11 +44,21 @@
 	[01].*|2.[0-7]|2.[0-7].*)
 		lddlflags="-Bshareable $lddlflags"
 		;;
-	*) # from 2.8 onwards
+	2.[8-9]|3.0)
 		ld=${cc:-cc}
-		lddlflags="%s $lddlflags"
+		lddlflags="-shared -fPIC $lddlflags"
+		;;
+	*) # from 3.1 onwards
+		ld=${cc:-cc}
+		lddlflags="-shared -fPIC $lddlflags"
+		libswanted=`echo $libswanted | sed 's/ dl / /'`
 		;;
 	esac
+
+	# We need to force ld to export symbols on ELF platforms.
+	# Without this, dlopen() is crippled.
+	ELF=`${cc:-cc} -dM -E - </dev/null | grep __ELF__`
+	test -n "$ELF" && ldflags="-Wl,-E $ldflags"
 	;;
 esac
 
EOPATCH
            } elsif ($which eq '3.1'
                     && !extract_from_file('hints/openbsd.sh',
                                           qr/We need to force ld to export symbols on ELF platforms/)) {
                # This is part of 29b5585702e5e025
                apply_patch(<<'EOPATCH');
diff --git a/hints/openbsd.sh b/hints/openbsd.sh
index c6b6bc9..4839d04 100644
--- a/hints/openbsd.sh
+++ b/hints/openbsd.sh
@@ -54,6 +54,11 @@ alpha-2.[0-8]|mips-*|vax-*|powerpc-2.[0-7]|m88k-*)
 		libswanted=`echo $libswanted | sed 's/ dl / /'`
 		;;
 	esac
+
+	# We need to force ld to export symbols on ELF platforms.
+	# Without this, dlopen() is crippled.
+	ELF=`${cc:-cc} -dM -E - </dev/null | grep __ELF__`
+	test -n "$ELF" && ldflags="-Wl,-E $ldflags"
 	;;
 esac
 
EOPATCH
            }
        }
    } elsif ($^O eq 'linux') {
        if ($major < 1) {
            # sparc linux seems to need the -Dbool=char -DHAS_BOOL part of
            # perl5.000 patch.0n: [address Configure and build issues]
            edit_file('hints/linux.sh', sub {
                          my $code = shift;
                          $code =~ s!-I/usr/include/bsd!-Dbool=char -DHAS_BOOL!g;
                          return $code;
                      });
        }

        if ($major <= 9) {
            if (`uname -sm` =~ qr/^Linux sparc/) {
                if (extract_from_file('hints/linux.sh', qr/sparc-linux/)) {
                    # Be sure to use -fPIC not -fpic on Linux/SPARC
                    apply_commit('f6527d0ef0c13ad4');
                } elsif(!extract_from_file('hints/linux.sh',
                                           qr/^sparc-linux\)$/)) {
                    my $fh = open_or_die('hints/linux.sh', '>>');
                    print $fh <<'EOT' or die $!;

case "`uname -m`" in
sparc*)
	case "$cccdlflags" in
	*-fpic*) cccdlflags="`echo $cccdlflags|sed 's/-fpic/-fPIC/'`" ;;
	*)	 cccdlflags="$cccdlflags -fPIC" ;;
	esac
	;;
esac
EOT
                    close_or_die($fh);
                }
            }
        }
    }
}

sub patch_SH {
    # Cwd.xs added in commit 0d2079faa739aaa9. Cwd.pm moved to ext/ 8 years
    # later in commit 403f501d5b37ebf0
    if ($major > 0 && <*/Cwd/Cwd.xs>) {
        if ($major < 10
            && !extract_from_file('Makefile.SH', qr/^extra_dep=''$/)) {
            # The Makefile.PL for Unicode::Normalize needs
            # lib/unicore/CombiningClass.pl. Even without a parallel build, we
            # need a dependency to ensure that it builds. This is a variant of
            # commit 9f3ef600c170f61e. Putting this for earlier versions gives
            # us a spot on which to hang the edits below
            apply_patch(<<'EOPATCH');
diff --git a/Makefile.SH b/Makefile.SH
index f61d0db..6097954 100644
--- a/Makefile.SH
+++ b/Makefile.SH
@@ -155,10 +155,20 @@ esac
 
 : Prepare dependency lists for Makefile.
 dynamic_list=' '
+extra_dep=''
 for f in $dynamic_ext; do
     : the dependency named here will never exist
       base=`echo "$f" | sed 's/.*\///'`
-    dynamic_list="$dynamic_list lib/auto/$f/$base.$dlext"
+    this_target="lib/auto/$f/$base.$dlext"
+    dynamic_list="$dynamic_list $this_target"
+
+    : Parallel makes reveal that we have some interdependencies
+    case $f in
+	Math/BigInt/FastCalc) extra_dep="$extra_dep
+$this_target: lib/auto/List/Util/Util.$dlext" ;;
+	Unicode/Normalize) extra_dep="$extra_dep
+$this_target: lib/unicore/CombiningClass.pl" ;;
+    esac
 done
 
 static_list=' '
@@ -987,2 +997,9 @@ n_dummy $(nonxs_ext):	miniperl$(EXE_EXT) preplibrary $(DYNALOADER) FORCE
 	@$(LDLIBPTH) sh ext/util/make_ext nonxs $@ MAKE=$(MAKE) LIBPERL_A=$(LIBPERL)
+!NO!SUBS!
+
+$spitshell >>Makefile <<EOF
+$extra_dep
+EOF
+
+$spitshell >>Makefile <<'!NO!SUBS!'
 
EOPATCH
        }
        if ($major < 14) {
            # Commits dc0655f797469c47 and d11a62fe01f2ecb2
            edit_file('Makefile.SH', sub {
                          my $code = shift;
                          foreach my $ext (qw(Encode SDBM_File)) {
                              next if $code =~ /\b$ext\) extra_dep=/s;
                              $code =~ s!(\) extra_dep="\$extra_dep
\$this_target: .*?" ;;)
(    esac
)!$1
	$ext) extra_dep="\$extra_dep
\$this_target: lib/auto/Cwd/Cwd.\$dlext" ;;
$2!;
                          }
                          return $code;
                      });
        }
    }

    if ($major == 7) {
        # Remove commits 9fec149bb652b6e9 and 5bab1179608f81d8, which add/amend
        # rules to automatically run regen scripts that rebuild C headers. These
        # cause problems because a git checkout doesn't preserve relative file
        # modification times, hence the regen scripts may fire. This will
        # obscure whether the repository had the correct generated headers
        # checked in.
        # Also, the dependency rules for running the scripts were not correct,
        # which could cause spurious re-builds on re-running make, and can cause
        # complete build failures for a parallel make.
        if (extract_from_file('Makefile.SH',
                              qr/Writing it this way gives make a big hint to always run opcode\.pl before/)) {
            apply_commit('70c6e6715e8fec53');
        } elsif (extract_from_file('Makefile.SH',
                                   qr/^opcode\.h opnames\.h pp_proto\.h pp\.sym: opcode\.pl$/)) {
            revert_commit('9fec149bb652b6e9');
        }
    }

    # There was a bug in makedepend.SH which was fixed in version 96a8704c.
    # Symptom was './makedepend: 1: Syntax error: Unterminated quoted string'
    # Remove this if you're actually bisecting a problem related to
    # makedepend.SH
    # If you do this, you may need to add in code to correct the output of older
    # makedepends, which don't correctly filter newer gcc output such as
    # <built-in>
    checkout_file('makedepend.SH');

    if ($major < 4 && -f 'config.sh'
        && !extract_from_file('config.sh', qr/^trnl=/)) {
        # This seems to be necessary to avoid makedepend becoming confused,
        # and hanging on stdin. Seems that the code after
        # make shlist || ...here... is never run.
        edit_file('makedepend.SH', sub {
                      my $code = shift;
                      $code =~ s/^trnl='\$trnl'$/trnl='\\n'/m;
                      return $code;
                  });
    }
}

sub patch_C {
    # This is ordered by $major, as it's likely that different platforms may
    # well want to share code.

    if ($major == 2 && extract_from_file('perl.c', qr/^\tfclose\(e_fp\);$/)) {
        # need to patch perl.c to avoid calling fclose() twice on e_fp when
        # using -e
        # This diff is part of commit ab821d7fdc14a438. The second close was
        # introduced with perl-5.002, commit a5f75d667838e8e7
        # Might want a6c477ed8d4864e6 too, for the corresponding change to
        # pp_ctl.c (likely without this, eval will have "fun")
        apply_patch(<<'EOPATCH');
diff --git a/perl.c b/perl.c
index 03c4d48..3c814a2 100644
--- a/perl.c
+++ b/perl.c
@@ -252,6 +252,7 @@ setuid perl scripts securely.\n");
 #ifndef VMS  /* VMS doesn't have environ array */
     origenviron = environ;
 #endif
+    e_tmpname = Nullch;
 
     if (do_undump) {
 
@@ -405,6 +406,7 @@ setuid perl scripts securely.\n");
     if (e_fp) {
 	if (Fflush(e_fp) || ferror(e_fp) || fclose(e_fp))
 	    croak("Can't write to temp file for -e: %s", Strerror(errno));
+	e_fp = Nullfp;
 	argc++,argv--;
 	scriptname = e_tmpname;
     }
@@ -470,10 +472,10 @@ setuid perl scripts securely.\n");
     curcop->cop_line = 0;
     curstash = defstash;
     preprocess = FALSE;
-    if (e_fp) {
-	fclose(e_fp);
-	e_fp = Nullfp;
+    if (e_tmpname) {
 	(void)UNLINK(e_tmpname);
+	Safefree(e_tmpname);
+	e_tmpname = Nullch;
     }
 
     /* now that script is parsed, we can modify record separator */
@@ -1369,7 +1371,7 @@ SV *sv;
 	scriptname = xfound;
     }
 
-    origfilename = savepv(e_fp ? "-e" : scriptname);
+    origfilename = savepv(e_tmpname ? "-e" : scriptname);
     curcop->cop_filegv = gv_fetchfile(origfilename);
     if (strEQ(origfilename,"-"))
 	scriptname = "";

EOPATCH
    }

    if ($major < 3 && $^O eq 'openbsd'
        && !extract_from_file('pp_sys.c', qr/BSD_GETPGRP/)) {
        # Part of commit c3293030fd1b7489
        apply_patch(<<'EOPATCH');
diff --git a/pp_sys.c b/pp_sys.c
index 4608a2a..f0c9d1d 100644
--- a/pp_sys.c
+++ b/pp_sys.c
@@ -2903,8 +2903,8 @@ PP(pp_getpgrp)
 	pid = 0;
     else
 	pid = SvIVx(POPs);
-#ifdef USE_BSDPGRP
-    value = (I32)getpgrp(pid);
+#ifdef BSD_GETPGRP
+    value = (I32)BSD_GETPGRP(pid);
 #else
     if (pid != 0)
 	DIE("POSIX getpgrp can't take an argument");
@@ -2933,8 +2933,8 @@ PP(pp_setpgrp)
     }
 
     TAINT_PROPER("setpgrp");
-#ifdef USE_BSDPGRP
-    SETi( setpgrp(pid, pgrp) >= 0 );
+#ifdef BSD_SETPGRP
+    SETi( BSD_SETPGRP(pid, pgrp) >= 0 );
 #else
     if ((pgrp != 0) || (pid != 0)) {
 	DIE("POSIX setpgrp can't take an argument");
EOPATCH
    }

    if ($major < 4 && $^O eq 'openbsd') {
        my $bad;
        # Need changes from commit a6e633defa583ad5.
        # Commits c07a80fdfe3926b5 and f82b3d4130164d5f changed the same part
        # of perl.h

        if (extract_from_file('perl.h',
                              qr/^#ifdef HAS_GETPGRP2$/)) {
            $bad = <<'EOBAD';
***************
*** 57,71 ****
  #define TAINT_PROPER(s)	if (tainting) taint_proper(no_security, s)
  #define TAINT_ENV()	if (tainting) taint_env()
  
! #ifdef HAS_GETPGRP2
! #   ifndef HAS_GETPGRP
! #	define HAS_GETPGRP
! #   endif
! #endif
! 
! #ifdef HAS_SETPGRP2
! #   ifndef HAS_SETPGRP
! #	define HAS_SETPGRP
! #   endif
  #endif
  
EOBAD
        } elsif (extract_from_file('perl.h',
                                   qr/Gack, you have one but not both of getpgrp2/)) {
            $bad = <<'EOBAD';
***************
*** 56,76 ****
  #define TAINT_PROPER(s)	if (tainting) taint_proper(no_security, s)
  #define TAINT_ENV()	if (tainting) taint_env()
  
! #if defined(HAS_GETPGRP2) && defined(HAS_SETPGRP2)
! #   define getpgrp getpgrp2
! #   define setpgrp setpgrp2
! #   ifndef HAS_GETPGRP
! #	define HAS_GETPGRP
! #   endif
! #   ifndef HAS_SETPGRP
! #	define HAS_SETPGRP
! #   endif
! #   ifndef USE_BSDPGRP
! #	define USE_BSDPGRP
! #   endif
! #else
! #   if defined(HAS_GETPGRP2) || defined(HAS_SETPGRP2)
! 	#include "Gack, you have one but not both of getpgrp2() and setpgrp2()."
! #   endif
  #endif
  
EOBAD
        } elsif (extract_from_file('perl.h',
                                   qr/^#ifdef USE_BSDPGRP$/)) {
            $bad = <<'EOBAD'
***************
*** 91,116 ****
  #define TAINT_PROPER(s)	if (tainting) taint_proper(no_security, s)
  #define TAINT_ENV()	if (tainting) taint_env()
  
! #ifdef USE_BSDPGRP
! #   ifdef HAS_GETPGRP
! #       define BSD_GETPGRP(pid) getpgrp((pid))
! #   endif
! #   ifdef HAS_SETPGRP
! #       define BSD_SETPGRP(pid, pgrp) setpgrp((pid), (pgrp))
! #   endif
! #else
! #   ifdef HAS_GETPGRP2
! #       define BSD_GETPGRP(pid) getpgrp2((pid))
! #       ifndef HAS_GETPGRP
! #    	    define HAS_GETPGRP
! #    	endif
! #   endif
! #   ifdef HAS_SETPGRP2
! #       define BSD_SETPGRP(pid, pgrp) setpgrp2((pid), (pgrp))
! #       ifndef HAS_SETPGRP
! #    	    define HAS_SETPGRP
! #    	endif
! #   endif
  #endif
  
  #ifndef _TYPES_		/* If types.h defines this it's easy. */
EOBAD
        }
        if ($bad) {
            apply_patch(<<"EOPATCH");
*** a/perl.h	2011-10-21 09:46:12.000000000 +0200
--- b/perl.h	2011-10-21 09:46:12.000000000 +0200
$bad--- 91,144 ----
  #define TAINT_PROPER(s)	if (tainting) taint_proper(no_security, s)
  #define TAINT_ENV()	if (tainting) taint_env()
  
! /* XXX All process group stuff is handled in pp_sys.c.  Should these 
!    defines move there?  If so, I could simplify this a lot. --AD  9/96.
! */
! /* Process group stuff changed from traditional BSD to POSIX.
!    perlfunc.pod documents the traditional BSD-style syntax, so we'll
!    try to preserve that, if possible.
! */
! #ifdef HAS_SETPGID
! #  define BSD_SETPGRP(pid, pgrp)	setpgid((pid), (pgrp))
! #else
! #  if defined(HAS_SETPGRP) && defined(USE_BSD_SETPGRP)
! #    define BSD_SETPGRP(pid, pgrp)	setpgrp((pid), (pgrp))
! #  else
! #    ifdef HAS_SETPGRP2  /* DG/UX */
! #      define BSD_SETPGRP(pid, pgrp)	setpgrp2((pid), (pgrp))
! #    endif
! #  endif
! #endif
! #if defined(BSD_SETPGRP) && !defined(HAS_SETPGRP)
! #  define HAS_SETPGRP  /* Well, effectively it does . . . */
! #endif
! 
! /* getpgid isn't POSIX, but at least Solaris and Linux have it, and it makes
!     our life easier :-) so we'll try it.
! */
! #ifdef HAS_GETPGID
! #  define BSD_GETPGRP(pid)		getpgid((pid))
! #else
! #  if defined(HAS_GETPGRP) && defined(USE_BSD_GETPGRP)
! #    define BSD_GETPGRP(pid)		getpgrp((pid))
! #  else
! #    ifdef HAS_GETPGRP2  /* DG/UX */
! #      define BSD_GETPGRP(pid)		getpgrp2((pid))
! #    endif
! #  endif
! #endif
! #if defined(BSD_GETPGRP) && !defined(HAS_GETPGRP)
! #  define HAS_GETPGRP  /* Well, effectively it does . . . */
! #endif
! 
! /* These are not exact synonyms, since setpgrp() and getpgrp() may 
!    have different behaviors, but perl.h used to define USE_BSDPGRP
!    (prior to 5.003_05) so some extension might depend on it.
! */
! #if defined(USE_BSD_SETPGRP) || defined(USE_BSD_GETPGRP)
! #  ifndef USE_BSDPGRP
! #    define USE_BSDPGRP
! #  endif
  #endif
  
  #ifndef _TYPES_		/* If types.h defines this it's easy. */
EOPATCH
        }
    }

    if ($major == 4 && extract_from_file('scope.c', qr/\(SV\*\)SSPOPINT/)) {
        # [PATCH] 5.004_04 +MAINT_TRIAL_1 broken when sizeof(int) != sizeof(void)
        # Fixes a bug introduced in 161b7d1635bc830b
        apply_commit('9002cb76ec83ef7f');
    }

    if ($major == 4 && extract_from_file('av.c', qr/AvARRAY\(av\) = 0;/)) {
        # Fixes a bug introduced in 1393e20655efb4bc
        apply_commit('e1c148c28bf3335b', 'av.c');
    }

    if ($major == 4 && !extract_from_file('perl.c', qr/delimcpy.*,$/)) {
        # bug introduced in 2a92aaa05aa1acbf, fixed in 8490252049bf42d3
        apply_patch(<<'EOPATCH');
diff --git a/perl.c b/perl.c
index 4eb69e3..54bbb00 100644
--- a/perl.c
+++ b/perl.c
@@ -1735,7 +1735,7 @@ SV *sv;
 	    if (len < sizeof tokenbuf)
 		tokenbuf[len] = '\0';
 #else	/* ! (atarist || DOSISH) */
-	    s = delimcpy(tokenbuf, tokenbuf + sizeof tokenbuf, s, bufend
+	    s = delimcpy(tokenbuf, tokenbuf + sizeof tokenbuf, s, bufend,
 			 ':',
 			 &len);
 #endif	/* ! (atarist || DOSISH) */
EOPATCH
    }

    if ($major == 4 && $^O eq 'linux') {
        # Whilst this is fixed properly in f0784f6a4c3e45e1 which provides the
        # Configure probe, it's easier to back out the problematic changes made
        # in these previous commits:
        if (extract_from_file('doio.c',
                              qr!^/\* XXX REALLY need metaconfig test \*/$!)) {
            revert_commit('4682965a1447ea44', 'doio.c');
        }
        if (my $token = extract_from_file('doio.c',
                                          qr!^#if (defined\(__sun(?:__)?\)) && defined\(__svr4__\) /\* XXX Need metaconfig test \*/$!)) {
            my $patch = `git show -R 9b599b2a63d2324d doio.c`;
            $patch =~ s/defined\(__sun__\)/$token/g;
            apply_patch($patch);
        }
        if (extract_from_file('doio.c',
                              qr!^/\* linux \(and Solaris2\?\) uses :$!)) {
            revert_commit('8490252049bf42d3', 'doio.c');
        }
        if (extract_from_file('doio.c',
                              qr/^	    unsemds.buf = &semds;$/)) {
            revert_commit('8e591e46b4c6543e');
        }
        if (extract_from_file('doio.c',
                              qr!^#ifdef __linux__	/\* XXX Need metaconfig test \*/$!)) {
            # Reverts part of commit 3e3baf6d63945cb6
            apply_patch(<<'EOPATCH');
diff --git b/doio.c a/doio.c
index 62b7de9..0d57425 100644
--- b/doio.c
+++ a/doio.c
@@ -1333,9 +1331,6 @@ SV **sp;
     char *a;
     I32 id, n, cmd, infosize, getinfo;
     I32 ret = -1;
-#ifdef __linux__	/* XXX Need metaconfig test */
-    union semun unsemds;
-#endif
 
     id = SvIVx(*++mark);
     n = (optype == OP_SEMCTL) ? SvIVx(*++mark) : 0;
@@ -1364,29 +1359,11 @@ SV **sp;
 	    infosize = sizeof(struct semid_ds);
 	else if (cmd == GETALL || cmd == SETALL)
 	{
-#ifdef __linux__	/* XXX Need metaconfig test */
-/* linux uses :
-   int semctl (int semid, int semnun, int cmd, union semun arg)
-
-       union semun {
-            int val;
-            struct semid_ds *buf;
-            ushort *array;
-       };
-*/
-            union semun semds;
-	    if (semctl(id, 0, IPC_STAT, semds) == -1)
-#else
 	    struct semid_ds semds;
 	    if (semctl(id, 0, IPC_STAT, &semds) == -1)
-#endif
 		return -1;
 	    getinfo = (cmd == GETALL);
-#ifdef __linux__	/* XXX Need metaconfig test */
-	    infosize = semds.buf->sem_nsems * sizeof(short);
-#else
 	    infosize = semds.sem_nsems * sizeof(short);
-#endif
 		/* "short" is technically wrong but much more portable
 		   than guessing about u_?short(_t)? */
 	}
@@ -1429,12 +1406,7 @@ SV **sp;
 #endif
 #ifdef HAS_SEM
     case OP_SEMCTL:
-#ifdef __linux__	/* XXX Need metaconfig test */
-        unsemds.buf = (struct semid_ds *)a;
-	ret = semctl(id, n, cmd, unsemds);
-#else
 	ret = semctl(id, n, cmd, (struct semid_ds *)a);
-#endif
 	break;
 #endif
 #ifdef HAS_SHM
EOPATCH
        }
        # Incorrect prototype added as part of 8ac853655d9b7447, fixed as part
        # of commit dc45a647708b6c54, with at least one intermediate
        # modification. Correct prototype for gethostbyaddr has socklen_t
        # second. Linux has uint32_t first for getnetbyaddr.
        # Easiest just to remove, instead of attempting more complex patching.
        # Something similar may be needed on other platforms.
        edit_file('pp_sys.c', sub {
                      my $code = shift;
                      $code =~ s/^    struct hostent \*(?:PerlSock_)?gethostbyaddr\([^)]+\);$//m;
                      $code =~ s/^    struct netent \*getnetbyaddr\([^)]+\);$//m;
                      return $code;
                  });
    }

    if ($major < 6 && $^O eq 'netbsd'
        && !extract_from_file('unixish.h',
                              qr/defined\(NSIG\).*defined\(__NetBSD__\)/)) {
        apply_patch(<<'EOPATCH')
diff --git a/unixish.h b/unixish.h
index 2a6cbcd..eab2de1 100644
--- a/unixish.h
+++ b/unixish.h
@@ -89,7 +89,7 @@
  */
 /* #define ALTERNATE_SHEBANG "#!" / **/
 
-#if !defined(NSIG) || defined(M_UNIX) || defined(M_XENIX)
+#if !defined(NSIG) || defined(M_UNIX) || defined(M_XENIX) || defined(__NetBSD__)
 # include <signal.h>
 #endif
 
EOPATCH
    }

    if (($major >= 7 || $major <= 9) && $^O eq 'openbsd'
        && `uname -m` eq "sparc64\n"
        # added in 2000 by commit cb434fcc98ac25f5:
        && extract_from_file('regexec.c',
                             qr!/\* No need to save/restore up to this paren \*/!)
        # re-indented in 2006 by commit 95b2444054382532:
        && extract_from_file('regexec.c', qr/^\t\tCURCUR cc;$/)) {
        # Need to work around a bug in (at least) OpenBSD's 4.6's sparc64 #
        # compiler ["gcc (GCC) 3.3.5 (propolice)"]. Between commits
        # 3ec562b0bffb8b8b (2002) and 1a4fad37125bac3e^ (2005) the darling thing
        # fails to compile any code for the statement cc.oldcc = PL_regcc;
        #
        # If you refactor the code to "fix" that, or force the issue using set
        # in the debugger, the stack smashing detection code fires on return
        # from S_regmatch(). Turns out that the compiler doesn't allocate any
        # (or at least enough) space for cc.
        #
        # Restore the "uninitialised" value for cc before function exit, and the
        # stack smashing code is placated.  "Fix" 3ec562b0bffb8b8b (which
        # changes the size of auto variables used elsewhere in S_regmatch), and
        # the crash is visible back to bc517b45fdfb539b (which also changes
        # buffer sizes). "Unfix" 1a4fad37125bac3e and the crash is visible until
        # 5b47454deb66294b.  Problem goes away if you compile with -O, or hack
        # the code as below.
        #
        # Hence this turns out to be a bug in (old) gcc. Not a security bug we
        # still need to fix.
        apply_patch(<<'EOPATCH');
diff --git a/regexec.c b/regexec.c
index 900b491..6251a0b 100644
--- a/regexec.c
+++ b/regexec.c
@@ -2958,7 +2958,11 @@ S_regmatch(pTHX_ regnode *prog)
 				I,I
  *******************************************************************/
 	case CURLYX: {
-		CURCUR cc;
+	    union {
+		CURCUR hack_cc;
+		char hack_buff[sizeof(CURCUR) + 1];
+	    } hack;
+#define cc hack.hack_cc
 		CHECKPOINT cp = PL_savestack_ix;
 		/* No need to save/restore up to this paren */
 		I32 parenfloor = scan->flags;
@@ -2983,6 +2987,7 @@ S_regmatch(pTHX_ regnode *prog)
 		n = regmatch(PREVOPER(next));	/* start on the WHILEM */
 		regcpblow(cp);
 		PL_regcc = cc.oldcc;
+#undef cc
 		saySAME(n);
 	    }
 	    /* NOT REACHED */
EOPATCH
}

    if ($major < 8 && $^O eq 'openbsd'
        && !extract_from_file('perl.h', qr/include <unistd\.h>/)) {
        # This is part of commit 3f270f98f9305540, applied at a slightly
        # different location in perl.h, where the context is stable back to
        # 5.000
        apply_patch(<<'EOPATCH');
diff --git a/perl.h b/perl.h
index 9418b52..b8b1a7c 100644
--- a/perl.h
+++ b/perl.h
@@ -496,6 +496,10 @@ register struct op *Perl_op asm(stringify(OP_IN_REGISTER));
 #   include <sys/param.h>
 #endif
 
+/* If this causes problems, set i_unistd=undef in the hint file.  */
+#ifdef I_UNISTD
+#   include <unistd.h>
+#endif
 
 /* Use all the "standard" definitions? */
 #if defined(STANDARD_C) && defined(I_STDLIB)
EOPATCH
    }
}

sub patch_ext {
    if (-f 'ext/POSIX/Makefile.PL'
        && extract_from_file('ext/POSIX/Makefile.PL',
                             qr/Explicitly avoid including/)) {
        # commit 6695a346c41138df, which effectively reverts 170888cff5e2ffb7

        # PERL5LIB is populated by make_ext.pl with paths to the modules we need
        # to run, don't override this with "../../lib" since that may not have
        # been populated yet in a parallel build.
        apply_commit('6695a346c41138df');
    }

    if ($major < 8 && $^O eq 'darwin' && !-f 'ext/DynaLoader/dl_dyld.xs') {
        checkout_file('ext/DynaLoader/dl_dyld.xs', 'f556e5b971932902');
        apply_patch(<<'EOPATCH');
diff -u a/ext/DynaLoader/dl_dyld.xs~ a/ext/DynaLoader/dl_dyld.xs
--- a/ext/DynaLoader/dl_dyld.xs~	2011-10-11 21:41:27.000000000 +0100
+++ b/ext/DynaLoader/dl_dyld.xs	2011-10-11 21:42:20.000000000 +0100
@@ -41,6 +41,35 @@
 #include "perl.h"
 #include "XSUB.h"
 
+#ifndef pTHX
+#  define pTHX		void
+#  define pTHX_
+#endif
+#ifndef aTHX
+#  define aTHX
+#  define aTHX_
+#endif
+#ifndef dTHX
+#  define dTHXa(a)	extern int Perl___notused(void)
+#  define dTHX		extern int Perl___notused(void)
+#endif
+
+#ifndef Perl_form_nocontext
+#  define Perl_form_nocontext form
+#endif
+
+#ifndef Perl_warn_nocontext
+#  define Perl_warn_nocontext warn
+#endif
+
+#ifndef PTR2IV
+#  define PTR2IV(p)	(IV)(p)
+#endif
+
+#ifndef get_av
+#  define get_av perl_get_av
+#endif
+
 #define DL_LOADONCEONLY
 
 #include "dlutils.c"	/* SaveError() etc	*/
@@ -185,7 +191,7 @@
     CODE:
     DLDEBUG(1,PerlIO_printf(Perl_debug_log, "dl_load_file(%s,%x):\n", filename,flags));
     if (flags & 0x01)
-	Perl_warn(aTHX_ "Can't make loaded symbols global on this platform while loading %s",filename);
+	Perl_warn_nocontext("Can't make loaded symbols global on this platform while loading %s",filename);
     RETVAL = dlopen(filename, mode) ;
     DLDEBUG(2,PerlIO_printf(Perl_debug_log, " libref=%x\n", RETVAL));
     ST(0) = sv_newmortal() ;
EOPATCH
        if ($major < 4 && !extract_from_file('util.c', qr/^form/m)) {
            apply_patch(<<'EOPATCH');
diff -u a/ext/DynaLoader/dl_dyld.xs~ a/ext/DynaLoader/dl_dyld.xs
--- a/ext/DynaLoader/dl_dyld.xs~	2011-10-11 21:56:25.000000000 +0100
+++ b/ext/DynaLoader/dl_dyld.xs	2011-10-11 22:00:00.000000000 +0100
@@ -60,6 +60,18 @@
 #  define get_av perl_get_av
 #endif
 
+static char *
+form(char *pat, ...)
+{
+    char *retval;
+    va_list args;
+    va_start(args, pat);
+    vasprintf(&retval, pat, &args);
+    va_end(args);
+    SAVEFREEPV(retval);
+    return retval;
+}
+
 #define DL_LOADONCEONLY
 
 #include "dlutils.c"	/* SaveError() etc	*/
EOPATCH
        }
    }

    if ($major < 10) {
        if (!extract_from_file('ext/DB_File/DB_File.xs',
                               qr!^#else /\* Berkeley DB Version > 2 \*/$!)) {
            # This DB_File.xs is really too old to patch up.
            # Skip DB_File, unless we're invoked with an explicit -Unoextensions
            if (!exists $defines{noextensions}) {
                $defines{noextensions} = 'DB_File';
            } elsif (defined $defines{noextensions}) {
                $defines{noextensions} .= ' DB_File';
            }
        } elsif (!extract_from_file('ext/DB_File/DB_File.xs',
                                    qr/^#ifdef AT_LEAST_DB_4_1$/)) {
            # This line is changed by commit 3245f0580c13b3ab
            my $line = extract_from_file('ext/DB_File/DB_File.xs',
                                         qr/^(        status = \(?RETVAL->dbp->open\)?\(RETVAL->dbp, name, NULL, RETVAL->type, $)/);
            apply_patch(<<"EOPATCH");
diff --git a/ext/DB_File/DB_File.xs b/ext/DB_File/DB_File.xs
index 489ba96..fba8ded 100644
--- a/ext/DB_File/DB_File.xs
+++ b/ext/DB_File/DB_File.xs
\@\@ -183,4 +187,8 \@\@
 #endif
 
+#if DB_VERSION_MAJOR > 4 || (DB_VERSION_MAJOR == 4 && DB_VERSION_MINOR >= 1)
+#    define AT_LEAST_DB_4_1
+#endif
+
 /* map version 2 features & constants onto their version 1 equivalent */
 
\@\@ -1334,7 +1419,12 \@\@ SV *   sv ;
 #endif
 
+#ifdef AT_LEAST_DB_4_1
+        status = (RETVAL->dbp->open)(RETVAL->dbp, NULL, name, NULL, RETVAL->type, 
+	    			Flags, mode) ; 
+#else
 $line
 	    			Flags, mode) ; 
+#endif
 	/* printf("open returned %d %s\\n", status, db_strerror(status)) ; */
 
EOPATCH
        }
    }

    if ($major < 10 and -f 'ext/IPC/SysV/SysV.xs') {
        edit_file('ext/IPC/SysV/SysV.xs', sub {
                      my $xs = shift;
                      my $fixed = <<'EOFIX';

#include <sys/types.h>
#if defined(HAS_MSG) || defined(HAS_SEM) || defined(HAS_SHM)
#ifndef HAS_SEM
#   include <sys/ipc.h>
#endif
#   ifdef HAS_MSG
#       include <sys/msg.h>
#   endif
#   ifdef HAS_SHM
#       if defined(PERL_SCO) || defined(PERL_ISC)
#           include <sys/sysmacros.h>	/* SHMLBA */
#       endif
#      include <sys/shm.h>
#      ifndef HAS_SHMAT_PROTOTYPE
           extern Shmat_t shmat (int, char *, int);
#      endif
#      if defined(HAS_SYSCONF) && defined(_SC_PAGESIZE)
#          undef  SHMLBA /* not static: determined at boot time */
#          define SHMLBA sysconf(_SC_PAGESIZE)
#      elif defined(HAS_GETPAGESIZE)
#          undef  SHMLBA /* not static: determined at boot time */
#          define SHMLBA getpagesize()
#      endif
#   endif
#endif
EOFIX
                      $xs =~ s!
#include <sys/types\.h>
.*
(#ifdef newCONSTSUB|/\* Required)!$fixed$1!ms;
                      return $xs;
                  });
    }
}

# Local variables:
# cperl-indent-level: 4
# indent-tabs-mode: nil
# End:
#
# ex: set ts=8 sts=4 sw=4 et:
