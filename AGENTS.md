# AGENTS.md

Durable, project-intrinsic knowledge (curated by `/scribe`). Non-obvious facts that change future actions — not task notes.

## Maintaining this file

Keep only knowledge useful to almost every future agent session in this project.
Don't repeat what the code already shows — point to the file, function, or command instead.
Prefer rewriting or pruning an existing entry over adding a new one; skip trivial tasks that taught nothing durable.
Keep each entry to one line, action first.

- Expand arrays as `${arr[@]+"${arr[@]}"}`, never bare `"${arr[@]}"` — on macOS bash 3.2 an empty array under `set -u` aborts with "unbound variable", and every `lib/*.sh` runs `set -euo pipefail`.
- Don't gate on a numeric flag with `${flag:+…}` — the string `"0"` is non-empty, so it fires when the flag is `0`. Use `[ "$flag" = 1 ]` (this is why `canopy setup` once mislabeled a real run as "(dry-run)").
- `bin/canopy` must follow symlinks (a `readlink` loop) to locate `lib/` — it's installed as a PATH symlink (`~/.local/bin/canopy`), so `dirname "${BASH_SOURCE[0]}"` alone points at the symlink's dir, not the repo.
- `repo_root()` resolves the MAIN tree via `git-common-dir`, not `--show-toplevel` — so `.canopy/` is reachable when a worker runs `canopy` from inside a linked worktree. Keep it that way; `--show-toplevel` returns the worktree, where there is no `.canopy/`.
- `canopy start` launches `claude` WITHOUT `--dangerously-skip-permissions`; for an unattended/headless drive (e.g. a demo or cron) add the flag yourself, or it stalls on the first tool-permission prompt.
- Update the installed CLI by re-running 'canopy setup' from the source checkout — setup installs a stable snapshot to ~/.local/share/canopy and points the PATH symlink there, so switching branches in the repo no longer changes the installed canopy (it used to, and broke canopy across all projects).
- macOS: the launchd merge-watcher can't read repos under ~/Documents|Desktop|Downloads (TCC 'Operation not permitted' — cd works but reads fail); grant Full Disk Access to /bin/bash or keep repos elsewhere. 'canopy watch status' detects it; 'canopy recover' reconciles merges in-session as a fallback.
- CI runs on ubuntu where 'awk' is mawk, not BSD/gawk — its regex and [[:space:]] handling differ and silently mis-parse. For text parsing that must pass CI, prefer grep+sed+tr over awk regex (this bit _pr_is_merged in lib/watch.sh).
- canopy review runs the reviewer headless with cwd=the leased worktree and --allowedTools Read Grep Glob (lib/review.sh) so it can follow changed symbols to call-sites without stalling on a permission prompt; drop either and it silently reverts to diff-only, blind to cross-file breakage.
- Guard command-substitution assignments as `x=$(cmd | ...) || x=""` — under set -euo pipefail an unguarded `x=$(failing-pipe)` aborts the whole caller (this silently broke 'canopy base' via _default_branch in repos with no origin/HEAD).
- Compute any review/PR/recover diff base via `base_branch` (honors the configured `canopy base` / state `.base`), never `_default_branch` directly — that resolves origin/HEAD and ignores the configured base, so a task stacked on a non-default base gets diffed against main and the gate reviews already-merged bloat (both reviewer paths now share `_review_base`; the codex path once diverged and did this).
- `base_branch` returns a ref NAME, and a linked worktree's LOCAL base ref freezes at pool-creation and drifts behind remote merges — so before diffing/merge-basing against it, `git fetch origin "$base"` and use FETCH_HEAD (the current remote tip), never the local ref, or the diff counts already-merged work as new and inflates risk to high (`_review_base` does this; `worktree lease` already did). Keep it offline-safe: fetch fails → fall back to the local ref + warn, don't abort.
