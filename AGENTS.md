# AGENTS.md

The operating manual for every agent in this repo, plus durable project facts. This file is loaded into context on every session (it is `CLAUDE.md` too, via symlink), so it persists where a one-shot system prompt drifts. **Read your role's section and follow it every turn.**

## Maintaining this file

Keep only knowledge useful to almost every future agent session in this project.
Don't repeat what the code already shows — point to the file, function, or command instead.
Prefer rewriting or pruning an existing entry over adding a new one; skip trivial tasks that taught nothing durable.
Keep each durable fact to one line, action first. Add new facts under the matching group in **Durable facts** (create a group only if none fits). The role sections above are the operating spec — edit them when the workflow changes, not for one-off task notes.

---

## Your role — read this first

This file loads into the orchestrator, workers, and every spawned sub-agent alike. **Follow ONLY your role's section; ignore the others.**

- **You are a WORKER** if your cwd is a linked worktree (git-dir under `.git/worktrees/`, or a `.treehouse` path) **or** `CANOPY_ROLE=worker`. Your task brief comes from your spawn prompt — build it, per **Workers & other roles** below. The Orchestrator playbook does **not** bind you: you *do* edit code.
- **You are the ORCHESTRATOR** if you were launched via `canopy start` (`CANOPY_ROLE=orchestrator`, running from the main tree). Follow the **Orchestrator playbook**.
- **You were spawned with a specific persona** (canopy-reviewer, canopy-planner, canopy-oracle, …)? Your persona's own system prompt governs. This manual is background; don't let the Orchestrator playbook override your persona.

---

## Orchestrator playbook

You are a supervisor one level above the workers. **You run the plan; you never write project code** (you have no Edit/Write by design — every code change goes through an isolated worker). Keep it lean: prefer deterministic `canopy` commands over spawning agents; spend LLM calls only on genuine judgment.

### Every turn
1. **Read `.canopy/state.json` first** — it is the source of truth for the board and `mode`. Reconcile it with reality before acting.
2. **On startup / after a `/clear`:** run `canopy recover --all` and show `canopy project ls`. For each in-flight task, **re-spawn its worker to CONTINUE from its checkpoint** (Task tool, `subagent_type: canopy-worker`, pointed at `canopy worktree path <id>`) — don't restart it. `recover` also reconciles merged PRs and re-arms the watcher.

### The per-task loop — MUST / SHOULD / MAY
A task is **trivial** only if it is a one-line, no-ambiguity change. Mark it `canopy task set <id> trivial 1` to justify skipping the plan + edge gates. **Everything else is non-trivial** — the gates below are default-ON, and `canopy` enforces them (see Gates). You justify a SKIP; you never skip silently.

1. **Capture intent** (MUST) — `canopy task add "<title>"` → `<id>`, then set the fields the PR renders: `brief`, `why`, and if relevant `issue <n>`, `breaking "…"`, `verify "…"`. Triage label auto-derives from the conventional-commit type in the title; override with `labels`.
   - **Contract-first** (MUST, for a shared boundary) — when two sides must agree on an interface, split into three tasks: task 0 authors ONLY the contract; each side declares `canopy task set <id> depends_on t0`. Land the contract first.
2. **Plan** (SHOULD — default-ON for non-trivial; the lease gate enforces it):
   - **`canopy-planner`** (Task tool) — read-only interview planner; asks you the genuine forks (relay to the human in **guided** mode), pins scope, writes `.canopy/plans/<id>.md`.
   - **`canopy plan-gate <id>`** (CLI) — fresh independent feasibility/gaps check; on `approve` it records `plan_status=approved` (which the lease gate reads). On `revise`, hand the gaps back to the planner and re-gate.
3. **Lease** (MUST) — `canopy worktree lease <id>` cuts the feature branch from a fresh copy of the base. **Refuses** if `depends_on` is unmet, or (non-trivial) if the plan isn't approved. Set a non-default integration branch once with `canopy base <branch>`.
4. **Spawn the worker** (MUST) — Task tool, `subagent_type: canopy-worker`, pointed at the leased worktree path + the task title/brief. It's synchronous: your call blocks and returns the worker's report or blocker. The worker implements → documents the change in the same diff → runs `canopy checks run` → commits incrementally → `canopy task checkpoint` at each milestone.
   - **Mid-task consults** (MAY, on demand): **`canopy-oracle`** (Task tool) for a high-stakes architecture/debug call; **`canopy-researcher`** (Task tool, cheap) for an external unknown (library/upstream behavior). Fold their guidance into the worker's brief on re-spawn. Reach for these only when a real judgment call or unknown blocks — not by default.
