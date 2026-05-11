# TODO

List of identified issues and improvements for the `shell-utils` project.

## Security & Robustness
- [x] **Fix Insecure Temporary Directories**: ~~Replace fixed paths in `/tmp` with `mktemp` to prevent symlink attacks and collisions.~~ Done in `pkg-hist.bash` and `best-block.bash`.
- [ ] **Improve Error Handling**: 
    - [ ] Add `set -euo pipefail` to Bash scripts where appropriate.
    - [ ] Add explicit checks for `cd`, `mkdir`, and critical command successes.
- [ ] **Robust Globbing**: Two scripts still bite on unmatched globs (audit done; `add-hashes.sh`/`battery-status.bash`/`check-git.sh` are safe):
    - [ ] `update-src.sh:3` — `for i in *; do ... cd "$i" || exit` bails on empty cwd and on the first regular file. Add `[ -d "$i" ] || continue` before the `cd`.
    - [ ] `make-tarballs.bash:3` — `for dir in */; do` on an empty cwd produces a literal `*.tar.gz` file in `$HOME`. Add `[ -d "$dir" ] || continue` (and drop the bogus `.`/`..` check, since `*/` never matches them).

## Logic & Portability
- [ ] **Dependency Verification**: Add checks to verify that external tools (e.g., `inxi`, `dmidecode`, `docker`, `pmset`) are installed before execution.
- [ ] **OS-Specific Labeling**: 
    - [ ] Update README to clearly categorize Linux-only vs. macOS-only scripts.
    - [ ] Add guard clauses in scripts to exit gracefully if run on the wrong OS (e.g., `[[ "$OSTYPE" == "linux-gnu"* ]]`).
- [ ] **Hardcoded Paths**: Review scripts that write to `$HOME` (e.g., `ls-docker.sh`, `pkg-hist.bash`) and consider making output paths configurable via arguments or environment variables.

## Maintenance & Style
- [ ] **Standardize Extensions**: Decide on a consistent naming convention for `.sh` vs `.bash` or ensure extensions strictly match the shebang.
- [ ] **Resolve `shellcheck` Suppressions**: Address the existing `# shellcheck disable` comments (e.g., the SC2045 suppressions in `pkg-hist.bash`).
- [ ] **Shebang Consistency**: Ensure all scripts have appropriate and consistent shebangs (e.g., `#!/usr/bin/env bash` for better portability).

## `download-claude-code.bash`
- [ ] **Deduplicate suffix derivation**: Lines 21-22 and 31-32 each compute `suffix=""; [[ $platform == win32-* ]] && suffix=".exe"`. Compute once into a parallel array, or accept the duplication.
- [ ] **`chmod +x` downloaded binaries**: Only matters if the binaries are meant to be run directly from the download dir.
- [ ] **Validate `VERSION`**: `${1:-...}` is interpolated into `mkdir -p` and filenames with no sanity check; a value containing `..` or shell metacharacters would produce surprising paths.
- [ ] **Redundant per-platform error blocks**: `|| { echo …; exit 1; }` after each `curl -f` is redundant with `set -e`; it only adds a friendlier message. Either keep for UX or drop for brevity.
