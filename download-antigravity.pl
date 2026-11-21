#!/usr/bin/env perl
use v5.34;
use warnings;

use Digest::SHA;
use File::Path qw(make_path);
use HTTP::Tiny;
use JSON::PP;
use Time::Local qw(timegm);

# Mirrors the Antigravity CLI ("agy") native builds. The official install.sh
# reads a per-platform manifest (version, url, sha512) from the Cloud Run
# auto-updater, downloads that platform's artifact, and installs it as agy.
# This walks every platform manifest and downloads each artifact into
# antigravity-<version>/, verifying it against the manifest's SHA512.
#
# The manifests only ever describe the current latest release; there is no
# versioned manifest endpoint, so this always mirrors latest.

# Like the shell's ${VAR:-default}: the first value that is set and non-empty.
sub first_set {
    return ( grep { defined && length } @_ )[0];
}

my $base_url = first_set( $ENV{ANTIGRAVITY_BASE_URL},
    'https://antigravity-cli-auto-updater-974169037036.us-central1.run.app' );

# Platform manifests to mirror. There is no index endpoint, so this list is
# the full namespace the official installers can request: install.sh builds
# darwin_<arch>, linux_<arch>, and linux_<arch>_musl when it detects musl;
# install.ps1 builds windows_<arch>. Both only ever emit amd64 or arm64.
#
# The musl manifests 404 today (Antigravity publishes glibc-only Linux builds),
# which the resolve loop reports and skips. They are listed anyway so that if
# musl builds do appear they get mirrored without a code change.
my @PLATFORMS = qw(
    darwin_amd64
    darwin_arm64
    linux_amd64
    linux_arm64
    linux_amd64_musl
    linux_arm64_musl
    windows_amd64
    windows_arm64
);

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
# artifact downloads follow them by hand so each hop can be held to HTTPS.
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

sub sha512_of {
    my ($file) = @_;
    return Digest::SHA->new(512)->addfile( $file, 'b' )->hexdigest;
}

sub describe {
    my ($res) = @_;

    # Status 599 is HTTP::Tiny's own connection or TLS error; the detail is in
    # the content.
    return $res->{status} == 599
        ? ( split /\n/, $res->{content} // '' )[0] // 'connection failed'
        : "$res->{status} $res->{reason}";
}

# The manifest value as jq -r '... // empty' prints it: scalars as text,
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

# Resolve every manifest first so the output directory can be named for the
# version before any large download starts.
my $VERSION = '';
my @artifacts;
say "Fetching manifests from $base_url...";
for my $platform (@PLATFORMS) {

    # A missing manifest is expected, and this loop reports it itself, so
    # there is no separate error for the failed request.
    my $res = $api->get("$base_url/manifests/$platform.json");
    if ( !$res->{success} ) {
        say "  [$platform] manifest unavailable, skipping";
        next;
    }
    my $manifest = eval { $json->decode( $res->{content} ) };
    $manifest = {} if ref $manifest ne 'HASH';
    my $ver    = text_of( $manifest->{version} );
    my $url    = text_of( $manifest->{url} );
    my $digest = text_of( $manifest->{sha512} );
    if ( $url eq '' || $digest eq '' ) {
        say "  [$platform] malformed manifest, skipping";
        next;
    }
    fail("bad version '$ver' for $platform.")
        if $ver !~ /^[0-9]+\.[0-9]+\.[0-9]+/;
    fail("bad sha512 for $platform.") if $digest !~ /^[0-9a-f]{128}\z/;
    if ( $VERSION eq '' ) {
        $VERSION = $ver;
    }
    elsif ( $ver ne $VERSION ) {
        say "  [$platform] version $ver differs from $VERSION, skipping";
        next;
    }

    my $ext =
          $url =~ /\.tar\.gz/ ? '.tar.gz'
        : $url =~ /\.exe/     ? '.exe'
        :                       '';

    push @artifacts,
        {
        platform => $platform,
        url      => $url,
        digest   => $digest,
        file     => "antigravity-$VERSION-$platform$ext",
        };
}

fail('no usable manifests found.') if $VERSION eq '';

printf "Version %s (%d artifacts)\n", $VERSION, scalar @artifacts;

my $outdir = "antigravity-$VERSION";
make_path($outdir);
chdir $outdir or fail("cannot cd to $outdir: $!");

my $sums_file = "antigravity-$VERSION-SHA512SUMS.txt";
open my $sums, '>', $sums_file or fail("cannot write $sums_file: $!");
$sums->autoflush(1);

for my $artifact (@artifacts) {
    my ( $file, $digest ) = @$artifact{qw(file digest)};
    say "[$artifact->{platform}] $file";

    # Skip only when the existing file already matches the advertised digest.
    if ( -f $file && sha512_of($file) eq $digest ) {
        say '  already complete, skipping';
        print {$sums} "$digest  $file\n";
        next;
    }

    download( $artifact->{url}, $file );

    my $actual = sha512_of($file);
    if ( $actual ne $digest ) {
        print STDERR "Error: checksum mismatch for $file\n",
            "  expected $digest\n",
            "  actual   $actual\n",
            "  delete the file and re-run to download it fresh.\n";
        exit 1;
    }
    say '  verified sha512';
    print {$sums} "$digest  $file\n";
}

close $sums or fail("cannot write $sums_file: $!");

say '';
say "SHA512 sums written to $outdir/$sums_file";
open $sums, '<', $sums_file or fail("cannot read $sums_file: $!");
print while <$sums>;
close $sums;