5. **Review** (MUST) — `canopy review <id>`: one fresh independent reviewer over the diff + surrounding code, returns JSON with `risk_level` and per-issue `action`. For non-trivial tasks the **adversarial edge pass runs by default** (`canopy-reviewer-edge`, merged into the verdict) and records `edge_reviewed`; the PR gate requires it. Handle by `action`:
   - **`worker-fix`** — re-spawn `canopy-worker` at the same worktree with the issues as its brief; it continues, fixes, re-runs checks, commits → re-review. **At most 2 fix rounds.**
   - **`ask-user`** — in **guided**, surface via `AskUserQuestion` and fold the decision into the re-spawn; in **yolo**, treat as `worker-fix`.
   - **`no-op`** — ignore.
   - Unresolved after 2 rounds, or `risk_level: high` → **do not merge**: set the task `blocked` and surface to the human.
6. **Open the PR** (MUST) — `canopy pr open <id>`, **never** `gh`/`gh-axi pr create` (a guard hook blocks the bypass). It renders the standard body from task fields and enforces the review + edge + checks gates. Then block until CI is green.
7. **Merge → return → done** — handled by the background merge-watcher, with `canopy recover` as the in-session backup. You just observe the state flip on a later turn.

### The gates (deterministic — `canopy` refuses, you don't have to remember)
| Gate | Where | Rule |
|---|---|---|
| Plan approved | `canopy worktree lease` | non-trivial task refuses to lease until `plan_status=approved` (or `trivial=1`) |
| Deps merged | `canopy worktree lease` | refuses while any `depends_on` PR is unmerged |
| Reviewed clean | `canopy pr open` | no PR unless `reviewed=clean` (override `CANOPY_SKIP_REVIEW=1`) |
| Edge reviewed | `canopy pr open` | non-trivial task needs `edge_reviewed` recorded |
| Checks pass | `canopy pr open` | deterministic checks must pass (override `CANOPY_SKIP_CHECKS=1`) |

### Modes — one global switch
Read your autonomy with `canopy mode --global` (the HOME repo's `.mode`, applied to every routed project; a routed project's own `.mode` is superseded). Flip it with a bare `canopy mode yolo|guided` in the home repo.
- **guided** (default): ask the human via `AskUserQuestion` for a real architectural decision, then delegate the answer to the worker and re-review. Only interrupt for decisions that genuinely need a human.
- **yolo**: let the worker/review loop resolve autonomously; don't ask.

### Routing work (one session, many repos)
Any git repo directly under `<canopy-home>/projects/` is a registered project. When a request names one, resolve with `canopy project path <name>`, `cd` in, and run the loop above inside that project's own `.canopy/` board. No project named + cwd is a project/home repo → operate on the current repo. Canopy itself is the HOME, never a routed project.

### Escape hatch
Urgent fix outside the flow → `/hotfix "<what broke>"` (fast worker, fresh worktree, yolo, no review). You still never edit project code yourself.

---

## Orchestrator — edge cases & failure handling

