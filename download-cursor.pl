#!/usr/bin/env perl
use v5.34;
use warnings;

use Digest::SHA;
use File::Path qw(make_path);
use HTTP::Tiny;
use IO::Uncompress::Gunzip qw($GunzipError);
use IO::Uncompress::Unzip qw($UnzipError);
use Time::Local qw(timegm);

# Mirrors the Cursor Agent CLI ("cursor-agent") packages. The official
# installer at cursor.com/install detects the platform and downloads one
# agent-cli-package archive from downloads.cursor.com. This downloads the
# archive for every platform into cursor-agent-<version>/.
#
# Unlike the other mirrors here, Cursor publishes no checksums, manifest, or
# signatures for these archives -- the official installer pipes curl straight
# into tar. There is nothing upstream to verify against, so this records its
# own SHA256 sums and tests that each archive decompresses. Those sums attest
# to what was downloaded, not to what Cursor intended to publish.
#
# There is no version index either, so latest is resolved by reading the
# version the install script pins.
#
# Usage: download-cursor.pl [VERSION]   (VERSION defaults to latest)

# Like the shell's ${VAR:-default}: the first value that is set and non-empty.
sub first_set {
    return ( grep { defined && length } @_ )[0];
}

my $install_url =
    first_set( $ENV{CURSOR_INSTALL_URL}, 'https://cursor.com/install' );
my $base_url = first_set( $ENV{CURSOR_DOWNLOAD_BASE},
    'https://downloads.cursor.com/lab' );
my $version_input = first_set( $ARGV[0], $ENV{CURSOR_VERSION}, 'latest' );

