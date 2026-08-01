# PRD — Canopy: an orchestration layer for AI coding agents

| | |
|---|---|
| **Working name** | Canopy (the forest layer above the `treehouse` worktrees). Final name TBD — see Open Question 3. |
| **Status** | Draft. Design de-risked (Phase 0 run and passed). Not yet built. |
| **Owner** | Rhyu Miranda |
| **Date** | 2026-08-01 |
| **Related** | `docs/research/orchestrator-market-research.md`, `docs/research/orchestrator-technical-research.md`, `.lavish/orchestration-layer-architecture.html` (visual map) |

---

## 1. TL;DR

Working a single project with many AI agent windows means most of your energy goes to *managing agents*, not to the work — you lose track of what each session did. Canopy adds a supervisor layer one level above the workers: a single orchestrator that holds the plan, spins up isolated work, has an **independent** agent review the result, runs a never-exit quality loop, ships a high-empathy PR, and only interrupts you for a real decision. You steer everything from one seat.

A close prior-art exists — [`firstmate`](https://github.com/kunchenguid/firstmate) (MIT) — but a code read plus its ~22k-token always-on cost (inherent to its "agent distro" model) means we **build clean on cheaper patterns and harvest its MIT scripts**, rather than fork it. Canopy's net-new value (and the market gap) is the **independent diff-only reviewer + never-exit review→fix→test→lint loop**, delivered lean.

---

## 2. Problem

- One project, many Claude windows. You lose track of what each session did.
- Constant context-switching; threads tangle and get mixed up.
- Most effort is spent *supervising agents* rather than delivering.
- Clearing/compacting a session to reclaim context loses the plan and task state.
- Letting an agent review its own work is an echo chamber — it rubber-stamps itself.

## 3. Goals

1. One seat to run many agents on one project without losing the thread.
2. Task context and state survive a context wipe (`/clear`, compaction, crash, reboot).
3. Safe parallelism — multiple tasks at once with zero cross-task collisions.
4. Independent review that can't rubber-stamp itself.
5. Nothing ships until it's clean, tested (without breaking unrelated features), and linted.
6. High-empathy PRs; CI green before merge.
7. The human can navigate to any worker and steer/interrupt it.
8. Durable knowledge compounds across tasks.

## 4. Non-goals

- Not a hosted/cloud multi-tenant product (local-first, single operator).
- Not a replacement for CI — it *uses* CI as a gate.
- Not org-wide fleet scale in v1 (the local-first pieces graduate to webhooks later; see §11).
- The orchestrator itself never edits code.

## 5. Users & primary use case

A single developer/operator (Rhyu) running Claude Code on a laptop, working one project at a time but fanning several tasks out in parallel. Wants to delegate, review, and ship without babysitting each agent.

---

## 6. Product overview

An orchestrator (a Claude Code session) that, from an intent:

1. Writes a **brief + state** to `.canopy/` (durable, survives context wipe).
2. Leases an isolated **worktree** per task from the `treehouse` pool.
3. Spawns a **worker** subagent to implement in that worktree — one task per worker, many in parallel.
4. Spawns a **fresh, independent reviewer** that sees only the git diff.
5. Loops review → fix → tests+orthogonality → lint until the reviewer reports zero issues.
6. Opens a high-empathy **PR** via `gh-axi`; blocks on CI green.
7. A single external **merge-watcher** detects merge, returns the worktree to the pool, marks the task done.
8. `/scribe` distills durable project knowledge into `AGENTS.md`.

Two diagrams (flow + runtime topology) live in `.lavish/orchestration-layer-architecture.html`.

---

## 7. Locked decisions

| Decision | Choice |
|---|---|
| Base: fork or build clean | **Build clean** — firstmate's ~22k-token always-on contract is inherent to its distro model (poor fit for a cost-sensitive tool). See `docs/research/firstmate-evaluation.md`. |
| Quality gate | **Lean, in-house gate.** Evaluated `no-mistakes`/`ship-and-sleep` (independent review, git-layer enforced) but **rejected — too slow and token-heavy**: a multi-round LLM pipeline (review+test+lint+docs+PR) whose spend scales with diff × fix rounds. Instead: (a) the **worker runs deterministic checks itself** — `test · lint · typecheck · build` = 0 LLM tokens — and (b) **one bounded independent diff-review** (fresh non-`fork` reviewer, cheap model, ~2 rounds cap) preserves the no-echo-chamber differentiator; (c) CI re-runs the checks on the PR. See `docs/research/no-mistakes-evaluation.md` for why the heavy gate was rejected. |
| Orchestrator | A Claude Code CLI session (not the Agent SDK — the SDK has no human-steering UI). Delegates; never edits code. |
| Worktrees | `treehouse` worktree **pool** — lease per task, `return` on merge (keeps build cache). |
| Worker isolation | cwd = the treehouse-leased path, raw `git`. **Never** Claude's `isolation: worktree`. |
| Worker spawn | `claude --bg` detached sessions (tracked by id in `state.json`) so they survive an orchestrator `/clear` and stay navigable in agent view. Pending Phase 0b (confirm `--bg` doesn't collide with a treehouse lease). |
| Reviewer | A fresh **non-`fork`** subagent, diff-only, never sees the worker's context. |
| Tests & lint | The **worker** runs them itself (deterministic commands, no extra agent, no context bloat). Not an echo chamber. |
| Modes | Global toggle via slash command. `/yolo` = autonomous; Guided = surface architectural decisions to the human. Third mode TBD (§14). |
| State source of truth | `.canopy/` files on disk. |
| Context survival | A SessionStart hook re-injects a ≤10k-char digest on `startup·resume·clear·compact`; the orchestrator also reads `.canopy/` every turn (redundant safety). |
| Merge-watcher | One external OS-scheduled tick (launchd/cron) running `gh-axi`; not a hand-babysat daemon. Webhook at org scale. |
| GitHub ops | `gh-axi` (agent-ergonomic wrapper). |
| Knowledge capture | `/scribe` slash command → durable, project-intrinsic facts appended to `AGENTS.md`. |
| Human steering | Native Claude Code subagent windows (FleetView); `herdr` multiplexer if outgrown. |
| Parallelism | One task per worker; many worktrees concurrently. |

---

## 8. Functional requirements

### 8.1 Orchestrator
- Runs as `claude` with Edit/Write denied (via `permissions.deny` or a locked-down `--agent`).
- Reads `.canopy/state.json` at the top of every turn.
- Delegates all code work to subagents; aggregates their results.
- Only surfaces to the human when a decision needs human input (Guided mode) or per §8.6.

### 8.2 `.canopy/` state (source of truth)
```
.canopy/
├── brief.md          # human intent — the north star
├── state.json        # live task board (source of truth)
└── tasks/<id>.json   # one file per task, full detail
```
`state.json` (authoritative):
```json
{
  "updated": "<iso8601>",
  "mode": "guided",            // or "yolo"
  "tasks": [
    { "id": "t1", "title": "...", "status": "reviewing",
      "worktree": ".treehouse/…/1/repo", "branch": "...", "pr": 41 }
  ]
}
```
`status` enum: `planning | implementing | reviewing | testing | linting | pr-open | merged | done | blocked`.

Placement: `.canopy/` is **data**; it is NOT under `.claude/`. The SessionStart hook (configured in `.claude/settings.json`, user-level) only *reads* `.canopy/state.json`.

### 8.3 Worktree pool (`treehouse`)
- Lease: `treehouse get --lease`; release: `treehouse return`; inspect: `treehouse status`; clean: `treehouse prune`.
- One branch per task, no shared edits.
- On merge, the worktree returns to the pool (deps/build cache preserved).

### 8.4 Worker subagent
- Spawned as a `claude --bg` detached session; cwd = leased worktree; raw `git`.
- Implements the task; fixes bugs it hits; **runs tests and lint itself** and fixes red results in place.
- **Documents the change** in the same diff — keeps the project's own docs (README, `docs/`, comments, changelog) in sync (no extra LLM pass; this is no-mistakes' "document" step, done leanly). Distinct from `/scribe` (§8.10).
- Re-invoked (attach / message by id) whenever the reviewer or a gate sends work back.
- Detached so an orchestrator `/clear` doesn't kill it (see §8.12). Even if a worker dies, its committed worktree + `state.json` make progress recoverable — re-spawn on the same leased worktree.

### 8.5 Lean quality gate (built in-house, deterministic-first)
- **Deterministic checks (0 LLM tokens):** the worker runs `test · lint · typecheck · build` itself and fixes red results in place. CI re-runs them on the PR as a backstop. These catch most problems for free.
- **One bounded independent review (the only LLM step):** the orchestrator spawns ONE fresh non-`fork` diff-only reviewer (a cheap model is fine), run after the deterministic checks are green. It also verifies the change's **docs are in sync** (§8.4). If it finds real issues → worker fixes → re-run the (free) deterministic checks → at most one more review. Cap ~2 review rounds to bound cost.
- This preserves the no-echo-chamber differentiator (Phase 0 proved the fresh reviewer's context isolation) **without** a multi-round LLM pipeline.
- Explicitly NOT `no-mistakes`/`ship-and-sleep` — those are too slow/token-heavy (see §7).

### 8.6 Modes (global)
- `/yolo`: reviewer resolves architectural decisions and fixes them itself; no human gate.
- Guided (default): architectural decisions are surfaced to the orchestrator → human decides → orchestrator delegates the decision back to the worker → re-review.
- Third mode: TBD (candidate: plan-only / dry-run that stops before edits) — Open Question 2.

### 8.7 Quality gauntlet (never-exit loop)
Order: **diff review → (goal pass/fail) → tests + orthogonality → lint → PR.**
- Any failure routes work back to the worker, then re-enters diff review.
- Loop never exits until the reviewer reports zero issues.
- **Orthogonality:** the change must add behavior without breaking unrelated features — the reason tests run here, not merely "does it work."
- The "goal" gate (pass/fail) — build vs adopt and exact checks are Open Question 4.

### 8.8 PR contract (built for the reviewer's empathy)
Template carries: conventional-commit title (actionable, clear); summary; description (what + why); linked items with GitHub tags (bug/issue/feature); full list of touched files.
Ship criteria: atomic; breaking changes flagged explicitly; explicit repro/test steps; CI/CD green.
Automation: `gh-axi pr create` + `gh-axi` watch checks to block on CI green.

### 8.9 Merge-watcher
- **One** external OS-scheduled tick (launchd on macOS / cron), not per project, not a daemon.
- Every ~60s runs a small `gh-axi` script: for each open PR in `state.json`, if merged → `treehouse return` + set `status=done`.
- Stateless between runs (reads/writes `.canopy/state.json` only). Survives `/clear` and reboot; OS is the supervisor.
- **Wake model:** does not push into a running session (no reliable external→session inject in Claude Code). Orchestrator reconciles on its next turn. For a genuine nudge, the watcher fires an OS notification.
- Scale: fine to a few dozen PRs / few repos; graduate to a GitHub App webhook → hosted worker for org/always-on scale.

### 8.10 Scribe (`/scribe`)
- Slash command the operator invokes.
- Distills all agents' learnings and appends only **durable, project-intrinsic** facts to `AGENTS.md` — never task-level notes.
- Two gates (mirroring the operator's memory rule): *non-obvious* AND *changes future action*.
- `AGENTS.md` auto-loads for every agent, so knowledge compounds.
- **Not the same as the "document" step (§8.4):** `/scribe` = durable cross-task learnings (post-merge, not tied to a diff); "document" = the project's own docs for *this* change. Both exist; no overlap.

### 8.11 Human steering
- Workers appear as steerable/interruptible subagent windows (FleetView) under the input box.
- The operator can navigate to any worker and steer or interrupt one drifting off-plan.
- `herdr` multiplexer as an alternative if the native panel is outgrown.

### 8.12 Session lifecycle — `/clear` and `/compact` (verified vs docs)
- **`/compact` is safe.** It only summarizes the orchestrator's own history; workers are unaffected (their transcripts are separate files) and panes persist. This is the routine way to reclaim orchestrator context.
- **`/clear` kills in-session subagents.** Agent-tool subagents are co-scoped to the parent, so `/clear` terminates them and their panes vanish; background tasks aren't restored on resume.
- **`claude --bg` detached sessions survive `/clear`** (supervisor-managed, separate processes) and stay navigable in agent view, resumable by id. → workers are spawned this way (§8.4).
- **Durability backstop:** because `state.json` and the committed worktree persist, no path loses real work — a killed worker is recovered by re-spawning on the same leased worktree.
- Design posture: lean on `/compact`; treat `/clear` as rare.

---

## 9. Architecture

- **Substrate:** one interactive Claude Code CLI session (orchestrator) + one external `gh-axi` tick (merge-watcher).
- **On the machine:** the orchestrator session (Edit/Write denied) with a subagent panel (workers + fresh reviewer + Scribe); `.canopy/` and the `treehouse` pool on disk; a SessionStart hook; the external merge-watcher.
- **GitHub (cloud):** PRs + CI.
- The one boundary that must sit *outside* the session: the merge-watcher.

Concept → mechanism table and both diagrams: see `docs/architecture-map.html`. Full component mapping with confidence + citations: `docs/research/orchestrator-technical-research.md`.

### 9.1 Where the playbook lives (config, not memory)
The agents don't remember the process between sessions — it's written into config Claude Code auto-loads every session, and the must-happen steps are hook-enforced. `canopy setup` installs all of this once, user-level.

| Layer | Holds | Loaded | Guarantee |
|---|---|---|---|
| Agent definitions (`~/.claude/agents/*.md`) | Each role's job/tools/model. The orchestrator's system prompt **is** the playbook; worker/reviewer/scribe each have theirs. | on spawn / `--agent` | soft (model follows) |
| Skills / slash commands | Packaged step-by-step workflows: `/yolo`, `/scribe`, a `/canopy` task runner. | when invoked | soft |
| `CLAUDE.md` / `AGENTS.md` | Durable always-on rules & conventions (ground rules, `/scribe` knowledge). | every session, auto | soft |
| Hooks (`settings.json`) | Deterministic automation the harness runs: state re-inject (SessionStart), never-exit loop (Stop/SubagentStop exit-2), block PR until reviewer verdict recorded. | on events | **hard (guaranteed)** |
| `.canopy/state.json` | Where each task is → the next step. | read every turn | data |

**Design principle:** put *judgment* in prompts/skills (flexible, can drift); put *guarantees* in hooks (deterministic, harness-enforced). The loop-can't-exit-early, must-re-inject-state, and no-PR-before-clean-review rules are hooks, not prompt wishes.

---

## 10. Build plan

### Phase 0 — de-risk (DONE, passed 2026-08-01)
Ran the two scary unknowns with real `treehouse` + real Claude subagents in a throwaway repo:
- **Worktree collision:** a plain worker pointed at a treehouse-leased worktree committed inside it and created **no** `.claude/worktrees/`. The collision only occurs if you opt into Claude's `isolation: worktree` (that agent landed in `.claude/worktrees/agent-<id>` on its own locked branch). → **Avoidable by the ground rule below.**
- **Context isolation:** a fresh reviewer given only the diff had zero knowledge of the worker's in-context secret. → **Independent review holds by construction** (never `fork`).
- Bonus: Claude-managed worktrees auto-clean when left unchanged.

**Phase 0b (also passed):** a live `claude --bg` session launched with cwd = a treehouse-leased worktree (no `-w`) ran *inside* the leased worktree, made its edit there, and created no `.claude/worktrees/`. The CLI confirms `-w/--worktree` is opt-in. → `claude --bg` workers are safe under the same ground rule; no collision.

### Phase 1 — walking skeleton
1. `.canopy/` with `brief.md` + `state.json` + one hand-written `tasks/<id>.json`.
2. Orchestrator = `claude --agent orchestrator` (Edit/Write denied), spawns ONE worker subagent pointed at a treehouse-leased worktree.
3. Spawn ONE fresh reviewer subagent on `git diff`; loop review → fix (via `SendMessage`) until zero issues.
4. `gh-axi pr create`; human merges (no watcher yet).
5. **Exit criteria:** brief → PR entirely through subagents; orchestrator never edits; reviewer context provably fresh.

### Phase 2+ (subsequent)
- Add the never-exit test+lint gates (worker-run) and orthogonality check.
- Add the external merge-watcher tick + `treehouse return`.
- Add modes (`/yolo`, Guided) as slash commands writing `mode` to `state.json`.
- Add `/scribe`.
- Add the SessionStart digest hook.
- Parallelize N tasks.

---

## 11. Ground rules (locked by Phase 0 — non-negotiable)

1. Workers **never** use Claude's `isolation: worktree` / EnterWorktree. Lease via `treehouse`; plain worker at the leased path; raw `git`.
2. The reviewer is **never** a `fork` subagent (that is the independence guarantee).
3. The merge-watcher lives **outside** the session (external `gh-axi` process) — anything in-session dies on `/clear`.

---

## 12. Risks & mitigations

| Risk | Status |
|---|---|
| Worktree double-management (Claude vs treehouse) | **Retired** — avoidable by Ground Rule 1 (proven in Phase 0). |
| In-model watchers not durable (die on `/clear`) | **Retired** — merge-watcher is an external OS-scheduled process. |
| SessionStart re-injection contract unknown | **Retired** — pinned: fires on `startup·resume·clear·compact`; `hookSpecificOutput.additionalContext` ≤10k; digest + `.canopy/` read is the redundancy. |
| No external→session push (can't proactively wake orchestrator) | **Accepted** — turn-based reconciliation + optional OS notification. |
| Local-first pieces don't scale org-wide | **Accepted for v1** — graduate merge-watcher to webhook + hosted worker at scale. |
| `/clear` kills in-session workers | **Mitigated** — spawn workers as `claude --bg` (survive `/clear`); durability backstop via `state.json` + committed worktree. `/compact` is safe regardless. |
| `claude --bg` worktree collision | **Open (Phase 0b)** — Phase 0 cleared this for in-session subagents; not yet verified for `--bg`. |

---

## 13. Success criteria

- From a written brief, the system produces a merged PR with the orchestrator never editing code.
- Reviewer independence is demonstrable (fresh context each review).
- A task's state survives a `/clear` and a compaction with no loss.
- Two+ tasks run in parallel with no worktree/merge collisions.
- On merge, the worktree returns to the pool automatically and the task is marked done.
- `/scribe` produces only durable, non-task-level entries in `AGENTS.md`.

---

## 14. Open questions

**None open — all resolved.**
- Review budget → **1 bounded independent review** per task (cheap model, default Haiku, configurable).
- Modes → **two only**: YOLO (autonomous) + Guided (human-gated). No third mode.
- Name → **`Canopy` / `.canopy/`** confirmed.
- Worker spawn → **`claude --bg`** (cwd = leased worktree, no `-w`); **Phase 0b passed** (§10) — no collision.
- Quality gate → **lean in-house** (deterministic checks + one bounded review); `no-mistakes`/`ship-and-sleep` rejected as too token-heavy (§7, §8.5).
- Base → **build clean** (not fork firstmate) (§7).

Next step: scaffold the Phase-1 walking skeleton (§10) in the `canopy` repo, with Grid as the test subject.

---

## 15. Distribution & multi-project setup

Canopy is meant for **all** the operator's projects, not just this repo. It ships as a CLI (like `treehouse`), and setup is split so the heavy part is done once:

- **`canopy setup` — once, user-level.** Installs the orchestrator agent definition, the `/yolo` and `/scribe` slash commands, the SessionStart digest hook, and the launchd/cron merge-watcher into user-level `~/.claude/` (+ launchd). Applies to every project automatically. Matches the earlier "one watcher, user-level hook" decisions.
- **`canopy init` — per repo (one-liner).** Creates `.canopy/` (with `brief.md` + `state.json`) and ensures `treehouse` is initialized for that repo. The only per-project step; may be auto-run on the first task.
- **Onboarding another project:** `cd other-repo && canopy init`, then run the orchestrator there. Nothing else to wire up.

(`treehouse` remains a separate prerequisite install; `canopy init` ensures it's initialized per repo.)

## 16. References

- firstmate code evaluation: `docs/research/firstmate-evaluation.md`
- no-mistakes (quality gate) evaluation: `docs/research/no-mistakes-evaluation.md`
- Market landscape & build-vs-adopt: `docs/research/orchestrator-market-research.md`
- Technical mapping, Phase 0 results, hook contract: `docs/research/orchestrator-technical-research.md`
- Visual map (2 diagrams): `.lavish/orchestration-layer-architecture.html`
- [`treehouse`](https://github.com/kunchenguid/treehouse) · [`firstmate`](https://github.com/kunchenguid/firstmate) · Claude Code hooks: code.claude.com/docs/en/hooks
