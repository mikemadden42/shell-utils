#!/usr/bin/env perl
use v5.34;
use warnings;

use Digest::SHA;
use File::Path qw(make_path);
use HTTP::Tiny;
use JSON::PP;
use Time::Local qw(timegm);

# Mirrors the muse ("Muse Code") platform binaries. The launcher script served
# at api.meta.ai/muse-launcher.sh is only a bootstrapper; the real binaries are
# resolved through two JSON manifests and live on lookaside.facebook.com. This
# walks the same manifests and downloads every artifact, verifying each against
# the SHA256 the release manifest advertises.

# Like the shell's ${VAR:-default}: the first value that is set and non-empty.
sub first_set {
    return ( grep { defined && length } @_ )[0];
}

my $channel     = first_set( $ENV{MUSE_CHANNEL}, 'muse-stable' );
my $channel_url = first_set( $ENV{MUSE_CHANNEL_URL},
    "https://api.meta.ai/muse-code/channels/$channel" );
my $user_agent = 'muse-code/launcher-2';

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
# connect and total limits. Every request, manifests included, follows
# redirects by hand so each hop can be held to HTTPS.
my $http = HTTP::Tiny->new(
    timeout      => 30,
    verify_SSL   => 1,
    max_redirect => 0,
    agent        => $user_agent,
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

# The manifest value as jq -r prints it: scalars as text, anything missing or
# null as the empty string.
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

# Fetches and decodes a JSON manifest, held to HTTPS on every hop like the
# bash script's curl --proto '=https' --proto-redir '=https'.
sub get_json {
    my ($url) = @_;
    for ( my $hops = 0;; $hops++ ) {
        fail("refusing to fetch non-HTTPS URL $url") if $url !~ m{^https://}i;
        my $res = $http->get( $url,
            { headers => { Accept => 'application/json' } } );
        if ( $res->{status} =~ /^3/ && defined $res->{headers}{location} ) {
            fail("too many redirects fetching $url")
                if $hops >= $max_redirects;
            $url = absolute_url( $res->{headers}{location}, $url );
            next;
        }
        fail( "could not fetch $url: " . describe($res) )
            if !$res->{success};
        my $doc = eval { $json->decode( $res->{content} ) };
        fail("$url is not a JSON object.") if ref $doc ne 'HASH';
        return $doc;
    }
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
    my ( $url, $file, $size ) = @_;
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
        my $res     = $http->request(
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
                    }
                    print {$fh} $chunk or fail("cannot write $file: $!");
                    $written += length $chunk;
                    show_progress( $written, $size );
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
    my ( $url, $file, $size ) = @_;
    for my $attempt ( 0 .. $retries ) {
        my ( $error, $retry ) = fetch_once( $url, $file, $size );
        return       if !defined $error;
        fail($error) if !$retry || $attempt == $retries;
        print STDERR "  $error; retrying in ${retry_delay}s...\n";
        sleep $retry_delay;
    }
}

say "Fetching channel manifest ($channel)...";
my $channel_json = get_json($channel_url);
my $VERSION      = text_of( $channel_json->{version} );
my $manifest_url = text_of( $channel_json->{manifest_url} );
fail("unexpected version '$VERSION'.")
    if $VERSION !~ /^[0-9]+\.[0-9]+\.[0-9]+-R[0-9]+(?:\.[0-9]+)?\z/;
fail('channel manifest has no usable manifest_url.')
    if $manifest_url !~ m{^https://};

say "Version $VERSION; fetching release manifest...";
my $release_json = get_json($manifest_url);
fail('release manifest is not sha256-checksummed.')
    if text_of( $release_json->{checksum_algorithm} ) ne 'sha256';

# Mirror whatever the release manifest publishes, so newly added platforms are
# picked up automatically instead of silently going unmirrored.
my $artifacts = $release_json->{artifacts};
fail('release manifest lists no artifacts.')
    if ref $artifacts ne 'HASH' || !%$artifacts;
my @platforms = sort keys %$artifacts;

printf "Mirroring %d artifacts...\n", scalar @platforms;

my $outdir = "muse-$VERSION";
make_path($outdir);
chdir $outdir or fail("cannot cd to $outdir: $!");

my $sums_file = "muse-$VERSION-sha256sums.txt";
open my $sums, '>', $sums_file or fail("cannot write $sums_file: $!");
$sums->autoflush(1);

# chmod +x: add execute wherever the umask allows it.
my $exec_bits = 0111 & ~umask;

for my $platform (@platforms) {
    my $artifact =
        ref $artifacts->{$platform} eq 'HASH' ? $artifacts->{$platform} : {};
    my $url      = text_of( $artifact->{url} );
    my $checksum = text_of( $artifact->{checksum} );
    my $size     = text_of( $artifact->{size} );
    fail("bad checksum/size for $platform.")
        if $checksum !~ /^[0-9a-f]{64}\z/ || $size !~ /^[1-9][0-9]*\z/;

    # The download URL carries the real filename in its file= parameter; take
    # the extension from there (.pkg, .exe) instead of guessing per platform.
    my $ext = '';
    if ( $url =~ /.*file=([^&]*)/s ) {
        my $remote_name = $1;
        $ext = ".$1" if $remote_name =~ /\.([^.]*)\z/;
    }
    my $file = "muse-$VERSION-$platform$ext";

    say "[$platform] $file ($size bytes)";

    # Skip only when the existing file already matches the advertised digest.
    if (   -f $file
        && ( -s _ // 0 ) == $size
        && sha256_of($file) eq $checksum )
    {
        say '  already complete, skipping';
        print {$sums} "$checksum  $file\n";
        next;
    }

    download( $url, $file, $size );

    my $actual = sha256_of($file);
    if ( $actual ne $checksum ) {
        print STDERR "Error: checksum mismatch for $file\n",
            "  expected $checksum\n",
            "  actual   $actual\n",
            "  delete the file and re-run to download it fresh.\n";
        exit 1;
    }
    say "  verified $checksum";
    print {$sums} "$checksum  $file\n";

    if ( $ext ne '.pkg' ) {
        my $mode = ( stat $file )[2] & 07777;
        chmod $mode | $exec_bits, $file or fail("cannot chmod $file: $!");
    }
}

close $sums or fail("cannot write $sums_file: $!");

say '';
say "SHA256 sums written to $outdir/$sums_file";
open $sums, '<', $sums_file or fail("cannot read $sums_file: $!");
print while <$sums>;
close $sums;
