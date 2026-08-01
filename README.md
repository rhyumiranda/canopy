# Canopy — Product Requirements Document

> An orchestration layer for AI coding agents. One supervisor holds the plan, runs isolated work in parallel, gates it leanly and independently, ships a clean PR, and only interrupts you for a real decision.

| | |
|---|---|
| **Name** | Canopy (the forest layer above the `treehouse` worktrees). State dir: `.canopy/`. |
| **Status** | Final design. De-risked (Phase 0 + Phase 0b passed). Ready to build Phase 1. |
| **Owner** | Rhyu Miranda |
| **Repo** | `github.com/rhyumiranda/canopy` · workspace `/Users/rhyu/Documents/Repository/utils/rhyu/canopy` |
| **Test subject** | GRID (`/Users/rhyu/Documents/Repository/Work/Grid`) |
| **Date** | 2026-08-01 |

> **Status: v0.1 built.** The 10-day sprint is implemented and tested (see `docs/SPRINT-10-day.md`). This document is the full design/PRD; the Quickstart below is how you run it.

---

## Quickstart

**Prereqs:** [`treehouse`](https://github.com/kunchenguid/treehouse), `gh-axi`, `claude` (v2.1+), `jq`, `git`.

**Install (once, user-level):**
```bash
git clone https://github.com/rhyumiranda/canopy.git && cd canopy
./bin/canopy setup            # copies agents/commands/hooks -> ~/.claude, symlinks canopy onto PATH
export PATH="$HOME/.local/bin:$PATH"   # if not already
# then start the merge-watcher when you want it (canopy prints the exact command):
canopy watch install          # writes a launchd plist; run the printed launchctl command to load it
```

**Per project (one line):**
```bash
cd your-repo && canopy init    # creates .canopy/, ensures treehouse
```

**Run a task** (the orchestrator agent normally drives this; the raw CLI):
```bash
id=$(canopy task add "add a /health endpoint")
canopy task set "$id" brief "…what & why…"
canopy worktree lease "$id"        # isolated treehouse worktree + feature branch
canopy worker spawn "$id"          # claude --bg worker: implement -> document -> checks -> commit
canopy review "$id"                # one bounded independent (Haiku) diff review
canopy pr open "$id"               # gh-axi PR (blocked unless review is clean)
# a launchd tick runs `canopy watch once`: on merge -> treehouse return + status=done
canopy status                      # the board
```

**Modes:** `/yolo` (autonomous) vs guided (default). **Knowledge:** `/scribe` appends durable facts to `AGENTS.md`. **Urgent fix:** `/hotfix "<what broke>"`.

Full CLI: `init · status · task · mode · worktree · worker · checks · review · pr · watch · scribe · setup`.

---

## 1. Problem

Working one project with many AI agent windows means most energy goes to *managing agents*, not the work. You lose track of what each session did; context-switching tangles threads; clearing a session to reclaim context loses the plan; and letting an agent review its own work is an echo chamber. Canopy adds a supervisor one level above the workers so you steer everything from one seat.

## 2. Goals

1. One seat to run many tasks on one project without losing the thread.
2. Task context + state survive a context wipe (`/clear`, compaction, crash, reboot).
3. Safe parallelism — many tasks at once, zero cross-task collisions.
4. Independent review that can't rubber-stamp itself — kept **cheap**.
5. Nothing ships until it's documented, checks pass (without breaking unrelated features), and CI is green.
6. The human can navigate to any worker and steer/interrupt it.
7. Durable knowledge compounds across tasks.
8. **Lean by default** — cheap patterns everywhere; minimal token spend.

## 3. Non-goals

- Not a hosted/cloud multi-tenant product (local-first, single operator).
- Not a replacement for CI — it *uses* CI as a gate.
- Not org-wide fleet scale in v1 (local-first pieces graduate to webhooks later).
- The orchestrator never edits code.

## 4. User & primary use case

A single developer (Rhyu) running Claude Code on a laptop, working one project at a time but fanning several tasks out in parallel across multiple projects over time.

---

## 5. Overview — the loop

From an intent, the orchestrator:

1. Writes a **brief + state** to `.canopy/` (durable, survives a context wipe).
2. Leases an isolated **worktree** per task from the `treehouse` pool.
3. Spawns a **`claude --bg` worker** to implement in that worktree — one task per worker, many in parallel.
4. The worker **implements → documents the change → runs deterministic checks itself → commits** on a feature branch.
5. A **lean gate** runs: deterministic checks (already green from step 4, re-affirmed by CI) + **one bounded independent diff-review**.
6. On issues → worker fixes → re-run (free) checks → at most one more review. Then open a **PR** via `gh-axi`; block on CI green.
7. One external **merge-watcher** detects merge → `treehouse return` → mark the task done.
8. `/scribe` distills durable, cross-task knowledge into `AGENTS.md`.

Diagrams (flow + runtime topology): `docs/architecture-map.html`.

---

## 6. Locked decisions

| Decision | Choice |
|---|---|
| Base | **Build clean.** firstmate was evaluated but rejected — its ~22k-token always-on contract is inherent to its distro model (`docs/research/firstmate-evaluation.md`). |
| Substrate | One interactive **Claude Code CLI session** as orchestrator (not the Agent SDK — no human-steering UI), plus one external `gh-axi` process for the merge-watcher. |
| Orchestrator | Edit/Write denied; delegates; never edits code. |
| State source of truth | `.canopy/` files on disk. A SessionStart hook re-injects a ≤10k-char digest on `startup·resume·clear·compact`; the orchestrator also reads `.canopy/` every turn (redundancy). |
| Worktrees | `treehouse` pool — lease per task, `return` on merge. Worker cwd = leased path, raw `git`. **Never** Claude's `isolation: worktree` / `-w`. (Phase 0 + 0b proven.) |
| Workers | `claude --bg` detached sessions (survive `/clear`), tracked by id in `state.json`. One task per worker; many in parallel. |
| Quality gate | **Lean, in-house.** `no-mistakes`/`ship-and-sleep` rejected — too slow/token-heavy. Instead: worker runs deterministic checks itself (`test·lint·typecheck·build` = 0 LLM tokens) + **one bounded independent diff-review** (fresh non-`fork` reviewer, cheap model default Haiku, cap ~2 rounds) + CI backstop. |
| Document step | The **worker** keeps the project's own docs in sync with the change (README/`docs/`/comments/changelog) in the same diff — no extra LLM pass. Distinct from `/scribe`. |
| Modes | **Two only** — YOLO (autonomous) and Guided (human-gated). Global `/yolo` toggle. |
| PR + merge-watcher | `gh-axi` for PRs; ONE external launchd/cron tick reconciles all open PRs → `treehouse return` + `status=done`. Not per-project, not a babysat daemon. |
| Knowledge capture | `/scribe` → durable, project-intrinsic facts to `AGENTS.md`; gated by *non-obvious* + *changes future action*. |
| Human steering | Native `claude --bg` agent view (FleetView); `herdr` optional. |

---

## 7. Functional requirements

### 7.1 Orchestrator
Runs as `claude`. Reads `.canopy/state.json` at the top of every turn. Delegates all **project-code** work to `claude --bg` workers so every change is isolated in a worktree + reviewed; aggregates results. Surfaces to the human only when a decision needs input (Guided mode).

**"Never edits" is scoped, not total — and has an escape hatch** (addresses the "what if I'm stuck" risk):
- The edit restriction covers only the **project working tree**. The orchestrator freely edits `.canopy/` state and Canopy's own config. Implement via `permissions.deny` on Edit/Write to the repo tree (allow `.canopy/`), or a locked `--agent`.
- `/hotfix "<what broke>"` spawns a *fast* worker (fresh worktree, YOLO, review budget 0) for urgent fixes — still isolated, but immediate.
- Fallback: the operator can always open a plain Claude session / editor to fix anything, and hand-edit `.canopy/state.json` if the orchestration wedges. Everything is files + git, so nothing is ever truly locked.

### 7.2 `.canopy/` state (source of truth)
```
.canopy/
├── brief.md          # human intent — the north star
├── state.json        # live task board (source of truth)
└── tasks/<id>.json   # one file per task, full detail
```
`state.json`:
```json
{
  "updated": "<iso8601>",
  "mode": "guided",            // or "yolo"
  "tasks": [
    { "id": "t1", "title": "...", "status": "reviewing",
      "worktree": ".treehouse/…/1/repo", "branch": "...", "pr": 41,
      "worker_session": "1f4c39c7" }
  ]
}
```
`status` enum: `planning | implementing | documenting | checking | reviewing | pr-open | merged | done | blocked`.
`.canopy/` is **data**; it is NOT under `.claude/`. The SessionStart hook (in user-level `~/.claude/settings.json`) only *reads* it, emitting a ≤10k digest.

### 7.3 Worktree pool (`treehouse`)
Lease `treehouse get --lease`; release `treehouse return`; inspect `status`; clean `prune`. One branch per task; on merge the worktree returns to the pool (deps/build cache preserved).

### 7.4 Worker
A `claude --bg` detached session; cwd = leased worktree; raw `git`; tracked by id in `state.json`. Per task it: **implements** → **documents the change** (project docs, same diff) → **runs deterministic checks itself** (`test·lint·typecheck·build`, fixing red in place) → **commits** on a feature branch. Re-invoked (attach/message by id) when the review sends work back. Detached so an orchestrator `/clear` doesn't kill it; even a killed worker loses no work (recover from `state.json` + committed worktree). Never uses Claude's `isolation: worktree` / `-w`.

### 7.5 Lean quality gate
- **Deterministic checks (0 LLM tokens):** run by the worker (§7.4); CI re-runs them on the PR as the backstop. These catch most problems for free.
- **One bounded independent review (the only LLM step):** the orchestrator spawns ONE fresh non-`fork` diff-only reviewer (cheap model, default Haiku) after checks are green. It reads only the diff and verifies the change's docs are in sync. Issues → worker fixes → re-run free checks → at most one more review (cap ~2 rounds). Preserves the no-echo-chamber guarantee (Phase 0 proved the fresh reviewer's context isolation) with no multi-round LLM pipeline.
- Explicitly NOT `no-mistakes`/`ship-and-sleep` (too token-heavy).

