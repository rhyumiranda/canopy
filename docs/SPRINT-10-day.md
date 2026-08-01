# Canopy — 10-Day Build Sprint

**Goal:** ship a working Canopy that takes a brief → merged PR entirely through agents, orchestrator never editing, on the lean gate, with parallel tasks — proven on GRID.

**Definition of done (sprint):** from one seat, kick off 2+ parallel tasks on GRID; each runs in an isolated `treehouse` worktree via a `claude --bg` worker that implements → documents → runs deterministic checks → gets one bounded independent review → opens a `gh-axi` PR → CI green → auto-merge-watch → `treehouse return` + done. Token spend ≈ deterministic checks + one small review per task.

**Pre-reqs (already true):** Phase 0 + 0b passed; `treehouse`, `gh-axi`, `claude` v2.1+ installed; `canopy` repo initialized; GRID is the test subject.

**Stack (Day 1 decision, recommended):** thin glue in **bash + `jq`** (matches the `treehouse`/`gh-axi` ecosystem, zero build step) for state + spawning + watcher; all *behavior* lives in **Claude Code config** — agent defs (`~/.claude/agents/*.md`), skills (`/yolo`, `/scribe`, `/canopy`), and hooks. Keep the binary surface tiny.

**Daily rule:** every day ends with something runnable on GRID. Watch token spend each day — deterministic-first is the whole point.

**Legend:** 🎯 day goal · 📦 deliverable · ✅ acceptance · ↳ PRD ref

---

## Day 1 — Foundations & state layer ✅ DONE
🎯 Repo skeleton + `.canopy/` state is real and durable. ↳ PRD §6, §7.2, §11

- [x] Stack = bash + `jq`. `bin/canopy` CLI + subcommand router (`init`, `status`, `task add/set/status/show`, `mode`, `version`).
- [x] `.canopy/` layout: `brief.md`, `state.json`, `tasks/<id>.json`. Schemas documented in `lib/state.sh` header.
- [x] State helpers (`lib/common.sh` + `lib/state.sh`): atomic write (temp+rename), `task_add/set/status/log/show`, `state_board/mode`. Status enum enforced.
- [x] `canopy init`: creates `.canopy/`, seeds `state.json`, gitignores `.canopy/`, ensures `treehouse init`. Idempotent; rejects malformed state.
- [x] `test/run.sh` — 25 assertions, all green (id sequencing, status validation, unknown-task guard, mode, durability across a fresh process, malformed-state rejection).
- 📦 `canopy init` verified on GRID (state.json correct, board works); Grid left pristine.
- ✅ Met: init → `.canopy/` exists, board prints, state survives a fresh process.

## Day 2 — Agent definitions (the playbook) ✅ DONE
🎯 The three roles exist as Claude Code agents; orchestrator can't edit. ↳ PRD §6, §7.1/7.4/7.5, §8, §10

- [x] `agents/orchestrator.md`: playbook prompt (read `.canopy/` first, delegate, drive the loop, guided/yolo).
- [x] **Scoped** edit denial: orchestrator's `tools:` list has **no Edit/Write** → it structurally can't hand-edit files; mutates `.canopy/` only via the `canopy` CLI. (Hard Bash-write-to-project-tree hook = Day 8.)
- [x] `commands/hotfix.md`: fast isolated worker escape hatch. Fallbacks (plain session, hand-edit `state.json`) documented in PRD §7.1.
- [x] `agents/worker.md`: implement → document → deterministic checks → commit; forbids `-w`/extra worktrees.
- [x] `agents/reviewer.md`: fresh non-`fork`, diff-only, Haiku, structured JSON verdict + docs-in-sync.
- [x] Ground rules encoded in each prompt.
- [x] `test/agents_test.sh` — 14 assertions green (frontmatter, scoped-deny, worktree rule, verdict schema).
- [x] Live check: a Haiku reviewer on a planted-bug diff returned valid JSON, caught the correctness bug + `docs_in_sync:false`, no worker context (~8s, ~17k tok).
- ↳ Full "orchestrator refuses to edit" end-to-end verifies after `canopy setup` installs the agents (Day 9) + the hard hook (Day 8).

## Day 3 — treehouse + worker spawning ✅ DONE
🎯 Orchestrator leases a worktree and drives a `claude --bg` worker end-to-end (no gate yet). ↳ PRD §7.3/7.4, §10, §12

