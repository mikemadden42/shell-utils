#!/usr/bin/env perl
use v5.34;
use warnings;

use HTTP::Tiny;
use JSON::PP;

# Prints the Codex CLI version each release channel currently points at.
# Each channel is a release-metadata JSON document on releases.openai.com; the
# version is its tag_name without the rust-v prefix, the same lookup
# download-codex.bash does for latest.
#
# latest is the current stable release. prerelease tracks the newest alpha; it
# is not documented and the official install.sh never reads it, so it may move
# or disappear.
#
# Usage: codex-versions.pl [CHANNEL...]   (defaults to latest prerelease)

# Like the shell's ${VAR:-default}, an empty variable falls back too.
my $base_url = $ENV{CODEX_RELEASES_BASE_URL}
    || 'https://releases.openai.com/codex';

my ( $can_ssl, $ssl_reason ) = HTTP::Tiny->can_ssl;
if ( $base_url =~ /^https:/i && !$can_ssl ) {
    print STDERR "Error: HTTPS support unavailable: $ssl_reason";
    exit 1;
}

# HTTP::Tiny has a single inactivity timeout rather than curl's separate
# connect and total limits; it follows redirects by default, like curl -L.
# Certificates are checked explicitly, since HTTP::Tiny 0.076 (Perl 5.34)
# skips that unless verify_SSL is set.
my $http = HTTP::Tiny->new( timeout => 30, verify_SSL => 1 );
my $json = JSON::PP->new;

sub is_version {
    my ($v) = @_;
    return $v =~ /^[0-9]+\.[0-9]+\.[0-9]+(?:-[A-Za-z0-9.]+)?\z/;
}

# Returns the metadata's tag_name, or the empty string when the document is
# not a JSON object with a plain tag_name value.
sub tag_name {
    my ($metadata) = @_;
    my $doc = eval { $json->decode($metadata) };
    return '' if ref $doc ne 'HASH';
    my $tag = $doc->{tag_name};
    return defined $tag && !ref $tag ? $tag : '';
}

# Keep stdout and stderr lines in channel order when both go to a terminal.
STDOUT->autoflush(1);

my @channels = @ARGV ? @ARGV : qw(latest prerelease);

my $status = 0;
for my $channel (@channels) {
    if ( $channel !~ /^[a-z][a-z0-9-]*\z/ ) {
        print STDERR "Error: invalid channel name '$channel'.\n";
        $status = 1;
        next;
    }

    my $res = $http->get("$base_url/channels/$channel");
    if ( !$res->{success} ) {
        print STDERR "Error: could not fetch channel '$channel'.\n";
        $status = 1;
        next;
    }

    # tag_name looks like rust-v0.154.0; the release version is the part after
    # it.
    my $tag = tag_name( $res->{content} );
    ( my $version = $tag ) =~ s/^rust-v//;

    if ( $tag !~ /^rust-v/ || !is_version($version) ) {
        print STDERR
            "Error: channel '$channel' resolved to invalid tag '$tag'.\n";
        $status = 1;
        next;
    }

    printf "%-11s %s\n", $channel, $version;
}

exit $status;