### 7.6 Modes (global)
- **YOLO:** the review's fixes are applied autonomously; no human gate.
- **Guided (default):** a decision that needs a human is surfaced to the orchestrator via AskUserQuestion → human decides → orchestrator delegates back to the worker → re-review.
`/yolo` is a slash command writing `mode` to `state.json`.

### 7.7 PR contract
Via `gh-axi`. Title: conventional-commit, actionable. Body: summary; what + why; linked items with GitHub tags (bug/issue/feature); touched files. Criteria: atomic; breaking changes flagged explicitly; explicit repro/test steps; CI/CD green. Built for the reviewer's empathy.

### 7.8 Merge-watcher
ONE external OS-scheduled tick (launchd on macOS / cron), not per project, not a daemon. Every ~60s a small `gh-axi` script checks each open PR in `state.json`; on merge → `treehouse return` + `status=done`. Stateless between runs (reads/writes `.canopy/state.json`). Survives `/clear` + reboot (OS-supervised). **Wake model:** it does not push into a running session — the turn-based orchestrator reconciles on its next turn; for a nudge it fires an OS notification. **Scale:** fine to a few dozen PRs / few repos; graduate to a GitHub webhook + hosted worker at org scale.

### 7.9 Scribe (`/scribe`)
A slash command the operator invokes. Distills all agents' learnings and appends only **durable, project-intrinsic** facts to `AGENTS.md` — never task-level notes. Gates: *non-obvious* AND *changes future action*. `AGENTS.md` auto-loads for every agent, so knowledge compounds. **Distinct from the document step (§7.4):** `/scribe` = durable cross-task learnings (post-merge, not tied to a diff); "document" = the project's own docs for *this* change.

