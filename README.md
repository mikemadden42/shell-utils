# shell-utils

Linux/macOS shell scripts

Run formatting and lint checks:

```bash
shfmt -d *.bash *.sh
shellcheck *.sh
```

These scripts only work on macOS:
- ls-battery.sh
- set-volume.sh

## Codex CLI

`install-codex.bash` installs the OpenAI Codex CLI from its standalone package
archive, and `uninstall-codex.bash` removes it again:

```bash
./install-codex.bash            # latest
./install-codex.bash 0.154.0    # a specific release

./uninstall-codex.bash --dry-run  # show what would be removed
./uninstall-codex.bash            # remove the install, keep config and auth
./uninstall-codex.bash --purge    # also delete ~/.codex
```

The package cannot simply be unpacked onto `$PATH`: `codex` resolves its helper
binaries relative to its own directory. The installer reproduces the layout the
official `install.sh` builds, under `~/.codex/packages/standalone/releases/`,
with `~/.local/bin/codex` linked into it through a `current` symlink. Older
releases are left in place, so a bad upgrade can be rolled back by repointing
`current`.

Archives are verified against the digests the release metadata and
`codex-package_SHA256SUMS` publish before anything is unpacked. A mirror made by
`download-codex.bash` in the working directory is reused when its digest
matches. Neither script edits a shell profile; `$PATH` changes are printed for
you to make.

Both honour `CODEX_INSTALL_DIR` (default `~/.local/bin`) and `CODEX_HOME`
(default `~/.codex`).

`download-codex.bash` mirrors the `codex-package-<target>.tar.gz` archive for
every target the release publishes into `codex-<version>/`, verifying each
against the release metadata's SHA256 digest and writing a `SHA256SUMS.txt`:

```bash
./download-codex.bash           # latest
./download-codex.bash 0.154.0   # a specific release
```

`download-codex.pl` is a Perl 5.34 port with the same arguments, output and
`CODEX_RELEASES_BASE_URL` override. It needs no `curl`, `jq` or checksum tool:
`HTTP::Tiny`, `JSON::PP` and `Digest::SHA` replace them, and it resumes partial
files, retries transient failures and holds archive downloads to HTTPS the way
the bash script's curl flags do.

## Release channel versions

`claude-code-versions.bash` and `codex-versions.bash` print the version each
release channel currently points at:

```console
$ ./claude-code-versions.bash
stable   2.1.236
latest   2.1.269

$ ./codex-versions.bash
latest      0.154.0
prerelease  0.155.0-alpha.3.10
```

Pass channel names to check others. A channel that cannot be fetched or does not
resolve to a version is reported without stopping the rest, and the script exits
non-zero.

The two tools' channels do not line up:

| Claude Code | Codex        | Meaning                                         |
|-------------|--------------|-------------------------------------------------|
| `stable`    | `latest`     | the current stable release                      |
| `latest`    | —            | a newer full release, not yet promoted          |
| —           | `prerelease` | the newest alpha                                |

Codex's `prerelease` channel is undocumented and unused by the official
`install.sh`, so it may change without notice.

`claude-code-versions.bash` needs only `curl`; `codex-versions.bash` also needs
`jq`, since Codex channels return release metadata rather than a bare version.
Both honour the same base-URL override as their download scripts
(`CLAUDE_CODE_RELEASES_BASE_URL`, `CODEX_RELEASES_BASE_URL`).

`claude-code-versions.pl` and `codex-versions.pl` are Perl 5.34 ports of the
bash scripts with the same arguments, output, exit status and base-URL
overrides. They fetch with the core `HTTP::Tiny` module instead of running
`curl`, and `codex-versions.pl` parses JSON with the core `JSON::PP` instead of
`jq`. HTTPS also needs `IO::Socket::SSL` and `Net::SSLeay`, which the macOS
system Perl includes.

## Claude Code binaries

`download-claude-code.bash` mirrors the Claude Code native binary for every
platform `manifest.json` lists into `claude-<version>/`, verifying each against
the manifest's SHA256 and size and writing a `sha256sums.txt`:

```bash
./download-claude-code.bash           # stable
./download-claude-code.bash latest    # another channel
./download-claude-code.bash 2.1.311   # a specific release
```

`download-claude-code.pl` is a Perl 5.34 port with the same arguments, output
and `CLAUDE_CODE_RELEASES_BASE_URL` override. It needs no `curl`, `jq` or
checksum tool: `HTTP::Tiny`, `JSON::PP` and `Digest::SHA` replace them, and it
resumes partial files, retries transient failures and holds binary downloads to
HTTPS the way the bash script's curl flags do.

## Claude desktop installers

`download-claude-desktop.bash` mirrors the Claude desktop app installers — the
macOS `.pkg`, both Windows `.msix` builds, and both Linux `.deb` packages:

```bash
./download-claude-desktop.bash                       # the five default targets
./download-claude-desktop.bash --dry-run             # resolve and print, download nothing
./download-claude-desktop.bash darwin/universal/dmg  # a specific target
```

Targets are written as `platform/arch/kind`. The macOS package is universal, so
it covers Intel as well as Apple Silicon; there is no separate Intel build. Also
published, and available by naming them: the macOS `.dmg`, the Squirrel
`Claude Setup.exe` for both Windows architectures, and per-arch darwin `.zip`s,
which are auto-update payloads rather than something to install. The download page hands each
platform an `/api/desktop/<target>/latest/redirect` URL that redirects to the
artifact on `downloads.claude.ai`, and `latest` is the only channel — pinned
versions and names like `stable` and `beta` are refused.

