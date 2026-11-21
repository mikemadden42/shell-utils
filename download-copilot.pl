#!/usr/bin/env perl
use v5.34;
use warnings;

use Digest::SHA;
use File::Path qw(make_path);
use HTTP::Tiny;
use Time::Local qw(timegm);

# Mirrors the GitHub Copilot CLI standalone builds. The release publishes each
# platform as a copilot-<platform>.<ext> archive plus a Windows .msi, and a
# SHA256SUMS.txt covering them. This downloads every copilot-* asset into
# copilot-cli-<version>/ and verifies each against that file.
#
# The release also ships github-copilot-<version>-*.tgz npm packages, which
# repackage the same builds for a different channel; those are listed in
# SHA256SUMS.txt but deliberately not mirrored here, the way download-codex.pl
# mirrors only the package archives.
#
# Usage: download-copilot.pl [VERSION]   (VERSION defaults to latest)

# Like the shell's ${VAR:-default}: the first value that is set and non-empty.
sub first_set {
    return ( grep { defined && length } @_ )[0];
}

my $repo_url = first_set( $ENV{COPILOT_REPO_URL},
    'https://github.com/github/copilot-cli' );
my $version_input = first_set( $ARGV[0], $ENV{COPILOT_VERSION}, 'latest' );

my $max_redirects  = 3;
my $retries        = 3;
my $retry_delay    = 2;
my $progress_width = 50;

sub fail {
    print STDERR "Error: $_[0]\n";
    exit 1;
}

my ( $can_ssl, $ssl_reason ) = HTTP::Tiny->can_ssl;
fail("HTTPS support unavailable: $ssl_reason") if !$can_ssl;

# HTTP::Tiny has a single inactivity timeout rather than curl's separate
# connect and total limits. Text requests follow redirects like curl -L;
# downloads follow them by hand so each hop can be held to HTTPS.
my $api = HTTP::Tiny->new( timeout => 30, verify_SSL => 1 );
my $dl  = HTTP::Tiny->new(
    timeout      => 30,
    verify_SSL   => 1,
    max_redirect => 0,
    SSL_options  => { SSL_version => 'SSLv23:!SSLv2:!SSLv3:!TLSv1:!TLSv1_1' },
);

# Keep progress lines and errors in order when both go to a terminal.
STDOUT->autoflush(1);

sub sha256_of {
    my ($file) = @_;
    return Digest::SHA->new(256)->addfile( $file, 'b' )->hexdigest;
}

