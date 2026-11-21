#!/usr/bin/env perl
use v5.34;
use warnings;

use Digest::SHA;
use File::Basename qw(basename);
use File::Path     qw(make_path remove_tree);
use File::Temp     qw(tempdir);
use HTTP::Tiny;
use JSON::PP;
use POSIX       qw(_exit uname);
use Time::Local qw(timegm);

# Installs the OpenAI Codex CLI from its standalone package archive.
#
# The tarball cannot simply be unpacked onto $PATH: codex locates its helper
# binaries (codex-code-mode-host, rg, and bwrap on Linux) relative to its own
# directory, so the package has to keep its layout. This reproduces what the
# official install.sh does — unpack the package into
# ~/.codex/packages/standalone/releases/<version>-<target>/, repoint the
# "current" symlink at it, and link ~/.local/bin/codex into that tree — so
# upgrades are atomic and old releases stay around to roll back to.
#
# Unpacking still runs the system tar. Archive::Tar holds each entry in memory
# and peaks around 1.5 GB on the codex binary, too much for an installer.
#
# Usage: install-codex.pl [VERSION]   (VERSION defaults to latest)

# Like the shell's ${VAR:-default}: the first value that is set and non-empty.
sub first_set {
    return ( grep { defined && length } @_ )[0];
}

my $version_input = first_set( $ARGV[0], $ENV{CODEX_RELEASE}, 'latest' );
my $base_url      = first_set( $ENV{CODEX_RELEASES_BASE_URL},
    'https://releases.openai.com/codex' );
my $bin_dir    = first_set( $ENV{CODEX_INSTALL_DIR}, "$ENV{HOME}/.local/bin" );
my $codex_home = first_set( $ENV{CODEX_HOME},        "$ENV{HOME}/.codex" );
my $standalone_root = "$codex_home/packages/standalone";
my $releases_dir    = "$standalone_root/releases";
my $current_link    = "$standalone_root/current";

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
                            if $total
                            && $res->{status} == 206
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

# True when $command is an executable somewhere on $PATH, like command -v.
sub on_path {
    my ($command) = @_;
    return grep { -f "$_/$command" && -x _ } split /:/, $ENV{PATH} // '';
}

fail('required command not found: tar') if !on_path('tar');

# Verify $file against digest $expected, reporting both sides on a mismatch.
sub verify {
    my ( $file, $expected ) = @_;
    my $actual = sha256_of($file);
    if ( $actual ne $expected ) {
        print STDERR "Error: checksum mismatch for ", basename($file), "\n",
            "  expected $expected\n",
            "  actual   $actual\n";
        exit 1;
    }
}

# The package archives are built against musl on Linux and ship per-arch on
# macOS; Rosetta-translated shells get the native arm64 build.
my ( $system, $machine ) = ( uname() )[ 0, 4 ];
my $os =
      $system eq 'Darwin' ? 'darwin'
    : $system eq 'Linux'  ? 'linux'
    :                       fail('only macOS and Linux are supported.');
my $arch =
      $machine =~ /^(?:x86_64|amd64)\z/  ? 'x86_64'
    : $machine =~ /^(?:arm64|aarch64)\z/ ? 'aarch64'
    :            fail("unsupported architecture: $machine");

if ( $os eq 'darwin' && $arch eq 'x86_64' ) {
    my $translated = `sysctl -n sysctl.proc_translated 2>/dev/null` // '';
    $arch = 'aarch64' if $translated =~ /^1\s*\z/;
}

my $target =
    $os eq 'darwin' ? "$arch-apple-darwin" : "$arch-unknown-linux-musl";

# Accept latest, x.y.z, and pre-releases, with or without a rust-v / v prefix.
( my $version = $version_input ) =~ s/^rust-v//;
$version =~ s/^v//;
fail(
    "invalid version '$version_input'. Expected latest or x.y.z[-alpha|-beta].")
    if $version ne 'latest'
    && $version
    !~ /^[0-9]+\.[0-9]+\.[0-9]+(?:-alpha(?:\.[0-9]+){0,2}|-beta(?:\.[0-9]+)?)?\z/;

my $metadata_url =
    $version eq 'latest'
    ? "$base_url/channels/latest"
    : "$base_url/releases/$version/release.json";

say "==> Fetching release metadata ($version)...";
my $metadata = eval { $json->decode( get_text($metadata_url) ) };
fail("release metadata for $version is not a JSON object.")
    if ref $metadata ne 'HASH';

# tag_name looks like rust-v0.154.0; the release version is the part after it.
my $tag = text_of( $metadata->{tag_name} );
( my $VERSION = $tag ) =~ s/^rust-v//;
fail("could not resolve version from metadata (tag '$tag').")
    if $VERSION !~ /^[0-9]+\.[0-9]+\.[0-9]+/;
fail("metadata version $VERSION does not match requested $version.")
    if $version ne 'latest' && $VERSION ne $version;

my $asset      = "codex-package-$target.tar.gz";
my $sums_asset = 'codex-package_SHA256SUMS';

# The release's entry for the asset named $name, or an empty one.
sub asset_entry {
    my ($name) = @_;
    my $assets = $metadata->{assets};
    my @assets = ref $assets eq 'ARRAY' ? @$assets : ();
    my ($entry) =
        grep { ref eq 'HASH' && text_of( $_->{name} ) eq $name } @assets;
    return $entry // {};
}

sub asset_digest {
    my ($name) = @_;
    ( my $digest = text_of( asset_entry($name)->{digest} ) ) =~ s/^sha256://;
    fail("release $VERSION does not publish $name.")
        if $digest !~ /^[0-9a-f]{64}\z/;
    return $digest;
}

sub asset_url {
    my ($name) = @_;
    my $url = text_of( asset_entry($name)->{browser_download_url} );
    fail("release $VERSION has no download URL for $name.") if $url eq '';
    return $url;
}

