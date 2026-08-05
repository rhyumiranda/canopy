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
- Run hook/guard tests with 'env -u CANOPY_ROLE' when inside a canopy session — CANOPY_ROLE=orchestrator leaks from the worker/orchestrator shell and falsely fails the role-gated 'inactive without role' assertions (CI's clean env passes). Note: 'canopy scribe' writes to the MAIN tree's AGENTS.md (git-common-dir), so from a worktree edit AGENTS.md directly to make the entry ride your PR.
- Workers launch with CANOPY_ROLE=worker (the `env CANOPY_ROLE=worker` prefix in lib/herdr.sh + lib/worker.sh), so guard-project-write is inactive for them — they edit their worktree directly, no /tmp-scratch workaround needed. Only if orchestrator role leaks (un-updated canopy) does that guard reject bare redirect/arrow/angle-bracket chars in Bash; then fall back to a /tmp scratch file + `git commit -F` (the allowlist matches /tmp).
- Adding a worker launch site? prefix the agent command with `env CANOPY_ROLE=worker` — canopy_role_guard (lib/common.sh, allowlist in _worker_cmd_allowed) refuses orchestrator-only subcommands under that role so a worker can't clobber the shared .canopy board/Herdr identity via git-common-dir; widen _worker_cmd_allowed if a worker legitimately needs a new subcommand.
- mktemp templates must END in the X's — on macOS/BSD `mktemp foo.XXXXXX.json` is NOT randomized (creates a literal `foo.XXXXXX.json` that then collides on reuse); GNU/CI randomizes it, so this bites only on macOS. Use `mktemp "${TMPDIR:-/tmp}/foo.XXXXXX"` (X's last) — lib/review.sh currently gets this wrong.
- Claude's folder-trust gate is SEPARATE from tool permissions: --dangerously-skip-permissions does NOT bypass the trust-this-folder dialog, stored in ~/.claude.json at .projects[PATH].hasTrustDialogAccepted; before every claude launch workers pre-mark the leased worktree via _claude_trust_path (lib/common.sh) or an untrusted path silently wedges startup.
- Append new `task add` cases at the END of test/herdr_test.sh — its fake Herdr hardcodes task ids (t7/t8/t11…) that must line up with task-add order, so inserting an add mid-file renumbers every later task and breaks the id-keyed mock get-responses.