- [x] `lib/worktree.sh`: `lease` (treehouse + creates `rhyu/<id>-<slug>` branch, stores path+branch on task), `return`, `path`.
- [x] `lib/worker.sh`: `spawn` = `claude --bg` (cwd = leased path, **no `-w`**, appends worker agent prompt); session id parsed + stored in `worker_session`; `logs`, `stop`.
- [x] `worker logs`/`stop` by task-id or session; `worker_send` (message/resume for the review loop) lands Day 5 where it's used.
- [x] Wired: brief → lease → spawn → worker commits. `test/worktree_test.sh` — 8 assertions green.
- [x] Collision re-confirmed in the real flow: no `.claude/worktrees/`.
- 📦 **Live smoke passed:** brief "add greet()" → worker committed `feat: add greet(name) helper` in ~21s — correct `greet.js` + README updated (document step already working) in the leased worktree, no collision.
- ✅ Met on a scratch repo end-to-end via the CLI; branch + worker id tracked in state.

## Day 4 — Worker pipeline: document + deterministic checks
🎯 The worker self-gates for free (0 LLM tokens beyond its own work). ↳ PRD §2, §7.4, §7.5

- [ ] Per-project checks config (`.canopy/checks.json` or read from repo): the `test`, `lint`, `typecheck`, `build` commands (GRID's real commands).
- [ ] Worker step: **document the change** in the same diff (README/`docs/`/comments/changelog as relevant).
- [ ] Worker step: run the deterministic checks itself, fix red in place, loop until green; record results in the task.
- [ ] Handle "no such check" gracefully (skip missing commands, log it).
- [ ] Guard: worker commits only when checks are green.
- 📦 Worker produces a green, documented commit with zero orchestrator LLM cost for the checks.
- ✅ On GRID: a task that touches code updates its docs and passes `test/lint/typecheck/build` before committing; a deliberately-broken change is caught + fixed by the worker.

## Day 5 — Lean gate: one bounded independent review
🎯 The differentiator — independent review, cheap, bounded. ↳ PRD §2, §7.5, §10

- [ ] `review_run`: spawn the fresh `reviewer` (cheap model) on `git diff base..head` only; parse structured verdict.
- [ ] Loop: verdict has issues → `worker_send` the issues → worker fixes → re-run free deterministic checks → re-review. **Cap 2 review rounds**; on cap, mark `blocked` + surface.
- [ ] Reviewer also verifies docs-in-sync (fail if code changed but docs didn't, where expected).
- [ ] Enforce independence: reviewer never receives worker transcript; never a `fork`.
- [ ] Log per-task review token cost to sanity-check "lean".
- 📦 The review→fix→re-check loop converges within the cap.
- ✅ On GRID: a diff with a planted issue is caught by the reviewer, fixed by the worker, and passes on round 2; token cost per task ≈ one small review.

## Day 6 — PR + first full end-to-end 🚩 MILESTONE
🎯 Brief → PR, entirely through agents (Phase 1 exit criteria). ↳ PRD §5, §7.7, §12

- [ ] PR body builder: conventional title, what/why, linked items (tags), touched files, repro/test steps, breaking-change flag.
- [ ] `gh-axi pr create` from the worker's feature branch; store PR number in state; set `pr-open`.
- [ ] Block on CI green (`gh-axi` watch checks) before declaring the task shippable.
- [ ] Run the **whole Phase-1 skeleton** on GRID: brief → lease → worker(implement/document/checks) → bounded review → PR → CI green. Human merges manually (watcher is Day 7).
- [ ] Verify Phase-1 exit criteria: orchestrator never edited; reviewer context provably fresh; lean token spend.
- 📦 **First real PR opened by Canopy on GRID.**
- ✅ A GRID brief yields a green, well-formed PR with the orchestrator never touching code; you review + merge it by hand.

## Day 7 — Merge-watcher (external, durable)
🎯 Merges auto-close the loop without a babysat daemon. ↳ PRD §7.8, §10, §13

- [ ] `canopy-watch` script: read all `pr-open` tasks from `state.json`, `gh-axi` check each → on merge, `treehouse return` + `status=done`; stateless between runs.
- [ ] Install as **launchd** (macOS) job (~60s); verify it survives `/clear` and a reboot.
- [ ] OS notification on merge (nudge; no external→session push).
- [ ] Orchestrator reconciles `done` tasks on its next turn (turn-based).
- [ ] Rate-limit sanity: fine for a few dozen PRs; note the webhook upgrade path.
- 📦 Merge a Canopy PR → within ~a minute the worktree returns + task flips to done, untouched by the session.
- ✅ On GRID: merge the Day-6 PR; the launchd tick returns the lease + marks done; `/clear` the orchestrator and confirm the watcher kept working.

## Day 8 — Modes + hard-guarantee hooks
🎯 YOLO/Guided + the non-negotiables enforced by the harness, not the model. ↳ PRD §7.6, §8

- [ ] `/yolo` slash command: toggle `mode` in `state.json` (global). Guided = default.
- [ ] Guided path: a decision needing a human → orchestrator uses `AskUserQuestion` → delegates the answer back to the worker → re-review. YOLO path: apply review fixes autonomously.
- [ ] SessionStart hook: emit a ≤10k digest of `state.json` as `additionalContext` (fires on `startup·resume·clear·compact`). Test the digest on a compaction.
- [ ] Guardrail hooks: block the PR step until a review verdict is recorded; enforce the ≤2-round loop (Stop/SubagentStop). 
- [ ] Verify: judgment lives in prompts, guarantees in hooks.
- 📦 Modes switch cleanly; state re-injects after `/clear`; the gate can't be skipped.
- ✅ `/clear` the orchestrator mid-sprint → it re-orients from the digest and resumes; a forced attempt to open a PR without a review is blocked by the hook.

## Day 9 — /scribe, parallelization, steering, setup
🎯 Knowledge compounding + true parallel fan-out + one-command install. ↳ PRD §7.9/7.10, §11, §12

- [ ] `/scribe` slash command: distill agents' learnings → append durable, project-intrinsic facts to `AGENTS.md`, gated (*non-obvious* + *changes future action*). Never task-level.
- [ ] Parallel fan-out: orchestrator runs N tasks = N leased worktrees + N `claude --bg` workers concurrently; state tracks each; only summaries return.
- [ ] Verify human steering: navigate/interrupt any worker in agent view (FleetView); resume by id.
- [ ] `canopy setup`: install agents + `/yolo`/`/scribe`/`/canopy` + SessionStart hook + launchd watcher into user-level `~/.claude/` — once, all projects.
- 📦 Two tasks run in parallel; `/scribe` writes one real AGENTS.md line; `canopy setup` makes it work in a second repo.
- ✅ On GRID: 2 parallel briefs → 2 isolated worktrees, no collisions, both reach PR; `canopy init` a second repo and confirm zero extra setup.

## Day 10 — Hardening, E2E, docs 🚩 MILESTONE
🎯 Prove the whole thing + make it usable. ↳ PRD §13, §14

- [ ] Canopy's own test suite green (state, spawn, review loop, watcher).
- [ ] Full **multi-task E2E on GRID**: 2+ parallel briefs → merged PRs → auto teardown → done, orchestrator never editing.
- [ ] Token-spend audit vs the Day-0 target (deterministic + one review/task); trim any surprise costs.
- [ ] Failure-mode pass: killed worker recovers from state+worktree; blocked task surfaces; malformed state recovers.
- [ ] Polish: README quickstart, `canopy setup`/`init` docs, troubleshooting; update the architecture map if anything shifted.
- [ ] Sprint retro → next-cycle backlog (webhook watcher, more modes, etc.).
- 📦 **Canopy v0.1 — a working, documented, tested orchestration layer.**
- ✅ Success criteria (PRD §14) all demonstrably met on GRID.

---

## Milestones
- **Day 6:** first brief → PR end-to-end (Phase 1 exit).
- **Day 7:** merge auto-closes the loop.
- **Day 10:** parallel multi-task E2E, tested + documented (v0.1).

## Cut-scope levers (if behind)
Drop first, in order: parallel fan-out (Day 9) → run tasks serially; `canopy setup` polish → manual install; `/scribe` → defer; extra PR-body fields. **Never cut:** worktree isolation, the independent review, the external watcher, or the deterministic-first rule — they're the core.

## Watch-items
- Keep token spend deterministic-first every day; if a step wants an LLM, ask "can a command do it?"
- Re-verify Ground Rules (§10) hold in each new flow (esp. no `-w` / no `isolation: worktree`).
- The merge-watcher must stay an external OS process — never a Monitor/in-session loop.
