#!/usr/bin/env perl
use v5.34;
use warnings;

use Digest::MD5;
use Digest::SHA;
use File::Path qw(make_path);
use HTTP::Tiny;
use Time::Local qw(timegm);

# Mirrors the Anthropic Claude desktop app installers. The download page hands
# each platform a /api/desktop/<platform>/<arch>/<kind>/latest/redirect URL
# that 307s to the real artifact on downloads.claude.ai; this resolves every
# target into claude-desktop-<version>/ and verifies each download.
#
# Unlike download-claude-code.pl there is no manifest and no published
# checksum file, so the targets are a list rather than something derivable. The
# integrity checks are what the CDN itself advertises: the byte length, and the
# ETag, which for these objects is the MD5 of the content. That catches
# truncation and corruption, not substitution.
#
# Usage: download-claude-desktop.pl [--dry-run] [TARGET...]
#   TARGET is platform/arch/kind, e.g. darwin/universal/pkg. The default five
#   are the installer for each platform: the macOS pkg, which is universal and
#   covers Intel as well as Apple Silicon, both Windows msix builds, and both
#   Linux debs. Also published, and available by naming them: the macOS dmg,
#   the Squirrel "Claude Setup.exe" for both Windows arches, and per-arch
#   darwin zips, which are Squirrel.Mac auto-update payloads rather than
#   something to install.

my @DEFAULT_TARGETS = qw(
    darwin/universal/pkg
    win32/x64/msix
    win32/arm64/msix
    linux/x64/deb
    linux/arm64/deb
);

# Like the shell's ${VAR:-default}: the first value that is set and non-empty.
sub first_set {
    return ( grep { defined && length } @_ )[0];
}

my $api_base = first_set( $ENV{CLAUDE_DESKTOP_API_BASE_URL},
    'https://claude.ai/api/desktop' );
