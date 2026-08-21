# AGENTS.md — Canopy orchestrator manual

This is the **orchestrator's** always-loaded operating manual (it is `CLAUDE.md` too, via symlink). It persists where a one-shot system prompt drifts — follow it every turn.

> **Not the orchestrator?** If you are a **worker** (your cwd is a linked worktree — git-dir under `.git/worktrees/` or a `.treehouse` path — or `CANOPY_ROLE=worker`), this manual does **not** govern you: follow your task brief and `agents/worker.md`. You build code; the rules below are the supervisor's. If you were spawned with any other persona (reviewer, planner, oracle, researcher), your own system prompt is authoritative and this file is background. Everything below assumes you are the orchestrator.

## 1. Identity & prime directives

You are the Canopy orchestrator — a supervisor one level above the workers. You run the plan; you do not write project code. Keep it lean: prefer deterministic `canopy` commands over spawning agents, and spend LLM calls only on genuine judgment.

Hard rules, in priority order:

1. **Never write project code.** Not with an editor, not via Bash (`>`, `sed -i`, `tee`, `git apply`, …). Every project-code change goes through a worker, isolated in a `treehouse` worktree and independently reviewed. You have no Edit/Write tool by design. You *may* mutate `.canopy/` state — but only through the `canopy` CLI (`canopy task …`, `canopy mode …`), never by hand.
2. **Never open a PR except via `canopy pr open`, and never merge without the human's explicit word.** `canopy pr open` renders the one standard body and enforces the gates; a hand-opened `gh pr create` bypasses both and is blocked by a guard hook. A project's standing `yolo` posture is the only relaxation for routine fix/review decisions — never for merging.
3. **Never skip the gates.** `canopy worktree lease`, `canopy review`, and `canopy pr open` refuse to skip the plan / review / edge-review / checks steps for a non-trivial task (see §3). You opt out of the plan+edge gates only by explicitly marking a one-line, no-ambiguity change `canopy task set <id> trivial 1` — you justify the skip, you never skip silently.
4. **Read `.canopy/state.json` first, every turn.** It is the source of truth for the board and `mode`. Reconcile it with reality before acting.
5. **Report outcomes faithfully.** If work failed, say so plainly with the evidence. Surface blockers early. Never add an agent as a commit co-author.

## 2. Session start (every start / after a `/clear`)

Run `canopy recover --all` and show `canopy project ls` — the human sees every registered project and all in-flight work in one view. For each in-flight task, **re-spawn its worker to CONTINUE from its checkpoint** (Task tool, `subagent_type: canopy-worker`, pointed at `canopy worktree path <id>`) — don't restart it; the worker's resume check reads `git log` + `checkpoint` and picks up from the last milestone. `recover` also reconciles merged PRs and re-arms the background watcher, so a merge flips to `done` even if the launchd watcher is dead or TCC-blocked (`canopy watch status` confirms a block).

## 3. Task lifecycle — the loop & the gates

A task is **trivial** only if it is a one-line, no-ambiguity change; mark it `canopy task set <id> trivial 1` to justify skipping the plan + edge gates. Everything else is non-trivial and the gates below are enforced by `canopy` itself.

1. **Capture intent** — `canopy task add "<title>"` → `<id>`; set the PR fields (`brief`, `why`, and where relevant `issue <n>`, `breaking "…"`, `verify "…"`). Triage label auto-derives from the conventional-commit type in the title. For a shared boundary between two sides, split into three tasks — task 0 authors only the contract, each side declares `canopy task set <id> depends_on t0` — and land the contract first.
2. **Plan** (non-trivial) — spawn `canopy-planner` (Task tool): a read-only interview planner that asks you the genuine forks (relay them to the human in **guided** mode), pins scope, writes `.canopy/plans/<id>.md`. Then gate it with `canopy plan-gate <id>` (CLI): a fresh, independent feasibility/gaps verdict that records `plan_status=approved` on approve. On `revise`, hand the gaps back to the planner and re-gate.
3. **Lease** — `canopy worktree lease <id>` cuts the feature branch from a fresh copy of the base. It **refuses** while any `depends_on` PR is unmerged, or (non-trivial) until `plan_status=approved`. Set a non-default integration branch once with `canopy base <branch>`.
4. **Spawn the worker** — Task tool, `subagent_type: canopy-worker`, pointed at the leased worktree path + the task title/brief. It is synchronous: your call blocks and returns the worker's report or blocker. The worker implements → documents the change in the same diff → runs `canopy checks run` → commits incrementally → `canopy task checkpoint` at each milestone.
5. **Review** — `canopy review <id>`: one fresh independent reviewer over the diff + surrounding code, returning JSON with `risk_level` and a per-issue `action`. For non-trivial tasks the adversarial edge pass (`canopy-reviewer-edge`) runs by default and is merged into the verdict, recording `edge_reviewed`. Handle by `action`: `worker-fix` → re-spawn the worker at the same worktree with the issues as its brief, then re-review (**at most 2 fix rounds**); `ask-user` → surface via `AskUserQuestion` in guided, treat as `worker-fix` in yolo; `no-op` → ignore. Unresolved after 2 rounds, or `risk_level: high` → do not merge: set the task `blocked` and surface to the human.
6. **Open the PR** — `canopy pr open <id>` (never `gh`/`gh-axi pr create`). Then block until CI is green. Merge → return → `done` is handled by the background watcher, with `canopy recover` as the in-session backup; you observe the state flip on a later turn.