sub describe {
    my ($res) = @_;

    # Status 599 is HTTP::Tiny's own connection or TLS error; the detail is in
    # the content.
    return $res->{status} == 599
        ? ( split /\n/, $res->{content} // '' )[0] // 'connection failed'
        : "$res->{status} $res->{reason}";
}

sub get_text {
    my ($url) = @_;
    my $res = $api->get($url);
    fail( "could not fetch $url: " . describe($res) ) if !$res->{success};
    return $res->{content};
}

# Seconds since the epoch for an RFC 1123 date such as a Last-Modified header.
sub http_date {
    my ($date) = @_;
    my %month;
    @month{qw(Jan Feb Mar Apr May Jun Jul Aug Sep Oct Nov Dec)} = 0 .. 11;
    my ( $d, $mon, $y, $h, $m, $s ) =
        ( $date // '' )
        =~ /^\w{3}, (\d\d) (\w{3}) (\d{4}) (\d\d):(\d\d):(\d\d) GMT\z/
        or return;
    return if !exists $month{$mon};
    return timegm( $s, $m, $h, $d, $month{$mon}, $y );
}

sub absolute_url {
    my ( $location, $base ) = @_;
    return $location if $location =~ m{^[A-Za-z][A-Za-z0-9+.-]*://};
    my ( $scheme, $authority, $path ) =
        $base =~ m{^([^:]+)://([^/?#]+)([^?#]*)};
    return "$scheme:$location"             if $location =~ m{^//};
    return "$scheme://$authority$location" if $location =~ m{^/};
    ( my $dir = $path ) =~ s{[^/]*\z}{};
    return "$scheme://$authority" . ( length $dir ? $dir : '/' ) . $location;
}

# The full length of the file a response is delivering: the total from a
# Content-Range on a resumed download, otherwise the Content-Length.
sub total_size {
    my ($res) = @_;
    my $range = $res->{headers}{'content-range'} // '';
    return $1 if $range =~ m{/([0-9]+)\s*\z};
    my $length = $res->{headers}{'content-length'} // '';
    return $length =~ /^[0-9]+\z/ ? $length : 0;
}

# Draws a curl --progress-bar style bar on a terminal.
sub show_progress {
    my ( $done, $total ) = @_;
    return if !-t STDERR || !$total;
    my $fraction = $done / $total;
    $fraction = 1 if $fraction > 1;
    my $filled = int( $fraction * $progress_width );
    printf STDERR "\r%s%s %5.1f%%", '#' x $filled,
        ' ' x ( $progress_width - $filled ), 100 * $fraction;
}

# One attempt at fetching $url into $file, resuming from whatever is already
# there like curl -C -. Returns undef on success, or a message and whether the
# failure is worth retrying.
sub fetch_once {
    my ( $url, $file ) = @_;
    my $offset = -s $file // 0;

    return ( "refusing to fetch non-HTTPS URL $url", 0 )
        if $url !~ m{^https://}i;
    open my $fh, '>>:raw', $file or fail("cannot write $file: $!");
    my %headers = $offset ? ( Range => "bytes=$offset-" ) : ();

    for ( my $hops = 0;; $hops++ ) {
        return ( "refusing to follow non-HTTPS URL $url", 0 )
            if $url !~ m{^https://}i;

        my $written = $offset;
        my $started = 0;
        my $total   = 0;
        my $res     = $dl->request(
            'GET', $url,
            {   headers       => \%headers,
                data_callback => sub {
                    my ( $chunk, $res ) = @_;
                    if ( !$started++ ) {

                        # A 200 is the whole file, so the server has ignored
                        # the range and the partial copy is dropped.
                        if ( $res->{status} == 200 && $written ) {
                            truncate $fh, 0
                                or fail("cannot truncate $file: $!");
                            $written = 0;
                        }
                        $total = total_size($res);
                        $total += $written
                            if $total && $res->{status} == 206
                            && !defined $res->{headers}{'content-range'};
                    }
                    print {$fh} $chunk or fail("cannot write $file: $!");
                    $written += length $chunk;
                    show_progress( $written, $total );
                },
            }
        );
        print STDERR "\n" if $started && -t STDERR;

        my $status = $res->{status};
        if ( $status =~ /^3/ && defined $res->{headers}{location} ) {
            return ( "too many redirects fetching $url", 0 )
                if $hops >= $max_redirects;
            $url = absolute_url( $res->{headers}{location}, $url );
            next;
        }

        if ( $res->{success} ) {
            close $fh or fail("cannot write $file: $!");
            if ( my $mtime = http_date( $res->{headers}{'last-modified'} ) ) {
                utime $mtime, $mtime, $file;
            }
            return;
        }

        # Nothing left to fetch: the file is already as long as the remote
        # copy, so the checksum check decides whether it is good.
        return if $status == 416 && $offset;

        my $retry =
               $status == 599
            || $status == 408
            || $status == 429
            || $status =~ /^5/;
        return ( "download of $url failed: " . describe($res), $retry );
    }
}

# Fetches with up to $retries retries on transient failures, like curl --retry.
sub download {
    my ( $url, $file ) = @_;
    for my $attempt ( 0 .. $retries ) {
        my ( $error, $retry ) = fetch_once( $url, $file );
        return       if !defined $error;
        fail($error) if !$retry || $attempt == $retries;
        print STDERR "  $error; retrying in ${retry_delay}s...\n";
        sleep $retry_delay;
    }
}

# Splits a "<sha256>  [*]<name>" line the way the bash script's read -r does,
# dropping the binary-mode marker and a CRLF line ending. Returns the hash and
# name, or nothing for a blank line.
sub sums_entry {
    my ($line) = @_;
    my ( $hash, $name ) = $line =~ /^[ \t]*([^ \t\n]*)[ \t]*(.*?)[ \t]*\n?\z/s;
    return if $hash eq '';
    $name =~ s/^\*//;
    $name =~ s/\r\z//;
    return ( $hash, $name );
}

# Resolve the release tag. /releases/latest redirects to /releases/tag/<tag>,
# which avoids the GitHub API and its unauthenticated rate limit.
my $tag;
if ( $version_input eq 'latest' ) {
    say "Resolving latest release from $repo_url...";
    my $res = $api->get("$repo_url/releases/latest");
    fail( "could not fetch $repo_url/releases/latest: " . describe($res) )
        if !$res->{success};
    my $effective = $res->{url};
    ($tag) = $effective =~ m{.*/tag/(.*)}s;
    fail("could not resolve the latest tag from '$effective'.")
        if !defined $tag || $tag eq '';
}
else {
    $tag = 'v' . $version_input =~ s/^v//r;
}

( my $VERSION = $tag ) =~ s/^v//;
fail("invalid version '$version_input' (tag '$tag').")
    if $VERSION !~ /^[0-9]+\.[0-9]+\.[0-9]+(?:[.-][A-Za-z0-9.-]+)?\z/;

my $base = "$repo_url/releases/download/$tag";

my $outdir = "copilot-cli-$VERSION";
make_path($outdir);
chdir $outdir or fail("cannot cd to $outdir: $!");

say "Fetching SHA256SUMS.txt for $tag...";
my $listing = get_text("$base/SHA256SUMS.txt");
open my $fh, '>:raw', 'SHA256SUMS.txt'
    or fail("cannot write SHA256SUMS.txt: $!");
print {$fh} $listing;
close $fh or fail("cannot write SHA256SUMS.txt: $!");
fail('SHA256SUMS.txt is empty or missing.') if $listing eq '';

my $sums_file = "copilot-cli-$VERSION-SHA256SUMS.txt";
open my $sums, '>', $sums_file or fail("cannot write $sums_file: $!");
$sums->autoflush(1);

# SHA256SUMS.txt drives the mirror: one "<sha256>  [*]<name>" line per asset.
my $mirrored = 0;
for my $line ( split /^/m, $listing ) {
    my ( $hash, $name ) = sums_entry($line) or next;
    fail("malformed SHA256SUMS.txt line for '$name'.")
        if $hash !~ /^[0-9a-f]{64}\z/;

    # Standalone builds only; github-copilot-*.tgz are the npm channel.
    next if $name !~ /^copilot-/;

    say "[$name]";

    # Skip only when the existing file already matches the advertised digest.
    if ( -f $name && sha256_of($name) eq $hash ) {
        say '  already complete, skipping';
        print {$sums} "$hash  $name\n";
        $mirrored++;
        next;
    }

    download( "$base/$name", $name );

    my $actual = sha256_of($name);
    if ( $actual ne $hash ) {
        print STDERR "Error: checksum mismatch for $name\n",
            "  expected $hash\n",
            "  actual   $actual\n",
            "  delete the file and re-run to download it fresh.\n";
        exit 1;
    }
    say "  verified $hash";
    print {$sums} "$hash  $name\n";
    $mirrored++;
}

close $sums or fail("cannot write $sums_file: $!");
fail('SHA256SUMS.txt listed no copilot-* assets.') if !$mirrored;

say '';
say "Mirrored $mirrored assets; SHA256 sums written to $outdir/$sums_file";
open $sums, '<', $sums_file or fail("cannot read $sums_file: $!");
print while <$sums>;
close $sums;