There is no manifest and no published checksum file, so unlike
`download-claude-code.bash` the target list is written out rather than derived.
Downloads are verified against the byte length and the ETag, which on these
objects is a plain MD5. That catches truncation and corruption but not
substitution, so the `sha256sums.txt` it writes is this mirror's own record, not
an upstream attestation.

The macOS endpoint may answer with a Cloudflare challenge instead of the
redirect. Because every target in a release shares one version and build id, a
challenged target is addressed directly on the CDN once any other target has
resolved, and that URL is confirmed there before anything is downloaded. That
needs a second target in the same run, so if the macOS endpoint is being
challenged, ask for a Windows target alongside it rather than on its own.

## Kimi Code and Muse binaries

`download-kimi.bash` mirrors the Kimi Code CLI binary for every platform its
per-version `manifest.json` lists into `kimi-code-<version>/`, and
`download-muse.bash` mirrors every Muse Code artifact its release manifest
lists into `muse-<version>/`. Each verifies the downloads against the
manifest's SHA256 and writes a `sha256sums.txt`:

```bash
./download-kimi.bash           # latest
./download-kimi.bash 2.7.2     # a specific release
./download-muse.bash           # the muse-stable channel
MUSE_CHANNEL=other ./download-muse.bash
```

`download-kimi.pl` and `download-muse.pl` are Perl 5.34 ports with the same
arguments, output and overrides (`KIMI_DOWNLOAD_BASE` and `KIMI_VERSION`;
`MUSE_CHANNEL` and `MUSE_CHANNEL_URL`). Like `download-claude-code.pl`, they
need no `curl`, `jq` or checksum tool, and they resume partial files, retry
transient failures and hold binary downloads to HTTPS. The Muse port holds its
manifest requests to HTTPS too and sends the launcher's User-Agent, as the bash
script does.

## Antigravity CLI builds

`download-antigravity.bash` mirrors the Antigravity CLI (`agy`) artifact for
every platform manifest the auto-updater serves into `antigravity-<version>/`,
verifying each against the manifest's SHA512 and writing a `SHA512SUMS.txt`.
The manifests only describe the latest release, so it takes no arguments:

```bash
./download-antigravity.bash
```

`download-antigravity.pl` is a Perl 5.34 port with the same output and
`ANTIGRAVITY_BASE_URL` override. `Digest::SHA` computes the SHA512 in place of
`sha512sum`, `shasum` or `openssl`, and like the other ports it needs no `curl`
or `jq`. A manifest that is not valid JSON is reported as malformed and
skipped, where the bash script stops on the `jq` error.

## Copilot CLI and Qwen Code archives

`download-copilot.bash` mirrors every `copilot-*` standalone build a GitHub
Copilot CLI release lists in its `SHA256SUMS.txt` into
`copilot-cli-<version>/`, skipping the `github-copilot-*.tgz` npm packages.
`download-qwen.bash` mirrors every Qwen Code archive the release's
`SHA256SUMS` lists into `qwen-code-<version>/`. Both verify each download
against that file:

```bash
./download-copilot.bash          # latest
./download-copilot.bash 1.0.114  # a specific release
./download-qwen.bash             # latest
./download-qwen.bash 0.28.3      # a specific release
```

`download-copilot.pl` and `download-qwen.pl` are Perl 5.34 ports with the same
arguments, output and overrides (`COPILOT_REPO_URL` and `COPILOT_VERSION`;
`QWEN_RELEASE_BASE` and `QWEN_INSTALL_VERSION`). Like the other ports they need
no `curl` or checksum tool. The Copilot port still resolves `latest` from where
GitHub's `/releases/latest` redirects rather than through the rate-limited API.

## Cursor Agent CLI packages

`download-cursor.bash` mirrors the Cursor Agent CLI (`cursor-agent`) package
for macOS, Linux and Windows into `cursor-agent-<version>/`:

```bash
./download-cursor.bash                     # the version cursor.com/install pins
./download-cursor.bash 2026.11.19-f005e9d  # a specific build
```

Cursor publishes no checksums, manifest or index, so the platform list is
written out, `latest` is read from the install script, and the
`sha256sums.txt` it writes is this mirror's own record. A download is accepted
when the archive decompresses cleanly, and an existing file is kept when it
also matches the advertised size.

`download-cursor.pl` is a Perl 5.34 port with the same arguments, output and
overrides (`CURSOR_INSTALL_URL`, `CURSOR_DOWNLOAD_BASE`, `CURSOR_VERSION`). It
needs no `curl`, checksum tool, `gzip` or `unzip`: the core
`IO::Uncompress::Gunzip` and `IO::Uncompress::Unzip` modules test the
archives, so the zip check always runs, where the bash script skips it when
`unzip` is missing. Reading a zip front to back never touches its central
directory, so the port also checks that the directory and its end records
agree with the entries it read.

## Days since a date

`diff-days.bash` prints the whole days between today and the date set in
`past_date`. It needs GNU `date` for `--date`; macOS `date` rejects that, and
the script then counts from 1970 instead and still exits 0. `diff-days.pl` is a
Perl 5.34 port with the same output that works on both, using the core
`Time::Local` module to read the date as local midnight, as GNU `date` does,
and exiting non-zero for an invalid date.

## Archive hashes

`add-hashes.sh` writes a `<name>.sha256` next to each `.tar`, `.tgz`, `.txz` and
`.zip` in the current directory that does not have one yet. `add-hashes.pl` is a
Perl 5.34 port with the same output and files that hashes with the core
`Digest::SHA` module instead of `sha256sum`. Names holding a backslash, newline
or carriage return are escaped the way GNU `sha256sum` does it, so
`sha256sum -c` reads them back. A file that cannot be read is reported and
leaves no `.sha256`, where the shell script leaves an empty one that later runs
then skip.