### 7.10 Human steering & session lifecycle
Workers are `claude --bg` sessions, navigable/interruptible in agent view (FleetView); `herdr` optional. `/compact` is safe (workers unaffected, panes persist). `/clear` kills in-session subagents but **`claude --bg` workers survive** (supervisor-managed, resumable by id) — the reason workers are `--bg`. Durability backstop: `state.json` + committed worktree.

---

## 8. Where the playbook lives (config, not memory)

The agents don't remember the process between sessions — it's written into config Claude Code auto-loads, with the must-happen steps hook-enforced. `canopy setup` installs it once, user-level.

| Layer | Holds | Guarantee |
|---|---|---|
| Agent defs (`~/.claude/agents/*.md`) | Each role's job/tools/model; the orchestrator's prompt **is** the playbook. | soft |
| Skills / slash commands | `/yolo`, `/scribe`, a `/canopy` task runner. | soft |
| `CLAUDE.md` / `AGENTS.md` | Durable always-on rules + `/scribe` knowledge. | soft |
| Hooks (`settings.json`) | State re-inject (SessionStart); enforce the bounded-review gate; block PR until a review verdict is recorded. | **hard** |
| `.canopy/state.json` | Where each task is → the next step. | data |

**Principle:** judgment in prompts/skills (flexible); guarantees in hooks (deterministic).

---

## 9. Architecture

- **On the machine:** the orchestrator session (Edit/Write denied) + `/scribe`; detached `claude --bg` workers; the lean gate (worker-run deterministic checks + one bounded reviewer subagent); `.canopy/` + `treehouse` pool + `AGENTS.md` on disk; the SessionStart hook; the external `gh-axi` merge-watcher.
- **GitHub (cloud):** PRs + CI.
- The one boundary that must sit *outside* the session: the merge-watcher.

Full concept→mechanism mapping with citations: `docs/research/orchestrator-technical-research.md`.

---

## 10. Ground rules (locked by Phase 0/0b — non-negotiable)

