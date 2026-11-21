#!/usr/bin/env perl
use v5.34;
use warnings;

use Digest::SHA;
use File::Path qw(make_path);
use HTTP::Tiny;
use JSON::PP;
use Time::Local qw(timegm);

# Mirrors the OpenAI Codex CLI standalone package archives. The official
# install.sh resolves a release, downloads one codex-package-<target>.tar.gz
# for the current platform, and unpacks it into ~/.codex. This downloads the
# package archive for every platform into codex-<version>/ and verifies each
# against the SHA256 digest the release metadata advertises.
#
# Usage: download-codex.pl [VERSION]   (VERSION defaults to latest)

# Like the shell's ${VAR:-default}: the first value that is set and non-empty.
sub first_set {
    return ( grep { defined && length } @_ )[0];
}

my $version_input = first_set( $ARGV[0], $ENV{CODEX_RELEASE}, 'latest' );
my $base_url      = first_set( $ENV{CODEX_RELEASES_BASE_URL},
    'https://releases.openai.com/codex' );

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
# connect and total limits. Metadata requests follow redirects like curl -L;
# archive downloads follow them by hand so each hop can be held to HTTPS.
my $api = HTTP::Tiny->new( timeout => 30, verify_SSL => 1 );
my $dl  = HTTP::Tiny->new(
    timeout      => 30,
    verify_SSL   => 1,
    max_redirect => 0,
    SSL_options  => { SSL_version => 'SSLv23:!SSLv2:!SSLv3:!TLSv1:!TLSv1_1' },
);
my $json = JSON::PP->new;

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

# The metadata value as jq -r '... // empty' prints it: scalars as text,
# anything missing or null as the empty string.
sub text_of {
    my ($value) = @_;
    return defined $value && !ref $value ? "$value" : '';
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

# Accept latest, x.y.z, and pre-releases, with or without a rust-v / v prefix.
( my $version = $version_input ) =~ s/^rust-v//;
$version =~ s/^v//;
fail(
    "invalid version '$version_input'. Expected latest or x.y.z[-alpha|-beta]."
    )
    if $version ne 'latest'
    && $version !~
    /^[0-9]+\.[0-9]+\.[0-9]+(?:-alpha(?:\.[0-9]+){0,2}|-beta(?:\.[0-9]+)?)?\z/;

my $metadata_url =
    $version eq 'latest'
    ? "$base_url/channels/latest"
    : "$base_url/releases/$version/release.json";

say "Fetching release metadata ($version)...";
my $metadata = eval { $json->decode( get_text($metadata_url) ) };
fail("release metadata for $version is not a JSON object.")
    if ref $metadata ne 'HASH';

# tag_name looks like rust-v0.147.0; the release version is the part after it.
my $tag = text_of( $metadata->{tag_name} );
( my $VERSION = $tag ) =~ s/^rust-v//;
fail("could not resolve version from metadata (tag '$tag').")
    if $VERSION !~ /^[0-9]+\.[0-9]+\.[0-9]+/;
fail("metadata version $VERSION does not match requested $version.")
    if $version ne 'latest' && $VERSION ne $version;

# Mirror every codex-package-<target>.tar.gz the release publishes (a
# self-contained package: codex plus the codex-code-mode-host, rg, and — on
# Linux — bwrap helpers). Deriving the list from the release means newly added
# targets are picked up automatically instead of silently going unmirrored.
# The first asset of each name wins, as the bash script's lookup does.
my %assets;
for my $entry ( ref $metadata->{assets} eq 'ARRAY' ? @{ $metadata->{assets} } : () )
{
    next if ref $entry ne 'HASH';
    my $name = text_of( $entry->{name} );
    $assets{$name} //= $entry
        if $name =~ /^codex-package-.+\.tar\.gz\z/s;
}
my @targets = sort map { /^codex-package-(.+)\.tar\.gz\z/s } keys %assets;
fail('release publishes no codex-package archives.') if !@targets;

printf "Mirroring %d targets...\n", scalar @targets;

my $outdir = "codex-$VERSION";
make_path($outdir);
chdir $outdir or fail("cannot cd to $outdir: $!");

my $sums_file = "codex-$VERSION-SHA256SUMS.txt";
open my $sums, '>', $sums_file or fail("cannot write $sums_file: $!");
$sums->autoflush(1);

for my $target (@targets) {
    my $asset  = "codex-package-$target.tar.gz";
    my $url    = text_of( $assets{$asset}{browser_download_url} );
    my $digest = text_of( $assets{$asset}{digest} ) =~ s/^sha256://r;
    fail("bad digest for $asset.") if $digest !~ /^[0-9a-f]{64}\z/;

    say "[$target] $asset";

    # Skip only when the existing file already matches the advertised digest.
    if ( -f $asset && sha256_of($asset) eq $digest ) {
        say '  already complete, skipping';
        print {$sums} "$digest  $asset\n";
        next;
    }

    download( $url, $asset );

    my $actual = sha256_of($asset);
    if ( $actual ne $digest ) {
        print STDERR "Error: checksum mismatch for $asset\n",
            "  expected $digest\n",
            "  actual   $actual\n",
            "  delete the file and re-run to download it fresh.\n";
        exit 1;
    }
    say "  verified $digest";
    print {$sums} "$digest  $asset\n";
}

close $sums or fail("cannot write $sums_file: $!");

say '';
say "SHA256 sums written to $outdir/$sums_file";
open $sums, '<', $sums_file or fail("cannot read $sums_file: $!");
print while <$sums>;
close $sums;
