# AGENTS.md

Durable, project-intrinsic knowledge (curated by `/scribe`). Non-obvious facts that change future actions — not task notes.

## Maintaining this file

Keep only knowledge useful to almost every future agent session in this project.
Don't repeat what the code already shows — point to the file, function, or command instead.
Prefer rewriting or pruning an existing entry over adding a new one; skip trivial tasks that taught nothing durable.
Keep each entry to one line, action first.

- Expand arrays as `${arr[@]+"${arr[@]}"}`, never bare `"${arr[@]}"` — on macOS bash 3.2 an empty array under `set -u` aborts with "unbound variable", and every `lib/*.sh` runs `set -euo pipefail`.
- Don't gate on a numeric flag with `${flag:+…}` — the string `"0"` is non-empty, so it fires when the flag is `0`. Use `[ "$flag" = 1 ]` (this is why `canopy setup` once mislabeled a real run as "(dry-run)").
- `repo_root()` resolves the MAIN tree via `git-common-dir`, not `--show-toplevel` — so `.canopy/` is reachable when a worker runs `canopy` from inside a linked worktree. Keep it that way; `--show-toplevel` returns the worktree, where there is no `.canopy/`.
- `canopy start` launches `claude` WITHOUT `--dangerously-skip-permissions`; for an unattended/headless drive (e.g. a demo or cron) add the flag yourself, or it stalls on the first tool-permission prompt.