my $release_name = "$VERSION-$target";
my $release_dir  = "$releases_dir/$release_name";

say "==> Installing Codex CLI $VERSION ($target)";

# The temporary directory and a half-built release are removed however this
# exits, including on Ctrl-C.
my $tmp_dir       = tempdir( 'install-codex.XXXXXXXX', TMPDIR => 1 );
my $stage_release = "$releases_dir/.staging.$release_name.$$";

END {
    remove_tree( grep { defined && -e } $tmp_dir, $stage_release );
}
$SIG{$_} = sub { exit 1 }
    for qw(INT TERM);

make_path($releases_dir);

# The release metadata signs the checksum manifest, and the manifest carries
# the archive's digest, so both hops are verified before anything is unpacked.
my $sums_path = "$tmp_dir/$sums_asset";
{
    my $sums = get_text( asset_url($sums_asset) );
    open my $fh, '>:raw', $sums_path or fail("cannot write $sums_path: $!");
    print {$fh} $sums;
    close $fh or fail("cannot write $sums_path: $!");
}
verify( $sums_path, asset_digest($sums_asset) );

my $digest;
{
    open my $fh, '<', $sums_path or fail("cannot read $sums_path: $!");
    while (<$fh>) {
        my ( $hash, $name ) = split;
        next if !defined $name || $name ne $asset || length $hash != 64;
        $digest = lc $hash;
        last;
    }
}
fail("$asset is not listed in $sums_asset.") if !defined $digest;

# Reuse a mirror made by download-codex.bash or download-codex.pl when it is
# sitting alongside us, so installing after a mirror run does not refetch
# several hundred megabytes.
my $archive_path = "$tmp_dir/$asset";
my $mirrored     = "codex-$VERSION/$asset";
if ( -f $mirrored && sha256_of($mirrored) eq $digest ) {
    say "==> Using mirrored archive $mirrored";
    $archive_path = $mirrored;
}
else {
    say "==> Downloading $asset";
    download( asset_url($asset), $archive_path );
    verify( $archive_path, $digest );
}

say "==> Unpacking to $release_dir";
make_path($stage_release);
system( 'tar', '-xzf', $archive_path, '-C', $stage_release ) == 0
    or fail("could not unpack $asset.");

# The archive does not carry the executable bit for every helper, and codex
# refuses to start without them.
for my $helper (qw(bin/codex bin/codex-code-mode-host codex-path/rg)) {
    chmod 0755, "$stage_release/$helper"
        or fail("cannot chmod $stage_release/$helper: $!");
}
if ( -f "$stage_release/codex-resources/bwrap" ) {
    chmod 0755, "$stage_release/codex-resources/bwrap"
        or fail("cannot chmod $stage_release/codex-resources/bwrap: $!");
}
unlink "$stage_release/codex";
symlink 'bin/codex', "$stage_release/codex"
    or fail("cannot link $stage_release/codex: $!");

remove_tree($release_dir) if -e $release_dir || -l $release_dir;
rename $stage_release, $release_dir
    or fail("cannot move $stage_release to $release_dir: $!");

# Runs a command without a shell, with its stderr discarded, and returns its
# output and exit status.
sub output_of {
    my @command = @_;
    my $pid     = open my $fh, '-|';
    fail("cannot run $command[0]: $!") if !defined $pid;
    if ( !$pid ) {
        open STDERR, '>', '/dev/null';

        # _exit, so the child does not run the END block and remove the
        # parent's temporary files.
        exec { $command[0] } @command or _exit(127);
    }
    my $output = do { local $/; <$fh> }
        // '';
    close $fh;
    return ( $output, $? );
}

# The version is the last word codex --version prints, as awk '{print $NF}'
# takes it from each line.
my ( $output, $status ) = output_of( "$release_dir/bin/codex", '--version' );
my $installed = join "\n", map { ( split ' ' )[-1] // '' } split /\n/, $output;
fail("unpacked codex did not run (exit status $status).") if $status;
fail("unpacked codex reports version '$installed', expected $VERSION.")
    if $installed ne $VERSION;

# Swap a symlink through a temporary name so a failed install never leaves
# ~/.local/bin/codex dangling. rename(2) replaces a symlink rather than
# following it; only a real directory in the way has to be removed first.
sub relink {
    my ( $link, $target ) = @_;
    my $tmp = "$link.$$";
    unlink $tmp;
    symlink $target, $tmp or fail("cannot link $tmp: $!");
    return if rename $tmp, $link;
    remove_tree($link);
    rename $tmp, $link or fail("cannot move $tmp to $link: $!");
}

relink( $current_link, $release_dir );

make_path($bin_dir);
relink( "$bin_dir/codex", "$current_link/bin/codex" );

# Only macOS looks up codex-code-mode-host on PATH; elsewhere codex finds it
# next to itself, so an extra link would just go stale.
my $host_link = "$bin_dir/codex-code-mode-host";
if ( $os eq 'darwin' ) {
    relink( $host_link, "$current_link/bin/codex-code-mode-host" );
}
elsif (
    ( readlink($host_link) // '' ) eq "$current_link/bin/codex-code-mode-host" )
{
    unlink $host_link;
}

( undef, $status ) = output_of( "$bin_dir/codex", '--version' );
fail("$bin_dir/codex --version failed.") if $status;

say '';
say "Codex CLI $VERSION installed to $bin_dir/codex";
if ( ":$ENV{PATH}:" !~ /:\Q$bin_dir\E:/ ) {
    say "$bin_dir is not on your PATH; add it with:";
    say qq{  export PATH="$bin_dir:\$PATH"};
}

say "Previous releases are kept in $releases_dir; remove old ones by hand.";
