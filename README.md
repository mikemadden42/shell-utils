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

## Claude desktop installers

`download-claude-desktop.bash` mirrors the Claude desktop app installers — the
macOS `.pkg` and both Windows `.msix` builds:

```bash
./download-claude-desktop.bash                       # the three default targets
./download-claude-desktop.bash --dry-run             # resolve and print, download nothing
./download-claude-desktop.bash darwin/universal/dmg  # a specific target
```

Targets are written as `platform/arch/kind`. The download page hands each
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
