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

## Day 4 — Worker pipeline: document + deterministic checks ✅ DONE
🎯 The worker self-gates for free (0 LLM tokens beyond its own work). ↳ PRD §2, §7.4, §7.5

- [x] `lib/checks.sh`: config resolution is **worktree-visible** — committed `canopy.json` `.checks` override, else auto-detect from `package.json` scripts / `tsconfig.json` / `Makefile`. (`.canopy/` is main-tree-only, so config can't live there.)
- [x] `canopy checks run [dir]` (non-zero if any fail) + `canopy checks show`. `null`/absent checks skipped; empty repo = no-op success.
- [x] Worker prompt updated to prefer `canopy checks run` (fallback: infer + run directly). Document step already lands in the same diff (proven Day 3).
- [x] `test/checks_test.sh` — 8 assertions green (override, pass/fail, package.json auto-detect, skip-null, empty no-op).
- [x] `test/all.sh` runner; **full suite green: 55 assertions** (25+14+8+8).
- 📦 Worker self-gates deterministically at 0 LLM cost; commit gated on green (enforced by the worker prompt; hard hook = Day 8).
- ✅ Met: `canopy checks run` passes on green, fails on red, auto-detects real project checks.

## Day 5 — Lean gate: one bounded independent review ✅ DONE
🎯 The differentiator — independent review, cheap, bounded. ↳ PRD §2, §7.5, §10

- [x] `lib/review.sh` `canopy review <id>`: computes diff (`merge-base..HEAD`), spawns a fresh **Haiku** one-shot reviewer (`claude -p`) on the diff only, extracts + validates the structured verdict, logs it, exits 0 clean / 1 issues.
- [x] `_extract_json` tolerates fenced / chatty model output; verdict schema-checked.
- [x] `canopy worker fix <id> <issues>`: spawns a fresh worker in the same worktree to fix, re-run checks, re-commit. The **≤2-round loop is driven by the orchestrator prompt** (canopy provides the primitives).
- [x] Independence structural: reviewer is a separate `claude -p` process on the diff — no worker transcript, never a `fork`.
- [x] `test/review_test.sh` — 5 assertions green (JSON extraction bare/fenced/chatty, body load, default-branch). **Full suite = 60 green.**
- 📦 **Live-verified:** clean change → `verdict: clean, docs_in_sync: true`; planted `mul()` bug (adds instead of multiplies) → `verdict: issues, severity high`. Cheap Haiku, ~seconds.
- ↳ Full live fix-loop-to-green + token audit rolls into the Day 6 end-to-end run.

## Day 6 — PR + first full end-to-end 🚩 MILESTONE ✅ DONE
🎯 Brief → PR, entirely through agents (Phase 1 exit criteria). ↳ PRD §5, §7.7, §12

- [x] `lib/pr.sh` `_pr_body`: conventional title (from the worker's commit), Summary, What & why, Files changed (diff --stat), Testing note, Canopy footer.
- [x] `canopy pr open <id>`: pushes the branch, `gh-axi pr create`, parses + stores PR#, sets `pr-open`.
- [x] `canopy pr checks <id>`: `gh-axi pr checks` → 0 green/none, 1 fail, 2 pending; gracefully handles "no CI configured".
- [x] **Live E2E on the testbed** (not Grid, per the safe path): brief → lease → `claude --bg` worker (implement + document + `npm test`) → Haiku review → PR.
- [x] Phase-1 exit criteria met: orchestrator never edited; review ran on a fresh process; lean spend (worker + one Haiku review).
- 📦 **First real PR: `rhyumiranda/canopy-testbed#1` "feat: add subtract() to mathlib"** — worker committed in ~18s, `npm test` green (add + subtract), review `clean`, structured PR body.
- ✅ Met on the testbed end-to-end via the CLI.

## Day 7 — Merge-watcher (external, durable) ✅ DONE
🎯 Merges auto-close the loop without a babysat daemon. ↳ PRD §7.8, §10, §13

- [x] `lib/watch.sh` `canopy watch once`: reconciles all `pr-open` tasks — merged (keyed on `state: merged`) → `treehouse return` + `status=done`. Stateless. `canopy watch` = foreground loop (testing only).
- [x] `canopy watch install`: writes a per-repo launchd plist (~60s `StartInterval`, `RunAtLoad`, logs to `.canopy/watch.log`) and prints the exact `launchctl` commands — **does NOT load it** (you run launchctl).
- [x] `_notify`: opt-in desktop notification (`CANOPY_NOTIFY=1`); else logs. Orchestrator reconciles `done` on its next turn (turn-based).
- 📦 **Live-verified on the testbed:** merged real PR #1 → `watch once` detected it → worktree returned to the pool (treehouse shows it `available`) → task flipped to `done`. Installer wrote the plist and left launchd untouched (0 jobs loaded); test plist removed.
- ↳ Fix found + applied: merge detection keys on `state:` (the `merged:` field is a timestamp, not yes/no); merge should not `--delete-branch` while the worktree holds it — teardown is the watcher's `treehouse return`.

## Day 8 — Modes + hard-guarantee hooks ✅ DONE
🎯 YOLO/Guided + the non-negotiables enforced by the harness, not the model. ↳ PRD §7.6, §8

- [x] `commands/yolo.md`: `/yolo [yolo|guided]` toggles `mode` via the `canopy` CLI. Guided default; guided path uses AskUserQuestion (in the orchestrator prompt).
- [x] `hooks/session-start-digest.sh`: emits `hookSpecificOutput.additionalContext` (≤10k, hard-capped) digest of `state.json`; no-op outside a canopy repo. Wired via `dist/settings-hooks.json` matcher `startup|resume|clear|compact`.
- [x] **Hard gate (code-level, better than a hook):** `canopy review` records `reviewed=<verdict>`; `canopy pr open` refuses unless `reviewed=clean` (override `CANOPY_SKIP_REVIEW=1` for hotfix/budget-0).
- [x] `hooks/guard-project-write.sh`: PreToolUse(Bash) — blocks the orchestrator writing to the project tree (`>`, `sed -i`, `tee`, `git apply`, `cp/mv/rm`…), allows `.canopy/`+`/tmp`+read-only+`canopy` CLI; active only when `CANOPY_ROLE=orchestrator`.
- [x] `test/hooks_test.sh` — 12 assertions green. **Full suite = 72 green.**
- 📦 Modes toggle; digest re-injects; PR can't be opened unreviewed; orchestrator writes to the tree are blocked.
- ↳ Hooks are authored + settings snippet ready; `canopy setup` (Day 9) installs them into `~/.claude` (you run it).

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
