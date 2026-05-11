# TODO

List of identified issues and improvements for the `shell-utils` project.

## Security & Robustness
- [ ] **Fix Insecure Temporary Directories**: Replace fixed paths in `/tmp` (e.g., in `pkg-hist.bash`) with `mktemp -d` to prevent symlink attacks and collisions.
- [ ] **Improve Error Handling**: 
    - [ ] Add `set -euo pipefail` to Bash scripts where appropriate.
    - [ ] Add explicit checks for `cd`, `mkdir`, and critical command successes.
- [ ] **Robust Globbing**: Fix `add-hashes.sh` and similar scripts to handle cases where no files match the glob pattern (e.g., using `shopt -s nullglob` in Bash or checking file existence inside the loop).

## Logic & Portability
- [ ] **Dependency Verification**: Add checks to verify that external tools (e.g., `inxi`, `dmidecode`, `docker`, `pmset`) are installed before execution.
- [ ] **OS-Specific Labeling**: 
    - [ ] Update README to clearly categorize Linux-only vs. macOS-only scripts.
    - [ ] Add guard clauses in scripts to exit gracefully if run on the wrong OS (e.g., `[[ "$OSTYPE" == "linux-gnu"* ]]`).
- [ ] **Hardcoded Paths**: Review scripts that write to `$HOME` (e.g., `ls-docker.sh`, `pkg-hist.bash`) and consider making output paths configurable via arguments or environment variables.

## Maintenance & Style
- [ ] **Standardize Extensions**: Decide on a consistent naming convention for `.sh` vs `.bash` or ensure extensions strictly match the shebang.
- [ ] **Linting & Formatting**: 
    - [ ] Resolve existing `shellcheck` warnings (as seen in `pkg-hist.bash` comments).
    - [ ] Apply `shfmt` across all scripts for consistent indentation.
- [ ] **Shebang Consistency**: Ensure all scripts have appropriate and consistent shebangs (e.g., `#!/usr/bin/env bash` for better portability).

## `download-claude-code.bash`
- [ ] **Deduplicate suffix derivation**: Lines 21-22 and 31-32 each compute `suffix=""; [[ $platform == win32-* ]] && suffix=".exe"`. Compute once into a parallel array, or accept the duplication.
- [ ] **`chmod +x` downloaded binaries**: Only matters if the binaries are meant to be run directly from the download dir.
- [ ] **Validate `VERSION`**: `${1:-...}` is interpolated into `mkdir -p` and filenames with no sanity check; a value containing `..` or shell metacharacters would produce surprising paths.
- [ ] **Redundant per-platform error blocks**: `|| { echo …; exit 1; }` after each `curl -f` is redundant with `set -e`; it only adds a friendlier message. Either keep for UX or drop for brevity.