# Platforms to mirror. There is no index endpoint to enumerate. The install
# script only ever builds linux/darwin x {x64,arm64} and rejects every other
# uname; the Windows archives are published alongside them (as .zip) even
# though no official installer requests them.
my @PLATFORMS = qw(
    darwin/arm64
    darwin/x64
    linux/arm64
    linux/x64
    windows/arm64
    windows/x64
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
# connect and total limits. The install script and HEAD requests follow
# redirects like curl -L; archive downloads follow them by hand so each hop
# can be held to HTTPS.
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
        # copy, so the size and decompression checks decide whether it is good.
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

# The advertised length of $url, or the empty string when a HEAD request
# cannot get one.
sub remote_size_of {
    my ($url) = @_;
    my $res = $api->head($url);
    return '' if !$res->{success};
    my $length = $res->{headers}{'content-length'} // '';
    $length = $length->[-1] if ref $length;
    return $length =~ /^[0-9]+\z/ ? $length : '';
}

# Reads every member of an opened gzip or zip stream to the end, which checks
# each member's CRC32 and length along the way. Returns true when all of it
# decompresses cleanly. For a zip, @$seen gets a zip_entry for each member,
# its offset found by adding up the members before it.
sub drain {
    my ( $z, $seen ) = @_;
    return 0 if !$z;
    my ( $buffer, $offset ) = ( undef, 0 );
    for ( ;; ) {
        my $read;
        1 while ( $read = $z->read($buffer) ) > 0;
        return 0 if $read < 0;
        if ($seen) {
            my $info = $z->getHeaderInfo;
            push @$seen,
                zip_entry( @$info{qw(Name CRC32 MethodID CompressedLength
                        UncompressedLength)}, $offset );
            $offset += $info->{HeaderLength} + $info->{CompressedLength}
                + $info->{TrailerLength};
        }

        # 0 is the end of the archive: past the last gzip member, or at a zip
        # central directory. It still leaves a header error behind, so only
        # the return value is trusted.
        my $next = $z->nextStream;
        return 0 if $next < 0;
        last     if !$next;
    }
    return $z->close;
}

# What the central directory and a member's local header must agree on: the
# name, CRC32, compression method, both sizes, and where the member starts.
sub zip_entry {
    return join "\0", @_;
}

# Reading a zip front to back never looks at its central directory, which is
# what unzip and most other tools go by. Returns a zip_entry for each central
# directory entry, or nothing when the directory or the end record that
# locates it is damaged.
sub zip_directory {
    my ($file) = @_;
    open my $fh, '<:raw', $file or return;
    my $size = -s $fh;

    # The end record is the last 22 bytes before a comment of up to 64 KiB.
    my $tail_size = $size < 65557 ? $size : 65557;
    my $tail;
    seek $fh, $size - $tail_size, 0 or return;
    read( $fh, $tail, $tail_size ) == $tail_size or return;
    my $at = rindex $tail, "PK\x05\x06";
    return if $at < 0 || $at + 22 > length $tail;
    my ( $disk, $dir_disk, $disk_count, $count, $dir_size, $dir_offset,
        $comment_size )
        = unpack 'x4 v v v v V V v', substr $tail, $at, 22;
    return if $at + 22 + $comment_size != length $tail;
    my $end_at = $size - $tail_size + $at;

    # This is a single-disk archive, so every disk number is 0 and the
    # entries on this disk are all of them.
    return if $disk || $dir_disk || $disk_count != $count;

    # Zip64 archives keep the real values in a second end record, found
    # through the locator just before the first. Some writers add one even
    # when nothing overflows, and it then sits between the directory and the
    # first end record.
    my ( $sig, $end64_disk, $end64_at, $disks ) =
        $at >= 20 ? unpack( 'a4 V Q< V', substr $tail, $at - 20, 20 ) : ('');
    if ( $sig eq "PK\x06\x07" ) {
        return if $end64_disk || $disks != 1;
        my $end64;
        seek $fh, $end64_at, 0 or return;
        read( $fh, $end64, 56 ) == 56 or return;
        my ( $record_size, $needs, @wide );
        ( $sig, $record_size, $needs, $disk, $dir_disk, $disk_count, @wide )
            = unpack 'a4 Q< x2 v V V Q< Q< Q< Q<', $end64;
        return
               if $sig ne "PK\x06\x06"
            || $record_size < 44
            || ( $needs & 0xFF ) > 63
            || $disk
            || $dir_disk
            || $disk_count != $wide[0];

        # The first end record's values must be the same, or all ones to say
        # they are in this one.
        my @narrow = ( $count, $dir_size, $dir_offset );
        my @ones   = ( 0xFFFF, 0xFFFFFFFF, 0xFFFFFFFF );
        for ( 0 .. 2 ) {
            return if $narrow[$_] != $ones[$_] && $narrow[$_] != $wide[$_];
        }
        ( $count, $dir_size, $dir_offset ) = @wide;
        $end_at = $end64_at;
    }
    return if $dir_offset + $dir_size != $end_at;

    my $dir;
    seek $fh, $dir_offset, 0 or return;
    read( $fh, $dir, $dir_size ) == $dir_size or return;
    my ( @entries, $pos );
    for ( $pos = 0; $pos < $dir_size; ) {
        return if $pos + 46 > $dir_size;
        my ($sig,      $needs,     $method,     $crc,
            $packed,   $unpacked,  $name_size, $extra_size,
            $note_size, $local_at
        ) = unpack 'a4 x2 v x2 v x4 V V V v v v x8 V', substr $dir, $pos, 46;

        # 6.3 is the newest zip version; unzip refuses anything that claims
        # to need a later one.
        return if $sig ne "PK\x01\x02" || ( $needs & 0xFF ) > 63;
        my $next = $pos + 46 + $name_size + $extra_size + $note_size;
        return if $next > $dir_size;
        my $name  = substr $dir, $pos + 46,              $name_size;
        my $extra = substr $dir, $pos + 46 + $name_size, $extra_size;

        # A size or offset too big for 32 bits is all ones here, with the
        # real value in the zip64 extra field, in this order.
        my @wide =
            grep { $$_ == 0xFFFFFFFF } \( $unpacked, $packed, $local_at );
        while ( @wide && length $extra >= 4 ) {
            my ( $id, $length ) = unpack 'v v', $extra;
            my $data = substr $extra, 4, $length;
            if ( $id == 1 ) {
                return if length $data < 8 * @wide;
                ${ $wide[$_] } = unpack 'Q<', substr $data, 8 * $_, 8
                    for 0 .. $#wide;
                @wide = ();
            }
            substr( $extra, 0, 4 + $length ) = '';
        }
        return if @wide;

        push @entries,
            zip_entry( $name, $crc, $method, $packed, $unpacked, $local_at );
        $pos = $next;
    }
    return if @entries != $count;
    return @entries;
}

# With no upstream digest, decompressing is the only integrity signal there
# is: it catches truncation and corruption, though not substitution. Unlike
# the bash script, which needs unzip for the zip check and skips it without,
# both checks here use core modules and always run.
sub archive_ok {
    my ($file) = @_;
    my %strict = ( Strict => 1, Transparent => 0 );
    return drain(
        IO::Uncompress::Gunzip->new( $file, %strict, MultiStream => 1 ) )
        if $file =~ /\.tar\.gz\z/;
    return 1 if $file !~ /\.zip\z/;

    # Each member must decompress, and the central directory must describe
    # exactly the members found, in the same order.
    my @seen;
    drain( IO::Uncompress::Unzip->new( $file, %strict ), \@seen ) or return 0;
    my @listed = zip_directory($file) or return 0;
    return join( "\n", @seen ) eq join( "\n", @listed );
}

my $version_re = qr/20[0-9]{2}\.[0-9]{2}\.[0-9]{2}-[0-9a-f]{6,40}/;

# Resolve the version. The install script pins one, and is the only place it
# is published; every occurrence in it must agree.
my $version = $version_input;
if ( $version eq 'latest' ) {
    say "Resolving latest version from $install_url...";
    my $install_script = get_text($install_url);
    my %found;
    $found{$&} = 1 while $install_script =~ /$version_re/g;
    fail( 'expected one version in the install script, found '
            . keys(%found)
            . '.' )
        if keys %found != 1;
    ($version) = keys %found;
}
fail("invalid version '$version_input'.") if $version !~ /^$version_re\z/;
my $VERSION = $version;

printf "Downloading version %s (%d platforms)...\n", $VERSION,
    scalar @PLATFORMS;

my $outdir = "cursor-agent-$VERSION";
make_path($outdir);
chdir $outdir or fail("cannot cd to $outdir: $!");

my $sums_file = "cursor-agent-$VERSION-sha256sums.txt";
open my $sums, '>', $sums_file or fail("cannot write $sums_file: $!");
$sums->autoflush(1);

for my $platform (@PLATFORMS) {
    my ( $os, $arch ) = split m{/}, $platform;

    # Windows packages ship as .zip, the rest as .tar.gz.
    my $ext = $os eq 'windows' ? '.zip' : '.tar.gz';
    my $url = "$base_url/$VERSION/$os/$arch/agent-cli-package$ext";

    # Every platform ships the same asset basename, so the local name has to
    # carry the platform itself.
    my $file = "cursor-agent-$VERSION-$os-$arch$ext";

    say "[$os/$arch] $file";

    # No digest to compare against, so fall back to the advertised size, and
    # require the archive to still be readable before trusting it.
    if ( -f $file ) {
        my $remote_size = remote_size_of($url);
        if (   $remote_size ne ''
            && ( -s $file // 0 ) == $remote_size
            && archive_ok($file) )
        {
            say '  already complete, skipping';
            print {$sums} sha256_of($file) . "  $file\n";
            next;
        }
    }

    download( $url, $file );

    if ( !archive_ok($file) ) {
        print STDERR "Error: $file did not decompress cleanly;",
            " the download may be corrupt.\n",
            "  delete the file and re-run to download it fresh.\n";
        exit 1;
    }

    my $digest = sha256_of($file);
    say "  ok $digest";
    print {$sums} "$digest  $file\n";
}

close $sums or fail("cannot write $sums_file: $!");

say '';
say "SHA256 sums written to $outdir/$sums_file";
say 'Note: these are computed locally; Cursor publishes no upstream digests.';
open $sums, '<', $sums_file or fail("cannot read $sums_file: $!");
print while <$sums>;
close $sums;