1. Workers **never** use Claude's `isolation: worktree` / `-w`. Lease via `treehouse`; worker cwd = leased path; raw `git`.
2. The reviewer is **never** a `fork` subagent (the independence guarantee).
3. The merge-watcher lives **outside** the session (external `gh-axi` process).

---

## 11. Distribution & multi-project setup

Canopy ships as a CLI (like `treehouse`).
- **`canopy setup`** — once, user-level. Installs the orchestrator agent, `/yolo` + `/scribe`, the SessionStart hook, and the launchd/cron merge-watcher into `~/.claude/` (+ launchd). Applies to every project.
- **`canopy init`** — per repo, one line. Creates `.canopy/` and ensures `treehouse` is initialized. May auto-run on the first task.
- Onboarding another project: `cd other-repo && canopy init`, then run the orchestrator.

---

## 12. Build plan

**Phase 0 — de-risk (DONE, passed).** Real `treehouse` + real Claude subagents in a scratch repo:
- Worktree collision is **opt-in** — a plain worker on a leased path creates no `.claude/worktrees/`; only Claude's `isolation: worktree` spawns a rival tree. → avoidable by Ground Rule 1.
- Context isolation confirmed — a fresh non-`fork` reviewer given only the diff had zero knowledge of the worker's secret. → independent review holds by construction.

**Phase 0b — `claude --bg` (DONE, passed).** A live `claude --bg` session with cwd = a leased worktree (no `-w`) ran inside it, edited there, and created no `.claude/worktrees/`. CLI confirms `-w` is opt-in. → `--bg` workers are safe under Ground Rule 1.

**Phase 1 — walking skeleton.**
1. `.canopy/` with `brief.md` + `state.json` + one `tasks/<id>.json`.
2. Orchestrator = `claude --agent orchestrator` (Edit/Write denied) spawns ONE `claude --bg` worker on a `treehouse`-leased worktree; worker implements → documents → runs deterministic checks.
3. Orchestrator spawns ONE fresh diff-only reviewer (cheap model), bounded ~2 rounds; worker fixes.
4. `gh-axi pr create`; human merges (no watcher yet).
5. **Exit criteria:** brief → PR entirely through workers; orchestrator never edits; reviewer context provably fresh; token spend near deterministic-only + one small review.

**Phase 2+.** External merge-watcher tick + `treehouse return`; `/yolo` + Guided modes; `/scribe`; SessionStart digest hook; parallelize N tasks; `canopy setup`/`init` CLI.

---

## 13. Risks

| Risk | Status |
|---|---|
| Worktree double-management (Claude vs treehouse) | **Retired** — opt-in; Ground Rule 1 (Phase 0 for subagents, Phase 0b for `--bg`). |
| In-model watchers not durable (die on `/clear`) | **Retired** — merge-watcher is an external OS process. |
| SessionStart re-injection contract | **Retired** — fires on `startup·resume·clear·compact`; `additionalContext` ≤10k → digest + `.canopy/` read redundancy. |
| `/clear` kills in-session workers | **Mitigated** — workers are `claude --bg` (survive); durability backstop via `state.json` + committed worktree. `/compact` is safe. |
| No external→session push (can't proactively wake orchestrator) | **Accepted** — turn-based reconciliation + OS notification. |
| Local-first pieces don't scale org-wide | **Accepted for v1** — graduate merge-watcher to webhook + hosted worker. |

---

## 14. Success criteria

- From a written brief, the system produces a merged PR with the orchestrator never editing code.
- Reviewer independence is demonstrable (fresh context each review).
- A task's state survives `/clear` and a compaction with no loss; `claude --bg` workers keep running.
- Two+ tasks run in parallel with no worktree/merge collisions.
- On merge, the worktree returns to the pool automatically and the task is marked done.
- Token spend per task ≈ near-free deterministic checks + one small review.
- `/scribe` produces only durable, non-task-level entries in `AGENTS.md`.

## 15. Open questions

**None — all resolved.** (Name `.canopy`; two modes; 1 bounded review, cheap model default Haiku; `claude --bg` workers; lean in-house gate; build clean.) Next: build Phase 1, Grid as the test subject.

## 16. References

- firstmate evaluation: `docs/research/firstmate-evaluation.md`
- no-mistakes (rejected gate) evaluation: `docs/research/no-mistakes-evaluation.md`
- Market landscape: `docs/research/orchestrator-market-research.md`
- Technical mapping + Phase 0/0b + hook contract: `docs/research/orchestrator-technical-research.md`
- Visual map (2 diagrams): `docs/architecture-map.html`
- Tools: [`treehouse`](https://github.com/kunchenguid/treehouse) · Claude Code hooks: code.claude.com/docs/en/hooks
