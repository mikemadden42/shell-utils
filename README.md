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
