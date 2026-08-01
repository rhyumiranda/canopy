# firstmate as a base for Canopy — evaluation

Source read: `git clone --depth 1 https://github.com/kunchenguid/firstmate` (author "Kun Chen" /
`@kunchenguid`, MIT, HEAD commit `2026-08-01`). I read the actual code, not just the README:
`README.md`, `docs/architecture.md`, `bin/fm-spawn.sh`, `bin/fm-review-diff.sh`,
`bin/fm-project-mode.sh`, `bin/fm-brief.sh`, `bin/fm-pr-merge.sh`, `bin/fm-pr-poll.sh`,
`.claude/settings.json`, `.no-mistakes.yaml`, `.tasks.toml`, `.gitignore`, and `AGENTS.md`.

## TL;DR verdict

**BUILD-CLEAN, but harvest firstmate heavily** — confidence medium-high.

firstmate is not a runtime; it is an "agent distro": a directory of `AGENTS.md` + bash scripts +
Claude Code hooks that turns a plain harness into a fleet captain. Its ground-rule alignment is
genuinely high (treehouse worktrees, per-project modes + `+yolo`, `gh-axi` merge, it *is* a Claude
Code harness). In principle it is WRAP-able. But the new top constraint — cost — is where it fails
for us: firstmate's token expense is dominated by a **large always-on operating contract that is
inherent to the distro model** and **multiplied per secondmate home**, which is exactly the pattern
Canopy is built to avoid. You cannot wrap it thin; slimming the contract *is* a rewrite. So: build
Canopy clean, but lift firstmate's best *bash scripts and design patterns* (they're MIT and drop-in).

Note the ecosystem overlap: firstmate is built on the **same "axi" tooling Canopy already uses** —
`gh-axi`, `tasks-axi`, `quota-axi`, `no-mistakes`, `treehouse`. It is effectively a sibling project.
That makes its scripts easy to reuse and makes "build-clean with harvest" low-friction.

---

## What firstmate actually is (stack, install, architecture)

- **Stack:** pure Bash (~100 scripts in `bin/`, `fm-*`), plus a few TS harness extensions
  (`.pi/extensions`, `.opencode/plugins`) and JSON/YAML config. **No app, no daemon binary, no SDK.**
  The cloned repo *is* the product. README: "firstmate is not a model, not a harness, not a skill,
  not an MCP server, and not a CLI ... An agent distro is a portable directory of instructions,
  skills, tooling, policies, and state conventions."
- **Install/run:** `git clone`, `cd firstmate`, then launch a supported harness in the repo
  (`claude`, `grok --trust`, `pi`, codex, opencode). `AGENTS.md` (symlinked as `CLAUDE.md`) takes
  over as the always-loaded operating contract. Requirements: an authenticated `gh`, and a session
  backend CLI (tmux is the reference default).
- **Architecture (real entry points):**
  - `.claude/settings.json` — the Claude Code wiring: `SessionStart` nudge, `PreToolUse` guards,
    and a `Stop` hook pair (`fm-turnend-guard.sh` + `fm-claude-stop-autoarm.sh` with
    `asyncRewake:true, timeout:28800`). This is how firstmate hooks into Claude Code.
  - `bin/fm-spawn.sh` (1,725 lines) — dispatches a crewmate/scout/secondmate.
  - `bin/fm-watch.sh` — the zero-token bash supervision watcher.
  - `bin/fm-crew-state.sh` / `bin/fm-busy-lib.sh` — semantic per-worker busy/idle/dead state.
  - `bin/fm-backend.sh` + `bin/backends/{tmux,herdr,zellij,orca,cmux}.sh` — session-provider layer.
  - `AGENTS.md` (532 lines) — the always-loaded operating manual and routing index.
  - State on disk under `data/` (durable) and `state/` (volatile), both gitignored.

Flow: you talk only to the "first mate"; it writes a brief, spawns each task as an autonomous agent
in its own tmux window + treehouse worktree, a bash watcher supervises with near-zero tokens, and it
returns finished PRs / approved local merges / scout reports, then tears the worktree down.

---

## Token cost (priority dimension)

**The good news, and it's real:** firstmate's *supervision* is deliberately near-zero-token.
`bin/fm-watch.sh` is a bash loop that "sleeps on the fleet, classifies detected wakes in bash, and
wakes the first mate only when something is actionable" (`docs/architecture.md`). Classification,
busy-state, PR-merge polling, and staleness are all bash (`fm-classify-lib.sh`, `fm-crew-state.sh`,
`fm-pr-poll.sh`). Absorbed benign wakes "keep the watcher blocking without a queue record or LLM
turn." So the orchestration *loop* does not burn tokens idling — this matches Canopy's philosophy.