my $channel = first_set( $ENV{CLAUDE_DESKTOP_RELEASE}, 'latest' );

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
# connect and total limits. Every request follows redirects by hand, or not at
# all, so each hop can be held to HTTPS.
#
# It keeps HTTP::Tiny's own User-Agent. claude.ai's bot challenge has been seen
# to answer curl's with a 403 where it gives HTTP::Tiny's the redirect, so
# borrowing curl's would only make the fallback below needed more often.
my $dl = HTTP::Tiny->new(
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

sub md5_of {
    my ($file) = @_;
    return Digest::MD5->new->addfile( open_raw($file) )->hexdigest;
}

sub open_raw {
    my ($file) = @_;
    open my $fh, '<:raw', $file or fail("cannot read $file: $!");
    return $fh;
}

# The first value of a response header, as curl -D prints it.
sub header_of {
    my ( $res, $name ) = @_;
    my $value = $res->{headers}{$name} // '';
    return ref $value ? $value->[0] : $value;
}

# Ask the CDN for an object's size and ETag without fetching it. A one-byte
# range keeps this cheap while still proving the object is really there. Like
# the bash script's curl call, this does not follow a redirect.
sub probe {
    my ($url) = @_;
    return { status => 0, headers => {} } if $url !~ m{^https://}i;
    return $dl->get( $url, { headers => { Range => 'bytes=0-0' } } );
}

my $dry_run = 0;
my @targets;
for my $arg (@ARGV) {
    if ( $arg eq '--dry-run' || $arg eq '-n' ) {
        $dry_run = 1;
    }
    elsif ( $arg =~ /^-/ ) {
        fail("unknown option '$arg'.");
    }
    else {
        fail("invalid target '$arg'. Expected platform/arch/kind.")
            if $arg !~ m{^[a-z0-9]+/[a-z0-9]+/[a-z0-9]+\z};
        push @targets, $arg;
    }
}
@targets = @DEFAULT_TARGETS if !@targets;

my ( $version, $build ) = ( '', '' );
my ( %url_of,  @unresolved );

printf "Resolving %d targets (%s)...\n", scalar @targets, $channel;

for my $target (@targets) {
    my $redirect = "$api_base/$target/$channel/redirect";
    my $res      = $redirect =~ m{^https://}i ? $dl->get($redirect) : {};
    my $url =
        ( $res->{status} // '' ) =~ /^3/ && defined $res->{headers}{location}
        ? absolute_url( header_of( $res, 'location' ), $redirect )
        : '';

    # The redirect path carries the release:
    # .../releases/<platform>/<arch>/<version>/Claude-<build>.<ext>
    if ($url =~ m{ /releases/[a-z0-9]+/[a-z0-9]+/([0-9][0-9A-Za-z.-]*)
                      /Claude-([0-9a-f]+)\.[a-z0-9]+ \z }x
        )
    {
        my ( $this_version, $this_build ) = ( $1, $2 );
        if ( $version eq '' ) {
            ( $version, $build ) = ( $this_version, $this_build );
        }
        elsif ( $this_version ne $version || $this_build ne $build ) {
            print STDERR "Error: $target resolved to $this_version",
                " (build $this_build), but an earlier target resolved to",
                " $version (build $build).\n",
                "  a release is probably mid-rollout; pass one target at a",
                " time to mirror them separately.\n";
            exit 1;
        }
        say "  $target -> $this_version";
        $url_of{$target} = $url;
    }
    else {
        say "  $target -> could not resolve";
        push @unresolved, $target;
    }
}

# claude.ai sits behind a bot challenge that answers some clients with a 403
# instead of the redirect. Every target in a release shares one version and
# build id, so a target that failed can still be addressed directly on the CDN
# once any other target has resolved -- confirmed against the CDN before use,
# so a wrong guess is reported rather than downloaded.
if ( @unresolved && $version ne '' ) {
    printf "Deriving %d unresolved targets from %s (build %s)...\n",
        scalar @unresolved, $version, $build;
    for my $target (@unresolved) {
        my ( $platform, $arch, $kind ) = split m{/}, $target;
        my $url = "https://downloads.claude.ai/releases/$platform/$arch"
            . "/$version/Claude-$build.$kind";
        fail("$target is not published at $url")
            if probe($url)->{status} !~ /^20[06]\z/;
        say "  $target -> ", $url =~ s{.*/}{}r;
        $url_of{$target} = $url;
    }
}

fail(     'no target resolved. claude.ai may be challenging this client;'
        . ' try again or from another network.' )
    if !%url_of;

say "Mirroring Claude desktop $version (build $build)...";

my $outdir    = "claude-desktop-$version";
my $sums_file = "claude-desktop-$version-sha256sums.txt";
my $sums;

if ( !$dry_run ) {
    make_path($outdir);
    chdir $outdir or fail("cannot cd to $outdir: $!");
    open $sums, '>', $sums_file or fail("cannot write $sums_file: $!");
    $sums->autoflush(1);
}

for my $target (@targets) {
    my $url = $url_of{$target};
    my ( $platform, $arch, $kind ) = split m{/}, $target;
    my $file = "claude-desktop-$version-$platform-$arch.$kind";

    # content-range is "bytes 0-0/<total>"; the total after the slash is the
    # size.
    my $res    = probe($url);
    my ($size) = header_of( $res, 'content-range' ) =~ m{([^/]*)\z};
    ( my $etag = header_of( $res, 'etag' ) ) =~ s/"//g;
    fail("$target did not report a size.") if $size !~ /^[0-9]+\z/;

    printf "[%s] %s (%d MiB)\n", $target, $file, int( $size / $mib );

    if ($dry_run) {
        say "  $url";
        next;
    }

    # An MD5-shaped ETag is checked; a multipart upload's ETag ends in -<n>
    # and is not an MD5, so those are skipped rather than reporting a
    # mismatch that means nothing.
    my $md5_etag = $etag =~ /^[0-9a-f]{32}\z/;

    # A complete file is only skipped when its length and, when the CDN gives
    # a usable one, its MD5 still match what is published.
    if (   -f $file
        && ( -s _ // 0 ) == $size
        && ( !$md5_etag || md5_of($file) eq $etag ) )
    {
        say '  already complete, skipping';
        print {$sums} sha256_of($file) . "  $file\n";
        next;
    }

    download( $url, $file, $size );

    my $actual_size = -s $file // 0;
    fail("size mismatch for $file: expected $size, got $actual_size.")
        if $actual_size != $size;

    if ($md5_etag) {
        my $actual_md5 = md5_of($file);
        if ( $actual_md5 ne $etag ) {
            print STDERR "Error: ETag mismatch for $file\n",
                "  expected $etag\n",
                "  actual   $actual_md5\n",
                "  delete the file and re-run to download it fresh.\n";
            exit 1;
        }
        say "  verified md5 $etag and $size bytes";
    }
    else {
        say "  no usable ETag; verified $size bytes";
    }

    print {$sums} sha256_of($file) . "  $file\n";
}

if ($dry_run) {
    say '';
    say 'Dry run; nothing was downloaded.';
    exit 0;
}

close $sums or fail("cannot write $sums_file: $!");

say '';
say "Locally computed SHA256 sums written to $outdir/$sums_file";
say 'Anthropic publishes no checksums for these installers; the sums are this';
say "mirror's own, not an upstream attestation.";
open $sums, '<', $sums_file or fail("cannot read $sums_file: $!");
print while <$sums>;
close $sums;