| Situation | Do this |
|---|---|
| **Startup / after `/clear`** | `canopy recover --all` + `canopy project ls`; re-spawn each in-flight worker to CONTINUE from checkpoint (don't restart). |
| **Merges not flipping to `done`** | The launchd watcher may be dead or TCC-blocked (repos under `~/Documents\|Desktop\|Downloads` can't be read by launchd). `canopy watch status` confirms the block; `canopy recover` reconciles merges in-session as the fallback. |
| **Lease refuses — unmet `depends_on`** | A dependency PR hasn't merged. Don't force it; leave the task until `canopy status` shows the dep merged, then lease. (This is what makes contract-first safe.) |
| **Lease refuses — plan not approved** | Non-trivial task without `plan_status=approved`. Run `canopy-planner` → `canopy plan-gate <id>`; or, if genuinely a one-liner, `canopy task set <id> trivial 1`. |
| **Review loop stalls** | 2 fix rounds exhausted, or `risk_level: high`, or reviewer challenges deliberate intent unresolved → set the task `blocked` and surface to the human. **Never ship unresolved.** |
| **`ask-user` in yolo** | Treat as `worker-fix` — let the loop resolve it; don't interrupt the human. |
| **Worker returns blocked** | Read its blocker, gather the missing decision (human via `AskUserQuestion` in guided, or an oracle/researcher consult), fold into the brief, re-spawn at the same worktree. |
| **Worker died mid-task (detached path)** | The worktree + `.canopy/` checkpoint survive. Re-spawn `canopy-worker` at `canopy worktree path <id>`; its resume check reads `git log` + `checkpoint` and continues. Don't restart from scratch. |
| **Want to bypass `canopy pr open`** | Don't — a guard hook blocks `gh pr create` and hand-opening drifts the PR format + skips the gates. Fix the blocker instead. |
| **Truly need to ship past a gate** | Emergency only: `CANOPY_SKIP_REVIEW=1` / `CANOPY_SKIP_CHECKS=1` on `canopy pr open`, or `/hotfix`. Say so explicitly; don't make it a habit. |

---

## Workers & other roles

If you are a **worker**: your task brief is in your spawn prompt — implement exactly that, in your leased worktree, with raw `git` (never Claude's `-w`/isolation). Document the change in the same diff, run `canopy checks run` yourself, commit incrementally on the feature branch, and `canopy task checkpoint <id> "<done / next>"` at each milestone so a resume can continue you. Return your result (or blocker) to the orchestrator. Ignore the Orchestrator playbook's "never edit code" rule — that's for the supervisor, not you.

If you are a **reviewer / planner / oracle / researcher**: your persona's system prompt is authoritative; this manual is only background context.

---

## Durable facts (curated by `/scribe`)

Non-obvious facts that change future actions — not task notes. One line each, action first.

### Shell & portability (bash 3.2 · macOS · CI)

- Expand arrays as `${arr[@]+"${arr[@]}"}`, never bare `"${arr[@]}"` — on macOS bash 3.2 an empty array under `set -u` aborts with "unbound variable", and every `lib/*.sh` runs `set -euo pipefail`.
- Never reference a just-assigned var on the SAME `local` line (`local a="$1" b="$a"`) — under `set -u` the RHS `$a` is seen as unbound and aborts; split into two `local` lines (bit `_dep_reaches` in lib/state.sh).
- Don't gate on a numeric flag with `${flag:+…}` — the string `"0"` is non-empty, so it fires when the flag is `0`. Use `[ "$flag" = 1 ]` (this is why `canopy setup` once mislabeled a real run as "(dry-run)").
- Guard command-substitution assignments as `x=$(cmd | ...) || x=""` — under set -euo pipefail an unguarded `x=$(failing-pipe)` aborts the whole caller (this silently broke 'canopy base' via _default_branch in repos with no origin/HEAD).
- mktemp templates must END in the X's — on macOS/BSD `mktemp foo.XXXXXX.json` is NOT randomized (creates a literal `foo.XXXXXX.json` that then collides on reuse); GNU/CI randomizes it, so this bites only on macOS. Use `mktemp "${TMPDIR:-/tmp}/foo.XXXXXX"` (X's last).
- In jq, `x // default` treats `false` (not just null) as empty, so `false // true` returns `true` — never default a BOOLEAN field with `//` (use `(.f != false)`); this silently flipped a merged `docs_in_sync:false` back to true in `_merge_verdicts` (lib/review.sh).
- CI runs on ubuntu where 'awk' is mawk, not BSD/gawk — its regex and [[:space:]] handling differ and silently mis-parse. For text parsing that must pass CI, prefer grep+sed+tr over awk regex (this bit _pr_is_merged in lib/watch.sh).
- Telemetry runs inside canopy's EXIT trap (bin/canopy) — any network call there MUST stay detached fire-and-forget or it blocks EVERY command's exit up to --max-time; _canopy_telemetry_track_command backgrounds the curl in a `( nohup curl ... & )` subshell (macOS bash 3.2 has no setsid), so keep it detached and never add a synchronous request to the trap.

### Install, paths & worktrees

- Update the installed CLI by re-running 'canopy setup' from the source checkout — setup installs a stable snapshot to ~/.local/share/canopy and points the PATH symlink there, so switching branches in the repo no longer changes the installed canopy (it used to, and broke canopy across all projects).
- `canopy setup` snapshots into ~/.local/share/canopy (which IS $CANOPY_ROOT via the PATH symlink) not only the dirs the CLI READS at runtime (`bin lib agents dist` — a missing dist/ once made installed `canopy init` exit 1) but ALSO the WIRING assets (`commands hooks skills`), because first-run auto-wire and `canopy setup --link` re-copy the Claude/Codex defs FROM $CANOPY_ROOT via _canopy_link_defs; drop any dir and only the INSTALLED CLI breaks, never the tests (which run bin/canopy from the checkout). test/setup_test.sh runs `init` from the installed snapshot to catch this.
- `bin/canopy` must follow symlinks (a `readlink` loop) to locate `lib/` — it's installed as a PATH symlink (`~/.local/bin/canopy`), so `dirname "${BASH_SOURCE[0]}"` alone points at the symlink's dir, not the repo.
- `repo_root()` resolves the MAIN tree via `git-common-dir`, not `--show-toplevel` — so `.canopy/` is reachable when a worker runs `canopy` from inside a linked worktree. Keep it that way; `--show-toplevel` returns the worktree, where there is no `.canopy/`.
- `canopy scribe` writes AGENTS.md via `git rev-parse --show-toplevel` (the CURRENT worktree), NOT repo_root/git-common-dir, so a worker's entry lands on its branch and rides its PR — keep `_scribe_file` on show-toplevel; only `.canopy/` state stays on git-common-dir.

### Base branch, review & PR

- Compute any review/PR/recover diff base via `base_branch` (honors the configured `canopy base` / state `.base`), never `_default_branch` directly — that resolves origin/HEAD and ignores the configured base, so a task stacked on a non-default base gets diffed against main and the gate reviews already-merged bloat (both reviewer paths now share `_review_base`; the codex path once diverged and did this).
- `base_branch` returns a ref NAME, and a linked worktree's LOCAL base ref freezes at pool-creation and drifts behind remote merges — so before diffing/merge-basing against it, `git fetch origin "$base"` and use FETCH_HEAD (the current remote tip), never the local ref, or the diff counts already-merged work as new and inflates risk to high (`_review_base` does this; `worktree lease` already did; `canopy pr open` body/`_pr_body` now routes its `## Files` stat through `_review_base` too — it once diffed the stale local ref and bloated a 2-file docs PR to 15 files/+805). Keep it offline-safe: fetch fails → fall back to the local ref + warn, don't abort.
- canopy review runs the reviewer headless with cwd=the leased worktree and --allowedTools Read Grep Glob (lib/review.sh) so it can follow changed symbols to call-sites without stalling on a permission prompt; drop either and it silently reverts to diff-only, blind to cross-file breakage.
- Don't parse `gh-axi` output with substring greps — it emits AXI-structured TOON (`summary: "N passed, M failed, T total"`, then a `checks[N]{name,conclusion}` block). Read the counts (lib/pr.sh `canopy_pr_checks`); a `/fail|error/` scan over the whole blob reads a check NAMED `lint-error-scan` as a failure and silently calls unrecognized output green.

### Roles, guards & hooks

- Don't rely on CANOPY_ROLE alone to tell if the guard-project-write hook is inactive for a worker — only DETACHED workers (canopy worker spawn) get CANOPY_ROLE=worker via the `env CANOPY_ROLE=worker` prefix in lib/worker.sh; the DEFAULT in-session workers spawned via the orchestrator's Agent tool INHERIT CANOPY_ROLE=orchestrator and are exempted instead by the guard's own linked-worktree/.treehouse cwd detection (hooks/*.sh). Both paths let a worker edit its worktree directly; if the guard still rejects bare redirect/angle-bracket chars (un-updated canopy), use a /tmp scratch file + `git commit -F`.
- Adding a worker launch site? prefix the agent command with `env CANOPY_ROLE=worker` — canopy_role_guard (lib/common.sh, allowlist in _worker_cmd_allowed) refuses orchestrator-only subcommands under that role so a worker can't clobber the shared .canopy board via git-common-dir; widen _worker_cmd_allowed if a worker legitimately needs a new subcommand.
- PreToolUse Bash hooks (hooks/*.sh) must read stdin to EOF (`input="$(cat)"`) BEFORE any early exit — exiting first gives the harness writer SIGPIPE, a flaky exit 141 under its pipefail; and detect a worker via linked-worktree (git-dir under `.git/worktrees/`, or a `.treehouse` path), since in-session workers inherit `CANOPY_ROLE=orchestrator`.
- Run hook/guard tests with 'env -u CANOPY_ROLE' when inside a canopy session — CANOPY_ROLE=orchestrator leaks from the worker/orchestrator shell and falsely fails the role-gated 'inactive without role' assertions (CI's clean env passes).

### Launching agents (claude / codex)

- `canopy start` launches `claude` WITHOUT `--dangerously-skip-permissions`; for an unattended/headless drive (e.g. a demo or cron) add the flag yourself, or it stalls on the first tool-permission prompt.
- Claude's folder-trust gate is SEPARATE from tool permissions: --dangerously-skip-permissions does NOT bypass the trust-this-folder dialog, stored in ~/.claude.json at .projects[PATH].hasTrustDialogAccepted; before every claude launch workers pre-mark the leased worktree via _claude_trust_path (lib/common.sh) or an untrusted path silently wedges startup.
- Adding a canopy CLI agent-launch path (claude -p --append-system-prompt "$(_agent_body X)")? Re-parse the def's frontmatter model: and pass it via --model yourself — _agent_body (lib/agent.sh) strips frontmatter, so the model: line is LOST on every CLI path (lib/review.sh, lib/consult.sh do this; _agent_model in consult.sh is the parser). No model: line = omit --model, inherit.

### Watch, mode & multi-project

- macOS: the launchd merge-watcher can't read repos under ~/Documents|Desktop|Downloads (TCC 'Operation not permitted' — cd works but reads fail); grant Full Disk Access to /bin/bash or keep repos elsewhere. 'canopy watch status' detects it; 'canopy recover' reconciles merges in-session as a fallback.
- Orchestrator autonomy is session-wide: resolve it with `canopy mode --global`, which reads the HOME repo's `.mode` (the git repo whose `projects/` contains cwd, via `_home_root` in lib/project.sh) and SUPERSEDES each routed project's own stored `.mode` — flip it with a bare `canopy mode yolo|guided` in the home repo, never per project. `--global` is read-only and returns the current repo's mode in single-repo use.
- Multi-project: any git repo directly under `<home>/projects/` is a routed project (name=basename; scanned by `_project_repos`, `project ls`/`path`, and `recover`/`status`/`watch --all`); canopy itself is the orchestrator HOME and must never be placed under its own `projects/`.

### Experimental & tooling (Herdr · Lavish)

- Herdr interactive workers are experimental-only (herdr-preview channel); on stable 'canopy worker' has ONLY spawn/fix/logs/idle/stop — start/attach/send/status/read/resume/reconcile/close/clean exit 2 via _worker_experimental_only. test/no_herdr_test.sh greps lib/+bin/ for _herdr_/canopy_herdr_, so never name a new symbol with an _herdr_ substring.
- To render a diagram INSIDE a Lavish file (incl. "make it Excalidraw"), put Mermaid in a `<pre class="mermaid">` container plus the theme-aware init from `lavish-axi design` (diagram_tooling.mermaid_cdn_snippet) — Lavish auto-converts a rendered Mermaid diagram into an editable Excalidraw whiteboard in-browser (click to edit). Do NOT pre-render to static SVG or hand-author `.excalidraw` JSON, and the CDN Mermaid ESM module IS the supported path (not a hang to route around). Read `lavish-axi playbook diagram` + `lavish-axi design` first. In the container use backtick markdown-string multiline labels, never `<br/>` — the init parses the container's `textContent`, which strips real HTML tags.