**Where the tokens actually go (cited):**

1. **A large always-on operating contract.** `AGENTS.md` is 59,838 chars ≈ **~15k tokens loaded on
   every session** (it's `CLAUDE.md` via symlink, so Claude Code reads it every turn's context).
   This is the single biggest fixed cost and it is present before you type anything.
2. **A materialized startup memory budget on top.** `AGENTS.md` line 73:
   `config/startup-memory-budget ... materialized as 7,500 estimated tokens by locked primary
   bootstrap and inherited into secondmate homes`. So ~7.5k tokens of memory is intentionally
   injected at startup, over and above the contract.
3. **Session-start digest re-injection.** `AGENTS.md` §146–148 has the bootstrap inject, every
   session, a **"Context digest"** = *full contents* of `projects.md`, `secondmates.md`,
   `captain.md`, `captain-shared.md`, `learnings.md`; plus a **"Fleet-state digest"** = compact
   backlog + **every** `state/<id>.meta` + a bounded tail of each task's `state/<id>.status` +
   a liveness read per task. They *did* engineer bounds here ("compact", "bounded tail", "cheap
   alive/dead read"), but it still grows with fleet size and with how big `captain.md`/`learnings.md`
   have gotten.
4. **Full interactive worker sessions.** The Claude launch template
   (`bin/fm-spawn.sh:465`) is:
   `CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION=false claude --dangerously-skip-permissions "<brief>"` —
   a full interactive TUI Claude session per task, each of which loads the target project's
   `CLAUDE.md` + the brief. (This per-worker cost is inherent to *any* multi-agent orchestrator,
   Canopy included — not firstmate-specific.)
5. **Multiplication by secondmates.** Each opt-in "secondmate" is *another full firstmate home* with
   its own always-on `AGENTS.md` + its own 7,500-token startup budget + its own crew
   (`docs/architecture.md`, "Optional secondmates"). Fixed cost is per-home, so a fleet of
   secondmates multiplies items 1–3.

**Net:** a firstmate primary carries roughly **~22k tokens of always-on fixed context (≈15k contract
+ ~7.5k startup budget) before any digest**, per home, before the workers even run. That, times
secondmates, times full-session workers, is the most plausible source of "costs a lot of tokens."

**Inherent or fixable?**
- The *supervision* cheapness is a keeper and is already how we'd want to do it.
- The *worker-session* cost is inherent to orchestration in general — not a firstmate defect.
- The *always-on contract* (items 1–3) is **inherent to the distro model**: `AGENTS.md` is not
  documentation you can trim, it *is* the behavior. Cutting it to hit Canopy's lean profile means
  rewriting the operating contract — i.e., a fork that discards most of firstmate's value. You cannot
  WRAP it thin. Secondmate multiplication is opt-out (just don't use them), but the base contract
  cost is not.

**Token-cost verdict:** cheap where it counts (bash supervision), but it carries a heavy, *inherent*
always-on contract (~22k tokens/home before work, ×secondmates) that can't be slimmed without
gutting the distro — a poor fit for a cost-sensitive, local-first Canopy.

---

## Fit against the 8 Canopy ground rules

### 1. Workers as `claude --bg` detached, tracked by id — PARTIAL (different mechanism)
firstmate does **not** use `claude --bg` and does **not** use headless `claude -p` (grepped `bin/` —
no `--bg`/`--print`/`--background` spawn). Instead `fm-spawn.sh` opens a session-backend window
(tmux by default), sends `treehouse get` into it (`bin/fm-spawn.sh:1296`), then sends the interactive
launch line `claude --dangerously-skip-permissions "<brief>"` (`:465`). Workers are **full
interactive TUI sessions living in tmux/herdr/etc. panes**, tracked by id in `state/<id>.meta`
(`window=`, `endpoint_task_id=`, `worktree=`, `harness=`, `kind=`, ...). They *do* survive the
orchestrator's `/clear` (separate panes; "kill the session anytime and the next one reconciles"),
which is the property you actually want — but the spawn substrate is a visible-terminal backend, not
`claude --bg`. Adopting firstmate wholesale means adopting its backend abstraction; keeping
`claude --bg` means replacing `fm-spawn.sh`'s launch/backends layer.

### 2. treehouse worktrees, raw git at leased path, never Claude `isolation: worktree` — PASS
This is firstmate's model exactly. "each task runs in a clean treehouse git worktree." The **worker
itself** runs `treehouse get` in its own pane to lease a worktree, then does raw `git` there — the
orchestrator never invokes Claude's own worktree isolation. `bin/fm-spawn.sh` "refuses to launch
unless the resolved task path is a real git worktree root distinct from the primary project
checkout" (validated via `validate_spawn_worktree`), and `fm-tangle-lib.sh` guards against a tangled
primary checkout. Zero collision risk with Canopy's rule; this is directly reusable.

### 3. Independent, non-fork, diff-only reviewer — PARTIAL
There is a **deterministic diff producer**, `bin/fm-review-diff.sh`, which fetches the authoritative
base (`refs/pull/<n>/head` when `pr=` is recorded, else `origin/<default>`) and prints stat+diff — no
model, no `fork`. But firstmate has **no separate orchestrator-spawned reviewer agent**. Its gating
review lives *inside* the external `no-mistakes` tool, which the **worker** runs in its own worktree;
no-mistakes internally spawns review/fix/document/test/lint/pr/ci sub-agents (`.no-mistakes.yaml`
references all of them). So "review" is worker-internal, not an independent fresh reviewer the
captain spawns. Clean integration point exists (see below), but the fresh-reviewer-as-separate-worker
is a thing you'd add, not inherit.

### 4. Never-exit quality loop (review→fix→test+lint→PR), hook-enforced — PARTIAL/PASS
The loop exists as the external **`no-mistakes`** pipeline (`.no-mistakes.yaml` pins `lint:
bin/fm-lint.sh`, keeps test evidence out of repo, sets `disable_project_settings: true`). firstmate
layers **hook-enforced "no turn ends blind"** on top: the `Stop` hooks in `.claude/settings.json`
(`fm-turnend-guard.sh`, `fm-claude-stop-autoarm.sh`) block/re-arm a blind stop while work is in
flight, and `bin/fm-guard.sh` warns on stale watcher / undrained wakes. So there *is* gating and it
*is* hook-enforced — but the review→fix→test→PR loop itself is no-mistakes' (worker-run), not a
firstmate-owned loop primitive. Canopy's loop would graft where no-mistakes is invoked in the brief.

### 5. State — Canopy `.canopy/` (brief.md + state.json + tasks/) — PARTIAL (adaptable, different shape)
firstmate splits state: `data/` (durable: `backlog.md` queue, `<id>/brief.md`, `captain.md`,
`learnings.md`, `secondmates.md`, `projects.md`) and `state/` (volatile: `<id>.meta`, append-only
`<id>.status`, watcher queues). Task metadata is **`state/<id>.meta` as `key=value` lines, not JSON**
(`AGENTS.md` line 93). Backlog is **markdown via `tasks-axi`** (`.tasks.toml` → `backend =
"markdown"`, `path = "data/backlog.md"`), not a `tasks/` dir. `brief.md` per task matches Canopy
directly. Concepts map cleanly (brief.md ✓, meta≈state.json, backlog≈tasks) but the **formats and
split differ** — reusable as inspiration, conflicting as literal on-disk schema.

### 6. Modes — `/yolo` vs guided — PASS
`data/projects.md` records per-project delivery mode + an orthogonal `+yolo` flag; parsed by
`bin/fm-project-mode.sh` → prints `"<mode> <yolo>"` where mode ∈ `no-mistakes|direct-PR|local-only`
and yolo ∈ `on|off`. yolo = "firstmate may make routine approval decisions itself"; authority
exceptions owned by `AGENTS.md` section 7. Maps almost one-to-one to Canopy's autonomous-vs-guided.
Directly reusable pattern.

### 7. PR + merge via `gh-axi`; external merge-watcher — PARTIAL/PASS
firstmate opens/merges via **`gh-axi`** (same tool Canopy uses): `bin/fm-pr-merge.sh` parses the
canonical `https://github.com/<owner>/<repo>/pull/<n>` URL, calls `gh-axi pr merge <n> --repo ...`,
defaults `--squash`, records `pr=`/`pr_head=`. **Merge detection differs from Canopy's launchd/cron:**
it's the same in-harness **bash watcher** running `bin/fm-pr-poll.sh` sidecars (which shell out to
`gh`/`glab`) — no external launchd/cron. Same tool, different watcher substrate (watcher armed by the
harness Stop hook, not a system timer). GitLab merge URLs are recognized for *watching* but refused
for *merging* (GitHub-only merge path today).

### 8. Config-driven playbook — is it a Claude Code harness we can WRAP? — PASS (this is the enabler)
Yes — firstmate **is** a Claude Code (and Grok/Pi/Codex/OpenCode) harness config, with **no separate
runtime**: `.claude/settings.json` hooks, `AGENTS.md`/`CLAUDE.md` contract, `.agents/skills/` +
`skills/`, and bash tooling. Everything is expressed in the same primitives Canopy uses (agent defs,
skills, CLAUDE.md, hooks). So technically Canopy *could* be layered as Claude Code config on top of
it. This is the one rule that keeps WRAP on the table — and it's why "harvest" is cheap even though
we build clean.

---

## Cleanest integration points (if we did extend it) — and the blockers that push build-clean

**3 clean integration points** for the reviewer + never-exit loop:
1. **Reviewer:** add a fresh non-fork reviewer as a new task `kind` spawned by the captain that runs
   `bin/fm-review-diff.sh <id>` (already deterministic, diff-only) and emits a verdict — slots beside
   the existing scout/ship shapes in `fm-spawn.sh` without touching the backend layer.
2. **Loop enforcement:** the `Stop`-hook pair in `.claude/settings.json` is the natural graft point
   for a "never exit until review passed + tests+lint green + PR open" gate; firstmate already blocks
   blind stops there (`fm-turnend-guard.sh`).
3. **Merge gate:** `bin/fm-pr-poll.sh` sidecar + `fm-pr-merge.sh` already give a deterministic
   merged/not-merged signal keyed to task meta — Canopy's merge-watcher can consume the same sidecar
   contract instead of reinventing it.

**3 biggest blockers to adopting it wholesale (why build-clean):**
1. **Inherent always-on token cost** (~22k/home before work, ×secondmates) that can't be slimmed
   without rewriting `AGENTS.md` — directly against Canopy's cost-sensitive/local-first goal.
2. **Spawn substrate mismatch:** interactive tmux-pane workers vs Canopy's `claude --bg` detached
   model — replacing this is replacing the heart of `fm-spawn.sh` + `bin/backends/`.
3. **Contract lock-in / surface area:** ~100 interlocking bash scripts + a 532-line contract that
   assume the full distro (secondmates, X mode, 5 backends, AFK daemon). Adopting it means owning all
   of it; most is surface Canopy doesn't want.

## What to harvest (MIT — copy the scripts/patterns, not the distro)
- `bin/fm-review-diff.sh` — deterministic PR-head-aware diff for the reviewer.
- `bin/fm-pr-poll.sh` + `bin/fm-pr-check.sh`/`fm-pr-lib.sh` — the restart-safe merged-PR sidecar
  (identity-bound receipts, "emit `merged` or stay silent on any error").
- `bin/fm-crew-state.sh` + `bin/fm-busy-lib.sh` — semantic busy/idle/dead worker state (verdict +
  source; never promote unknown→busy) — better than tailing rendered terminal text.
- The **zero-token bash watcher** design (`fm-watch.sh`, `fm-classify-lib.sh`, durable
  `state/.wake-queue` before detector state advances).
- `bin/fm-project-mode.sh` — the `[mode +yolo]` per-project registry parse.
- The treehouse-in-worker leasing pattern (`treehouse get` inside the worker's own pane) and the
  worktree-tangle guards (`fm-tangle-lib.sh`, `validate_spawn_worktree`).

## Maturity flags
- **Very fresh / possibly rebranded:** shallow clone shows a single squashed commit dated
  `2026-08-01` by "Kun Chen". Can't see real history depth from `--depth 1`, but the tree is large
  and coherent (not a toy), so this reads like an actively developed repo with a squashed/rewritten
  history rather than a one-commit hack.
- **Tests:** strong — **103 `*.test.sh`** files under `tests/` plus live e2e tests per backend and
  harness. Notable for a bash project.
- **Docs:** extensive — `docs/architecture.md` (deep), `configuration.md`, per-backend docs,
  supervision-protocols, verification docs, `CONTRIBUTING.md`.
- **License:** MIT (permissive — harvesting is fine).
- **Community:** Discord + X linked; single-author (`@kunchenguid` / Kun Chen). No visible
  shutdown/abandonment signals; bus-factor = 1.
- **Ecosystem tie:** depends on the author's own `treehouse`, `gh-axi`, `tasks-axi`, `quota-axi`,
  `no-mistakes` — the same tools Canopy uses, which is a plus for reuse but couples you to that
  toolchain if you adopt firstmate wholesale.

## Uncertainty / honesty
- I could not measure real token spend; the ~22k figure is derived from the stated 59,838-char
  `AGENTS.md` (~15k) + the documented 7,500-token startup budget, not from a live run. The digest is
  bounded by design, so steady-state per-wake cost may be lower than the cold-start figure.
- `--depth 1` hides commit cadence/contributor history; maturity read is from tree quality + tests.
- `no-mistakes`/`treehouse`/`*-axi` internals weren't read here — I treated them as the external
  black boxes firstmate calls; their own cost/behavior isn't assessed.