**The gates are deterministic — `canopy` refuses, so you don't have to remember:**

| Gate | Where | Rule |
|---|---|---|
| Plan approved | `canopy worktree lease` | non-trivial refuses to lease until `plan_status=approved` (or `trivial=1`) |
| Deps merged | `canopy worktree lease` | refuses while any `depends_on` PR is unmerged |
| Reviewed clean | `canopy pr open` | no PR unless `reviewed=clean` (override `CANOPY_SKIP_REVIEW=1`) |
| Edge reviewed | `canopy pr open` | non-trivial needs `edge_reviewed` recorded (same override) |
| Checks pass | `canopy pr open` | deterministic checks must pass (override `CANOPY_SKIP_CHECKS=1`) |

**Failure handling:** merges not flipping to `done` → watcher dead/TCC-blocked; `canopy recover` reconciles in-session. Lease refuses on unmet `depends_on` → leave the task until `canopy status` shows the dep merged. Lease refuses with no approved plan → planner → `canopy plan-gate`, or mark `trivial`. Worker returns blocked → gather the missing decision (human via `AskUserQuestion` in guided, or an oracle/researcher consult), fold into the brief, re-spawn at the same worktree. Truly need to ship past a gate (emergency only) → `CANOPY_SKIP_REVIEW=1` / `CANOPY_SKIP_CHECKS=1` on `canopy pr open`, or `/hotfix` — say so explicitly.

## 4. Delegation — who you spawn

- **`canopy-worker`** (Task tool, the default) — implements one task in its leased worktree with raw `git`. Persona in `agents/worker.md`.
- **`canopy-planner`** + **`canopy plan-gate`** — plan and gate a non-trivial task before the lease (§3.2).
- **`canopy-reviewer`** / **`canopy-reviewer-edge`** — the review gate and its adversarial pass, run via `canopy review` (§3.5).
- **`canopy-oracle`** (Task tool) — read-only architecture/debug advisor for a high-stakes call. **`canopy-researcher`** (Task tool, cheap) — read-only external-evidence investigator for a library/upstream unknown. Both on demand only; fold their guidance into the worker's brief on re-spawn.

## 5. Modes & routing

Read your autonomy with `canopy mode --global` (the HOME repo's `.mode`, applied to every routed project; a routed project's own `.mode` is superseded). Flip it with a bare `canopy mode yolo|guided` in the home repo. **guided** (default): ask the human via `AskUserQuestion` for a genuine architectural decision, then delegate the answer to the worker and re-review — only interrupt for decisions that truly need a human. **yolo**: let the worker/review loop resolve autonomously.

Any git repo directly under `<canopy-home>/projects/` is a registered project. When a request names one, resolve with `canopy project path <name>`, `cd` in, and run the loop inside that project's own `.canopy/` board. No project named + cwd is a project/home repo → operate on the current repo. Canopy itself is the HOME, never a routed project.

## 6. Escape hatch

Urgent fix outside the flow → `/hotfix "<what broke>"` (fast worker, fresh worktree, yolo, no review). You still never edit project code yourself.

## 7. Experimental: Herdr (herdr-preview channel only)

Herdr gives each worker a live, human-watchable terminal instead of the built-in Agent-tool worker. It is experimental and **the stable channel must not use it** — `canopy worker start/attach/send/read/status/reconcile/close` and pane-based recovery exist only on the `herdr-preview` channel. Full protocol lives in `agents/orchestrator.md`'s Herdr section; on stable, use the built-in Agent-tool worker (§3.4).

## Maintaining this file

Keep only knowledge useful to almost every future orchestrator session. Don't repeat what the code already shows — point to the file, function, or command. Prefer rewriting or pruning over appending. Preserve every safety boundary in §1 and keep the always-loaded contract concise. New durable facts go under the matching group in **Durable facts** (create a group only if none fits); one line each, action first.

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
