#!/usr/bin/env perl
use v5.34;
use warnings;

use HTTP::Tiny;

# Prints the Claude Code version each release channel currently points at.
# Each channel is a plain-text object in the release bucket holding a single
# version string, the same lookup download-claude-code.bash does to resolve a
# channel name.
#
# Usage: claude-code-versions.pl [CHANNEL...]   (defaults to stable latest)

my $base_url = $ENV{CLAUDE_CODE_RELEASES_BASE_URL}
    // 'https://storage.googleapis.com/claude-code-dist-86c565f3-f756-42ad-8dfa-d59b1c096819/claude-code-releases';

my ( $can_ssl, $ssl_reason ) = HTTP::Tiny->can_ssl;
if ( $base_url =~ /^https:/i && !$can_ssl ) {
    print STDERR "Error: HTTPS support unavailable: $ssl_reason";
    exit 1;
}

# HTTP::Tiny has a single inactivity timeout rather than curl's separate
# connect and total limits; it follows redirects by default, like curl -L.
my $http = HTTP::Tiny->new( timeout => 30 );

sub is_version {
    my ($v) = @_;
    return $v =~ /^[0-9]+\.[0-9]+\.[0-9]+(?:[.-][A-Za-z0-9.-]+)?\z/;
}

# Keep stdout and stderr lines in channel order when both go to a terminal.
STDOUT->autoflush(1);

my @channels = @ARGV ? @ARGV : qw(stable latest);

my $status = 0;
for my $channel (@channels) {
    if ( $channel !~ /^[a-z][a-z0-9-]*\z/ ) {
        print STDERR "Error: invalid channel name '$channel'.\n";
        $status = 1;
        next;
    }

    my $res = $http->get("$base_url/$channel");
    if ( !$res->{success} ) {
        print STDERR "Error: could not fetch channel '$channel'.\n";
        $status = 1;
        next;
    }
    ( my $version = $res->{content} ) =~ s/[\r\n\t ]//g;

    if ( !is_version($version) ) {
        print STDERR
            "Error: channel '$channel' resolved to invalid version '$version'.\n";
        $status = 1;
        next;
    }

    printf "%-8s %s\n", $channel, $version;
}

exit $status;
