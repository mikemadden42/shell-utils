#!/usr/bin/env perl
use v5.34;
use warnings;

use Digest::SHA;

# Writes a <name>.sha256 next to each archive in the current directory that
# does not have one yet, in the format sha256sum prints and sha256sum -c
# reads.

# The line sha256sum writes for $file. Like GNU coreutils, a name holding a
# backslash, newline or carriage return is escaped and the line marked with a
# leading backslash, so the result still reads back one entry per line.
sub sums_line {
    my ( $digest, $file ) = @_;
    my %escape = ( "\\" => "\\\\", "\n" => "\\n", "\r" => "\\r" );
    return "$digest  $file\n" if $file !~ /[\\\n\r]/;
    ( my $name = $file ) =~ s/([\\\n\r])/$escape{$1}/g;
    return "\\$digest  $name\n";
}

# Keep progress lines and errors in order when both go to a terminal.
STDOUT->autoflush(1);

my $status = 0;

# Each pattern is expanded and sorted on its own, in this order, as the shell
# does with for i in *.tar *.tgz *.txz *.zip.
for my $file ( map { glob } qw(*.tar *.tgz *.txz *.zip) ) {
    next if !-e $file;
    next if -f "$file.sha256";

    say "Creating sha256 for '$file'...";

    # Hash first and write after, so a file that cannot be read leaves no
    # empty .sha256 behind to be mistaken for a finished one on the next run.
    # Digest::SHA reports an open or read failure by dying, with the reason
    # in the message rather than $!.
    my $digest =
        eval { Digest::SHA->new(256)->addfile( $file, 'b' )->hexdigest };
    if ( !defined $digest ) {
        ( my $why = $@ ) =~ s/ at \S+ line \d+\.\n\z//;
        $why =~ s/^\w+ failed: //;
        print STDERR "Error: cannot read $file: $why\n";
        $status = 1;
        next;
    }

    my $written = open my $fh, '>', "$file.sha256";
    $written &&= print {$fh} sums_line( $digest, $file );
    $written &&= close $fh;
    if ( !$written ) {
        print STDERR "Error: cannot write $file.sha256: $!\n";
        $status = 1;
    }
}

exit $status;
