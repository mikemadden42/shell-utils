#!/usr/bin/env perl
use v5.34;
use warnings;

use Digest::SHA;
use File::Path qw(make_path);
use HTTP::Tiny;
use JSON::PP;
use Time::Local qw(timegm);

# Mirrors the Anthropic Claude Code native binaries. The official installer
# resolves a version, reads manifest.json, and downloads the single binary for
# the current platform. This downloads the binary for every platform the
# manifest advertises into claude-<version>/ and verifies each against the
# SHA256 checksum and byte size the manifest records.
#
# The platform list is not hardcoded: whatever manifest.json lists is what gets
# mirrored, so newly added architectures are picked up automatically.
#
# Usage: download-claude-code.pl [VERSION]   (VERSION defaults to stable)

# Like the shell's ${VAR:-default}: the first value that is set and non-empty.
sub first_set {
    return ( grep { defined && length } @_ )[0];
}

my $version_input = first_set( $ARGV[0], $ENV{CLAUDE_CODE_RELEASE}, 'stable' );
my $base_url      = first_set( $ENV{CLAUDE_CODE_RELEASES_BASE_URL},
    'https://storage.googleapis.com/claude-code-dist-86c565f3-f756-42ad-8dfa-d59b1c096819/claude-code-releases'
);

my $mib            = 1048576;
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
# binary downloads follow them by hand so each hop can be held to HTTPS.
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

sub is_version {
    my ($v) = @_;
    return $v =~ /^[0-9]+\.[0-9]+\.[0-9]+(?:[.-][A-Za-z0-9.-]+)?\z/;
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
        # copy, so the size and checksum checks decide whether it is good.
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

# Accept a literal version, or a channel name that resolves to one.
( my $version = $version_input ) =~ s/^v//;
if ( !is_version($version) ) {
    fail("invalid version '$version_input'. Expected x.y.z or a channel name.")
        if $version !~ /^[a-z][a-z0-9-]*\z/;
    say "Resolving channel '$version'...";
    ( $version = get_text("$base_url/$version") ) =~ s/[\r\n\t ]//g;
    fail("channel '$version_input' resolved to invalid version '$version'.")
        if !is_version($version);
}

say "Fetching manifest ($version)...";
my $manifest_text = get_text("$base_url/$version/manifest.json");
my $manifest      = eval { $json->decode($manifest_text) };
fail("manifest for $version is not a JSON object.")
    if ref $manifest ne 'HASH';

my $VERSION = text_of( $manifest->{version} );
fail("manifest version '$VERSION' does not match requested $version.")
    if $VERSION ne $version;

my $entries = $manifest->{platforms};
fail('manifest lists no platforms.')
    if ref $entries ne 'HASH' || !%$entries;

# JSON::PP does not keep key order, so put the platforms back in the order the
# manifest lists them, as jq's keys_unsorted does, by where each key appears.
my %listed_at;
for my $platform ( keys %$entries ) {
    $listed_at{$platform} = length $manifest_text;
    $listed_at{$platform} = $-[0] if $manifest_text =~ /"\Q$platform\E"\s*:/;
}
my @platforms =
    sort { $listed_at{$a} <=> $listed_at{$b} || $a cmp $b } keys %$entries;

printf "Downloading version %s (%d platforms)...\n", $VERSION,
    scalar @platforms;

my $outdir = "claude-$VERSION";
make_path($outdir);
chdir $outdir or fail("cannot cd to $outdir: $!");

my $sums_file = "claude-$VERSION-sha256sums.txt";
open my $sums, '>', $sums_file or fail("cannot write $sums_file: $!");
$sums->autoflush(1);

my @files;

for my $platform (@platforms) {
    my $entry =
        ref $entries->{$platform} eq 'HASH' ? $entries->{$platform} : {};
    my $binary = text_of( $entry->{binary} );
    my $digest = text_of( $entry->{checksum} );
    my $size   = text_of( $entry->{size} );
    fail("incomplete manifest entry for $platform.")
        if $binary eq ''
        || $digest !~ /^[0-9a-f]{64}\z/
        || $size   !~ /^[0-9]+\z/;

    # Local names keep the platform in the filename; the manifest's binary name
    # only contributes its extension (claude vs claude.exe).
    my $ext  = $binary =~ /\.([^.]*)\z/ ? ".$1" : '';
    my $file = "claude-$VERSION-$platform$ext";
    my $url  = "$base_url/$VERSION/$platform/$binary";

    printf "[%s] %s (%d MiB)\n", $platform, $file, int( $size / $mib );

    # Skip only when the existing file already matches the advertised checksum.
    if ( -f $file && sha256_of($file) eq $digest ) {
        say '  already complete, skipping';
        print {$sums} "$digest  $file\n";
        push @files, $file;
        next;
    }

    download( $url, $file, $size );

    my $actual_size = -s $file // 0;
    fail("size mismatch for $file: expected $size, got $actual_size.")
        if $actual_size != $size;
    my $actual = sha256_of($file);
    if ( $actual ne $digest ) {
        print STDERR "Error: checksum mismatch for $file\n",
            "  expected $digest\n",
            "  actual   $actual\n",
            "  delete the file and re-run to download it fresh.\n";
        exit 1;
    }
    say "  verified $digest";
    print {$sums} "$digest  $file\n";
    push @files, $file;
}

close $sums or fail("cannot write $sums_file: $!");

# chmod +x: add execute wherever the umask allows it.
my $exec_bits = 0111 & ~umask;
for my $file (@files) {
    my $mode = ( stat $file )[2] & 07777;
    chmod $mode | $exec_bits, $file or fail("cannot chmod $file: $!");
}

say '';
say "SHA256 sums written to $outdir/$sums_file";
open $sums, '<', $sums_file or fail("cannot read $sums_file: $!");
print while <$sums>;
close $sums;
