package App::Tangerine;
# ABSTRACT: Perl dependency metadata tool
use 5.010;
use strict;
use warnings;
use App::Tangerine::Metadata;

use Archive::Extract;
use Cwd;
use File::Find::Rule;
use File::Find::Rule::Perl;
use File::Temp;
use File::Spec;
use Getopt::Long;
use List::Compare;
use MCE::Map;
use Pod::Usage;
use Tangerine;

my %flags = (
    jobs => 'auto',
    mode => 'all',
);

sub init {
    GetOptions
        all  =>     \$flags{all},
        compact =>  \$flags{compact},
        diff =>     \$flags{diff},
        files =>    \$flags{files},
        'jobs=i' => \$flags{jobs},
        help =>     \$flags{help},
        'mode=s' => \$flags{mode},
        verbose =>  \$flags{verbose};
    my %p2uargs = (
        -sections => 'SYNOPSIS|OPTIONS|EXAMPLES',
        -verbose => 99);
    unless (scalar(@ARGV)) {
        pod2usage(-message => "Nothing to examine.\n",
            -exitval => 1,
            %p2uargs)
    }
    if ($flags{diff} && scalar(@ARGV) != 2) {
        pod2usage(-message => "The diff option requires two arguments.\n",
            -exitval => 2,
            %p2uargs)
    }
    if ($flags{diff} && !(-e $ARGV[0] && -e $ARGV[1])) {
        pod2usage(-message => "Cannot compute difference: No such file or directory.\n",
            -exitval => 3,
            %p2uargs)
    }
    if ($flags{mode} &&
        $flags{mode} !~ m/^(compile|u(se)?|runtime|r(eq)?|package|p(rov)?|a(ll)?)$/) {
        pod2usage(-message => "Incorrect mode specified.\n",
            -exitval => 4,
            %p2uargs)
    }
    if ($flags{jobs} && $flags{jobs} !~ m/^(auto|\d+)$/) {
        pod2usage(-message => "The number of jobs must be a positive numeric value.\n",
            -exitval => 5,
            %p2uargs)
    }
    if ($flags{help}) {
        pod2usage(%p2uargs);
    }
    if ($flags{compact} && $flags{mode} ne 'all') {
        print { *STDERR }
            "Compact mode enabled.  Setting mode to `all'...\n";
        $flags{mode} = 'all'
    }
    if ($flags{compact} && $flags{files}) {
        print { *STDERR }
            "Compact and files modes are incompatible.  Ignoring files...\n";
        $flags{files} = undef
    }
    MCE::Map::init {
        max_workers => ($flags{jobs} // 'auto'),
        chunk_size => 1
    };
    adjustmode() if $flags{mode};
}

sub finish {
    MCE::Map::finish;
}

sub adjustmode {
    no warnings 'uninitialized';
    if ($Tangerine::VERSION < 0.15) {
        $flags{mode} = 'u' if $flags{mode} =~ m/^(compile|use)$/;
        $flags{mode} = 'r' if $flags{mode} =~ m/^(runtime|req)$/;
        $flags{mode} = 'p' if $flags{mode} =~ m/^(package|prov)$/;
    }
}

 
sub analyze {
    mce_map {
        my @meta;
        my $file = $_;
        my $scanner = Tangerine->new(file => $file, mode => $flags{mode});
        $scanner->run;
        my %metameta = (
            p => $scanner->provides,
            c => $scanner->uses,
            r => $scanner->requires
        );
        for my $metatype (keys %metameta) {
            for my $mod (keys %{$metameta{$metatype}}) {
                for my $occurence (@{$metameta{$metatype}->{$mod}}) {
                    push @meta, App::Tangerine::Metadata->new(
                        name => $mod,
                        type => $metatype,
                        file => $file,
                        line => $occurence->line,
                        version => $occurence->version
                    );
                }
            }
        }
        @meta
    } @_
}

sub gatherfiles {
    my @files;
    my $findrule = $flags{all} ?
        File::Find::Rule->file:
        File::Find::Rule->perl_file;
    for my $arg (@_) {
        if (-d $arg) {
            push @files, $findrule->in($arg);
        } elsif (-f $arg) {
            push @files, $arg
        } else {
            print { *STDERR } "Cannot access `$arg': No such file or directory\n"
        }
    }
    @files
}

sub sortmetadata {
    ...
}

sub extract {
    my ($archive, $destination) = @_;
    my $ae = Archive::Extract->new(archive => $archive);
    eval {
        $ae->extract(to => $destination);
    };
    if ($@) {
        print { *STDERR } "Failed to extract `$archive' to `$destination'.";
        return;
    }
    return $ae->files;
}

sub analyzedir {
    my $dir = shift;
    my $olddir = getcwd();
    chdir $dir;
    my @meta = analyze(gatherfiles(File::Spec->canonpath('./')));
    chdir $olddir;
    return @meta
}

sub analyzearchive {
    my $archive = shift;
    my $olddir = getcwd();
    my $tmpdir = File::Temp->newdir('tangerine-XXXXXX',
        DIR => File::Spec->tmpdir());
    my $files = extract($archive, $tmpdir->dirname) or exit 100;
    chdir File::Spec->catfile($tmpdir->dirname, $files->[0]);
    my @meta = analyze(gatherfiles(File::Spec->canonpath('./')));
    chdir $olddir;
    return @meta
}

sub run {
    init();
    if ($flags{diff}) {
        my (@m1, @m2);
        @m1 = -d $ARGV[0] ? analyzedir($ARGV[0]) : analyzearchive($ARGV[0]);
        @m2 = -d $ARGV[1] ? analyzedir($ARGV[1]) : analyzearchive($ARGV[1]);
        my $lc = List::Compare->new(\@m1, \@m2);
        @m1 = map { assemblemd($_) } $lc->get_unique;
        @m2 = map { assemblemd($_) } $lc->get_complement;
        my @files;
        {
            my %tmpfiles;
            $tmpfiles{$_->file} = 1 for (@m1, @m2);
            @files = keys %tmpfiles
        }
        for my $file (sort @files) {
            print $file."\n";
            for (@m1) {
                print "\t- ".formattype($_->type).' '.$_->name."\n"
                    if $_->file eq $file
            }
            for (@m2) {
                print "\t+ ".formattype($_->type).' '.$_->name."\n"
                    if ($_->file eq $file);
            }
        }
    } else {
        my @meta = analyze(gatherfiles(@ARGV));
        if ($flags{files}) {
            my $lastfile = '';
            for my $md (sort {
                lc($a->file) cmp lc($b->file) ||
                ($a->type eq 'p' ? -1 :
                ($b->type eq 'p' ? 1 :
                $a->type cmp $b->type)) ||
                lc($a->name) cmp lc($b->name) ||
                $a->line <=> $b->line
                } @meta) {
                if ($md->file ne $lastfile) {
                    print $md->file."\n";
                    $lastfile = $md->file
                }
                print "\t".
                    formattype($md->type).
                    ' '.$md->name.
                    ' [#'.$md->line.']'.
                    ($md->version ? ' [v'.$md->version.']' : '').
                    "\n";
            }
        } else {
            my $lastname = '';
            my $skip = '';
            for my $md (sort {
                lc($a->name) cmp lc($b->name) ||
                ($a->type eq 'p' ? -1 :
                ($b->type eq 'p' ? 1 :
                $a->type cmp $b->type)) ||
                lc($a->file) cmp lc($b->file) ||
                $a->line <=> $b->line
                } @meta) {
                next if $md->name eq $skip;
                if ($md->name ne $lastname) {
                    $lastname = $md->name;
                    if ($flags{compact} && $md->type eq 'p') {
                        $skip = $md->name;
                        next
                    }
                    print $md->name."\n";
                }
                print "\t".
                    formattype($md->type).
                    ' '.$md->file.
                    ':'.$md->line.
                    ($md->version ? ' [v'.$md->version.']' : '').
                    "\n";
            }
        }
    }
    finish();
}

sub formattype {
    my $type = shift;
    return 'PACKAGE' if $type eq 'p';
    return 'COMPILE' if $type eq 'c';
    return 'RUNTIME' if $type eq 'r';
}

sub assemblemd {
    my ($t, $n, $f) = split /\0/, shift;
    App::Tangerine::Metadata->new(type => $t, name => $n, file => $f)
}

1;
