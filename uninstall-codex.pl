#!/usr/bin/env perl
use v5.34;
use warnings;

use File::Path qw(remove_tree);
use POSIX qw(_exit);

# Removes a Codex CLI installed by install-codex.bash or install-codex.pl (or
# the official install.sh, which uses the same layout).
#
# By default this removes only what the installer created: the standalone
# package tree under ~/.codex/packages/standalone and the symlinks in
# ~/.local/bin. Your Codex config, credentials, and history in ~/.codex are
# left alone, because losing auth.json means signing in again. Pass --purge to
# delete all of ~/.codex as well.
#
# Usage: uninstall-codex.pl [--purge] [--dry-run] [--yes]

# Like the shell's ${VAR:-default}: the first value that is set and non-empty.
sub first_set {
    return ( grep { defined && length } @_ )[0];
}

my $bin_dir = first_set( $ENV{CODEX_INSTALL_DIR}, "$ENV{HOME}/.local/bin" );
my $codex_home      = first_set( $ENV{CODEX_HOME}, "$ENV{HOME}/.codex" );
my $standalone_root = "$codex_home/packages/standalone";

sub fail {
    print STDERR "Error: $_[0]\n";
    exit 1;
}

# Keep progress lines and errors in order when both go to a terminal.
STDOUT->autoflush(1);

# Prints the comment block above, without its leading "# ".
sub usage {
    open my $self, '<', $0 or fail("cannot read $0: $!");
    my $in_block = 0;
    while (<$self>) {
        next if $. == 1;    # the #! line
        if (/^#/) {
            s/^# ?//;
            print;
            $in_block = 1;
        }
        elsif ($in_block) {
            last;
        }
    }
}

my ( $purge, $dry_run, $assume_yes ) = ( 0, 0, 0 );
for my $arg (@ARGV) {
    if    ( $arg eq '--purge' )                    { $purge      = 1 }
    elsif ( $arg eq '--dry-run' || $arg eq '-n' )  { $dry_run    = 1 }
    elsif ( $arg eq '--yes'     || $arg eq '-y' )  { $assume_yes = 1 }
    elsif ( $arg eq '--help'    || $arg eq '-h' )  { usage(); exit 0 }
    else { fail("unknown argument '$arg'. See --help.") }
}

# Only remove links that point into the standalone tree; a codex installed by
# brew, npm, or bun is somebody else's to uninstall.
sub owned_link {
    my ($link) = @_;
    return 0 if !-l $link;
    return index( readlink($link) // '', "$standalone_root/" ) == 0;
}

# Runs a command without a shell, with its stderr discarded, and returns what
# it printed whether or not it succeeded.
sub output_of {
    my @command = @_;
    my $pid = open my $fh, '-|';
    return '' if !defined $pid;
    if ( !$pid ) {
        open STDERR, '>', '/dev/null';
        exec {$command[0]} @command or _exit(127);
    }
    my $output = do { local $/; <$fh> } // '';
    close $fh;
    return $output;
}

my @targets;
for my $link ( "$bin_dir/codex", "$bin_dir/codex-code-mode-host" ) {
    if ( owned_link($link) ) {
        push @targets, $link;
    }
    elsif ( -e $link ) {
        say "Leaving $link alone: it was not created by install-codex.bash.";
    }
}

if ($purge) {
    push @targets, $codex_home if -e $codex_home;
}
elsif ( -e $standalone_root ) {
    push @targets, $standalone_root;
}

if ( !@targets ) {
    say 'Nothing to remove; no Codex standalone install found.';
    exit 0;
}

# The version is the last word codex --version prints, as awk '{print $NF}'
# takes it from each line.
my $version = join "\n", map { ( split ' ' )[-1] // '' } split /\n/,
    output_of( "$standalone_root/current/bin/codex", '--version' );
say "Found Codex CLI $version" if $version ne '';

say 'The following will be removed:';
for my $target (@targets) {
    if ( -l $target ) {
        say "  $target -> ", readlink($target) // '';
    }
    else {
        # du's own size formatting, which differs between GNU and BSD.
        my ($size) = split /\t/, output_of( 'du', '-sh', $target );
        say "  $target  (", $size // '', ')';
    }
}
say '  (--purge: this includes your Codex config, credentials, and history)'
    if $purge;

if ($dry_run) {
    say '';
    say 'Dry run; nothing was removed.';
    exit 0;
}

if ( !$assume_yes ) {

    # Like read -p, the prompt goes to stderr and only when a person is
    # answering it.
    print STDERR 'Remove these? [y/N] ' if -t STDIN;
    my $answer = <STDIN> // '';
    $answer =~ s/^\s+|\s+\z//g;
    if ( $answer !~ /^(?:y|Y|yes|YES)\z/ ) {
        say 'Aborted; nothing was removed.';
        exit 1;
    }
}

for my $target (@targets) {
    remove_tree( $target, { error => \my $errors } );
    if (@$errors) {
        my ( $path, $why ) = %{ $errors->[0] };
        fail( "cannot remove " . ( $path || $target ) . ": $why" );
    }
    say "Removed $target";
}

# Without --purge the packages/ directory is left behind empty; tidy it up, but
# only if nothing else moved in there.
rmdir "$codex_home/packages";

# The official install.sh appends a PATH block to a shell profile. Point at it
# rather than editing the file, since people often add their own lines nearby.
for my $profile ( map {"$ENV{HOME}/$_"}
    qw(.zshrc .zprofile .bashrc .bash_profile .profile) )
{
    next if !-f $profile || !open my $fh, '<', $profile;
    next if !grep { index( $_, '# >>> Codex installer >>>' ) >= 0 } <$fh>;
    say "Note: $profile still has a Codex installer PATH block;",
        ' remove it by hand.';
}

# Like command -v, the first codex on $PATH, an empty entry meaning the
# current directory.
my ($remaining) =
    grep { -f && -x } map { ( length ? $_ : '.' ) . '/codex' }
    split /:/, $ENV{PATH} // '', -1;
say "Note: another codex is still on your PATH at $remaining"
    if defined $remaining;
