# Orchestration Layer ("Canopy") — Technical Research & Build Plan

How to actually build a meta-supervisor over AI coding agents, using Claude Code as
the substrate. Every capability claim is cited or explicitly flagged **UNVERIFIED**.

Research date: 2026-08-01. Docs move fast; re-verify before building. Claude Code
docs now live under `code.claude.com/docs/en/...` (old `docs.claude.com/en/docs/claude-code/...`
URLs 301-redirect there). Agent SDK docs live under `code.claude.com/docs/en/agent-sdk/...`.

---

## 0. TL;DR

- **Substrate**: the orchestrator is a **single interactive Claude Code session**, not
  an Agent SDK program. The SDK buys you nothing the CLI lacks here and costs you the
  native human-steering UI (agent view / subagent panel). The **one long-lived piece
  that should NOT live inside the model** is the merge-watcher — run it as a plain OS
  background process (`gh` poll loop) that reads/writes `.canopy/` so it survives the
  orchestrator being cleared, compacted, or backgrounded.
- **Source of truth is disk** (`.canopy/`), never the model's context. The model is a
  stateless executor that reconstructs everything from `brief.md` + `state.json` on every
  turn. This is what makes "survives compaction" true instead of aspirational.
- **Biggest landmine**: Claude Code's own background sessions auto-create a worktree
  under `.claude/worktrees/` before editing. That collides conceptually with a
  treehouse-leased worktree. Resolve this first (see Risk R1).

---

## 1. Component-by-component mapping

Confidence: **High** = directly documented; **Med** = documented but composed in a way
the docs don't spell out; **Low/UNVERIFIED** = inferred or not found in docs.

| # | Concept piece | Concrete Claude Code mechanism | Confidence | Citation |
|---|---------------|-------------------------------|-----------|----------|
| 1 | Orchestrator delegates, never edits | Main session with `Agent` tool; deny `Edit`/`Write` on the main thread via `permissions.deny`, or run it as `claude --agent orchestrator` whose definition omits Edit/Write from `tools` | High | sub-agents (frontmatter `tools`, `--agent`); permissions |
| 2 | Persistent brief + state on disk | Plain files in `.canopy/`. Nothing model-side is durable; files are. Re-read at turn start (SessionStart hook injects them) | High (files) / Med (auto-reinject) | hooks (`SessionStart` fires on `startup`/`resume`/`clear`/`compact`) |
| 3 | Pooled isolated worktrees | External `treehouse` CLI: `get --lease`, `return`, `status`, `prune` (§4) | High | treehouse README |
| 4 | Parallel worker agents as steerable windows | **Primary**: background subagents with `isolation: worktree`, surfaced in the subagent panel + `/tasks`, steered by opening the row and typing, interrupted with Esc/`x`, resumed via `SendMessage`. **Alt for full-session windows**: `claude --bg` background sessions monitored in **agent view** (`claude agents`) — this is "FleetView". | High | sub-agents (background, panel, resume); agent-view |
| 5 | Fresh reviewer, diff only | A **non-fork** named subagent. Non-fork subagents "start with a fresh, isolated context window… doesn't see your conversation history." Give it read-only tools + `git diff`; never resume the worker into it | High | sub-agents ("What loads at startup") |
| 6 | Modes as slash-command skills (`/yolo`) | Slash command / skill that writes `mode` into `.canopy/state.json`; orchestrator branches on it. Guided decisions use `AskUserQuestion` — which **only the main session has** (filtered out of every subagent) | High | skills/commands; sub-agents (tool filter removes `AskUserQuestion`) |
| 7 | Never-exit gate loop | Orchestrator control loop over `state.json`; optionally enforced by `SubagentStop` / `Stop` hooks that exit code 2 to force another round | Med | hooks (Stop/SubagentStop, exit-2 semantics) |
| 8 | PR automation | `gh` in a Bash-capable step; `gh pr create`, `gh pr checks`, `gh run watch` | High | gh CLI (external) |
| 9 | One merge-watcher, all PRs | External `gh` poll loop as an OS background process writing `.canopy/state.json` → on merge, `treehouse return` + mark done. (In-model `Monitor` is possible but NOT durable — see R2) | High (poll) / Med (placement) | tools-reference (Monitor, background tasks); agent-view (Monitor stopped on backgrounding) |
| 10 | Fan out N tasks, no collisions/bloat | One leased worktree per task (no shared files) + one subagent per task; concurrency capped at 20 (`CLAUDE_CODE_MAX_CONCURRENT_SUBAGENTS`), 200/session; worker verbose output stays in worker context, only summaries return | High | sub-agents (concurrency/session limits, context isolation) |

---

## 2. Substrate decision: Claude Code session vs Agent SDK

**Recommendation: interactive Claude Code CLI session as the orchestrator.**

The Agent SDK "gives you the same tools, agent loop, and context management that power
Claude Code, programmable in Python and TypeScript" — it is Claude Code as a library
(source: agent-sdk/overview). Both expose subagents, hooks, MCP, sessions/resume, skills.
So the SDK is not *more capable*; it is the same engine minus the terminal UI.

What the interactive CLI gives you that matters here and the SDK does not:
- **The human-steering surface**: the subagent panel, `/tasks`, and **agent view**
  (`claude agents`) — peek/attach/interrupt live agents (requirements #4). The SDK has no
  UI; you'd rebuild it.
- **Zero glue** for delegation, worktrees, permission prompts surfacing to you.

What the SDK/other products are actually for (source: agent-sdk/overview table):
- **Client SDK** — you implement the tool loop yourself (not wanted).
- **Managed Agents** — hosted REST for long-running agents "without managing your own
  sandbox or session infrastructure." Relevant *only* if you later want the merge-watcher
  or workers to run server-side at org scale.
- Note: **claude.ai login is not permitted for SDK-built products**; the SDK requires API-key
  auth (source: agent-sdk/overview Note). The interactive CLI keeps your existing login.

**Where a small non-model program IS the right tool: the merge-watcher.** It must outlive
the orchestrator's context. Options, simplest first:
1. **Plain shell `gh` poll loop** launched with `run_in_background` or as a detached OS
   process. Simplest, no infra, local-first. **Recommended.**
2. **Agent SDK headless** (`claude -p --output-format json` or a Python/TS loop) — only if
   you want the watcher to *reason* (e.g. summarize CI failures) rather than just detect merge.
3. **GitHub webhook** — most scalable, needs a public endpoint. See §7.

Verdict: **CLI session for the brain; a dumb external process for the heartbeat.** Do not
put the orchestrator in the SDK.

---

## 3. Persistent state design (survives clear/compact)

The rule that makes this real: **the model never holds task state; it derives it from disk
every turn.** Compaction, `/clear`, and backgrounding all wipe or shrink model context, but
files persist. Subagent transcripts also persist separately and survive main-conversation
compaction (source: sub-agents "Main conversation compaction… subagent transcripts are
unaffected"), but we don't rely on that — `.canopy/` is authoritative.

### Layout
```
.canopy/
  brief.md               # human-authored durable brief; the "why" + global constraints
  state.json             # global: mode (autonomous|guided), task index, cursor
  tasks/
    <task-id>.json       # per-task state machine (below)
  worktrees.json         # task-id -> {path, lease_id, lease_holder}  (mirror of treehouse leases)
  log/<task-id>.md       # append-only human-readable trail per task
```

### Per-task state machine (`tasks/<id>.json`)
```json
{
  "id": "auth-refresh-token",
  "status": "reviewing",
  "brief_ref": "brief.md#auth",
  "worktree": { "path": "/…/wt-3", "lease_id": "ab12", "lease_holder": "canopy:auth-refresh-token" },
  "worker_agent_id": "agent_…",        // for SendMessage resume/steer
  "reviewer_agent_id": null,           // fresh each round; not resumed
  "pr": { "number": 142, "url": "…", "ci": "pending" },
  "gate_round": 2,
  "open_questions": [],                // arch decisions awaiting human in Guided mode
  "updated_at": "2026-08-01T…"
}
```
Status enum: `planning → implementing → reviewing → testing → linting → pr-open → merged → done`,
plus `blocked` (any state, with a reason). One field, one writer per transition.

### Who writes, when
- **Orchestrator** writes on every state transition it drives (planning→implementing, etc.).
  It is the *only* writer to `status` except the merge-watcher's `merged`/`done` transition.
- **Merge-watcher** (external) writes `pr.ci`, and on merge sets `status: merged` then, after
  `treehouse return`, `status: done`.
- **Hooks** may write mechanically: a `PostToolUse` hook matching the `gh pr create` Bash call
  writes `pr.number` + `status: pr-open` so state can't drift from reality (Med confidence —
  requires parsing `gh` output in the hook).
- **On resume/compact**: a `SessionStart` hook (`matcher` supports `startup|resume|clear|compact|fork`)
  cats `brief.md` + `state.json` into the session as `additionalContext` so the reborn
  orchestrator immediately knows the board. (SessionStart firing on `compact` is documented;
  the exact `additionalContext` injection shape for SessionStart is **Med** — verify the hook
  output schema for that event.)

Concurrency safety on the files: single-writer-per-field discipline above avoids most races.
For the merge-watcher vs orchestrator both touching a task, write via temp-file-rename (atomic)
and keep their fields disjoint. treehouse itself persists leases atomically in
`treehouse-state.json` (source: README), so worktree ownership has its own durable record.

---

## 4. treehouse — where it fits + exact lifecycle

Source: `github.com/kunchenguid/treehouse` README (fetched). treehouse "manages a pool of
reusable, isolated git worktrees per repository… acquire clean, pre-configured environments
instantly." Worktrees use **detached HEAD**, reset to whichever of local/remote default branch
is further ahead.

Lifecycle mapped to a task:
```sh
# 1. Orchestrator claims a worktree for a new task (non-interactive, durable):
path=$(treehouse get --lease --lease-holder "canopy:$TASK_ID" --json)
#   --lease  -> durable reservation, prints path, NO subshell, survives with no process inside
#   --lease-holder LABEL -> records who owns it (ABA protection on return)
#   --json   -> lease metadata incl. unique lease_id (requires --lease)
#   Leased trees are never handed to other `get` calls and never pruned.

# 2. Worker does all work inside $path (its git branch lives there).

# 3. On merge, merge-watcher returns it (conditional on identity to avoid ABA):
treehouse return --if-lease-id "$LEASE_ID" "$path"      # or --if-lease-holder
#   --force skips the confirm prompt.

# Ops / housekeeping:
treehouse status --json     # pool state: idle|in-use|leased, holders, timestamps, processes
treehouse prune             # dry-run: remove idle+merged+clean trees (leased/dirty skipped)
treehouse prune --yes       # execute
```
Config: `treehouse.toml` (repo) or `~/.config/treehouse/config.toml` (user): `max_trees`,
`root`, and `[hooks] post_create`/`pre_destroy`. **Use `post_create` to run your repo setup
(install deps, seed .env) so every leased tree is task-ready** — this is the intended hook and
saves the worker from bootstrapping. `post_create` stdout is routed to stderr under `--lease`
so the path stays clean on stdout (source: README Hooks).

Why treehouse and not Claude's built-in `isolation: worktree`? Claude's worktrees are
*ephemeral and Claude-managed* (auto-created under `.claude/worktrees/`, auto-cleaned if no
changes). treehouse gives a **reusable pool with explicit leases, identity, and pruning** —
required for #3 and for the merge-watcher to hand a tree back to the pool. The cost is the
integration seam in R1.

---

## 5. Workers: parallel + human-steerable + interruptible

Claude Code exposes three overlapping primitives. Pick per requirement:

**A. Background subagents (recommended primary).** As of v2.1.198 subagents run in the
background by default (source: sub-agents). They:
- run **in parallel** (default concurrency limit **20**, session total **200**; both env-tunable:
  `CLAUDE_CODE_MAX_CONCURRENT_SUBAGENTS`, `CLAUDE_CODE_MAX_SUBAGENTS_PER_SESSION`);
- appear as **steerable windows** in the subagent panel below the prompt and in `/tasks`:
  `↑/↓` select, `Enter` opens the transcript and lets you type follow-ups directly to that
  agent, `x` stops it, `Esc` returns to the prompt (source: sub-agents "Observe and steer");
- **surface permission prompts in your main session**, naming the asking subagent; Esc denies
  one call without killing it (source: sub-agents, v2.1.186);
- keep verbose output in their own context — only a summary returns (context-bloat control, #10).

**How the orchestrator resumes/steers a specific worker**: when a subagent completes, Claude
receives its **agent ID**. To continue or redirect it, the orchestrator uses the **`SendMessage`**
tool with the agent's ID or name as `to` — "A completed subagent that receives a `SendMessage`
auto-resumes in the background." Resumed subagents keep full history (source: sub-agents
"Resume subagents"). `SendMessage` does **not** require agent teams. A subagent "treats messages
from the agent that launched it as normal task direction, including mid-task course corrections"
(v2.1.198). Store `worker_agent_id` in the task file so steering survives compaction.

**B. Full-session windows = agent view / "FleetView"** (`claude agents`). Each background
session is "a full Claude Code conversation that keeps running without a terminal attached."
Agent view is "one screen for all your background sessions: what's running, what needs your
input, what's done," with per-row live status, PR labels (`#1234`), `Space` to peek+reply,
`Enter` to attach, `←` to detach (source: agent-view). Start them with `claude --bg --name … "…"`.
These are the richest human-steerable windows and each already isolates into its own worktree
and can open its own PR. Use this when you want workers to be *independent sessions* the human
treats as peers. Trade-off: they're separate processes, so the orchestrator drives them by
shelling out (`claude --bg`, `claude agents --json`, `claude attach/logs/stop <id>`) rather than
via the `Agent` tool — and each burns quota like a full session ("ten agents ≈ 10× quota").

**C. Agent teams** (`CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1`). Teammates are full independent
sessions that message each other and share a task list; steer via the agent panel or split panes
(tmux/iTerm2). **Not recommended for v1**: experimental, "no session resumption with in-process
teammates," higher token cost (source: agent-teams Limitations).

**"herdr"** (`herdr.dev`, third-party Rust binary) is a terminal *agent multiplexer*: it wraps
whole agent processes (claude, codex, cursor, …) each in a PTY pane with agent-state awareness —
"tmux for coding agents." It is **external to and above** Claude Code; it would multiplex
*several `claude` processes*, not Claude Code's internal subagents. Optional operator convenience,
not part of the core mechanism. (Sources below.)

**Recommended worker model**: start with **A** (subagents + `isolation: worktree`) for the
walking skeleton — fewest moving parts, all native, all verified. Graduate to **B + treehouse**
when you need reusable pooled trees and full human-navigable session windows (the FleetView
requirement). This is a deliberate two-stage path because of R1.

---

## 6. Fresh reviewer with independent context (anti-echo-chamber)

Mechanism: spawn a **named, non-fork subagent** each review round. Non-fork subagents "start
with a fresh, isolated context window… doesn't see your conversation history, the skills you've
already invoked, or the files Claude has already read" (source: sub-agents "What loads at
startup"). That property *is* the independence.

Rules to keep it clean:
- **Do not use a fork** for the reviewer — a fork "inherits the entire conversation" and drops
  isolation (source: sub-agents "Fork"). Echo chamber guaranteed. Use a named subagent.
- **Do not `SendMessage`/resume the worker into the reviewer.** Each review is a *new invocation*
  → new agent ID → fresh context. Never pass the worker's transcript.
- **Feed it the diff only.** Reviewer `tools: Read, Grep, Glob, Bash`; its prompt says "run
  `git -C <worktree> diff <base>...HEAD` and review that." It reads code from the worktree but
  gets no worker chat. (Reviewer runs read-only; give it no Edit/Write.)
- **Reviewer cannot ask the human** — `AskUserQuestion` is filtered out of every subagent
  (source: sub-agents tool filter). So a reviewer that hits an architectural fork returns the
  decision *to the orchestrator*, which handles it per mode (§ below). This is a feature: it
  forces decisions up to the one agent that can talk to the human.
- Optional hardening: define reviewer with `memory: project` so it accrues review heuristics
  across tasks (source: sub-agents "Enable persistent memory"). Optional; adds cross-task learning.

---

## 7. Modes (`/yolo`) + never-exit gate loop

**Modes as a slash command / skill.** `/yolo` (a command in `.claude/commands/` or a skill in
`.claude/skills/`) flips `mode` in `.canopy/state.json` between `autonomous` and `guided`.
The orchestrator reads `mode` at each decision point.
- **Autonomous**: reviewer findings → orchestrator delegates fixes back to the worker
  (`SendMessage`); architectural decisions the orchestrator resolves itself and records in the
  task log.
- **Guided**: architectural decisions bubble to the human via **`AskUserQuestion`** (main
  session only), the answer is written to the task file, then delegated back to the worker.

**Gate loop** (per task, runs until reviewer reports zero issues):
```
implementing → reviewing:   spawn FRESH reviewer on the diff
   issues > 0 → fixing:      SendMessage worker with the findings → back to reviewing
   issues == 0 → testing:    worker runs test suite (+ orthogonality check: does the diff
                             touch only what the brief scopes?)  fail → fixing
   pass → linting:           worker runs lint/format; fail → fixing
   pass → pr-open:           gh pr create; block on CI (§8)
```
Enforcement options for "never exit until clean":
- Simplest: **orchestrator control logic** driven by `state.json` (a plain loop the model runs).
- Hardened: a **`SubagentStop` / `Stop` hook** that inspects the reviewer's structured output
  and **exits code 2** to inject "issues remain, continue" back into the loop, so the loop can't
  terminate early even if the model tries (source: hooks — Stop/SubagentStop, exit-2 = blocking
  error feeds stderr back). For teammates, `TeammateIdle` exit-2 does the same "keep working"
  (source: agent-teams). Confidence Med — wire and test the exact payloads.

---

## 8. PR automation (gh CLI)

All standard `gh`, run from a Bash-capable step (the orchestrator can do this itself since
`gh` is not "editing code," or delegate a tiny PR subagent):
```sh
gh pr create \
  --title "feat(auth): refresh-token rotation" \        # conventional commit
  --body-file .canopy/tasks/<id>.pr.md                    # structured: what / why / linked issues / touched files / repro / BREAKING CHANGE
gh pr view --json number,url -q .                          # capture into task file
gh pr checks <n> --watch      # or: gh run watch <run-id>  # block until CI green
```
- **Atomic**: one leased worktree = one branch = one PR; the diff scope check in the gate loop
  keeps it atomic.
- **Breaking-change flag**: detected in review/orthogonality step → `BREAKING CHANGE:` footer +
  label via `gh pr edit --add-label`.
- **Block on CI green**: `gh pr checks --watch` (exit non-zero on failure) gates the
  `pr-open → merged` transition; failures route back to `fixing`.
- Body assembly is mechanical from the task file (touched files from `git diff --name-only`,
  linked issues from the brief). All `gh` behavior is external-tool, **High** confidence.

---

## 9. Merge-watcher — one process, all PRs

**Recommended: one external `gh` poll loop, decoupled from the orchestrator session**, writing
`.canopy/`:
```sh
# canopy-merge-watcher.sh  (run detached / via run_in_background, NOT inside model context)
while true; do
  gh pr list --state merged --json number,headRefName --search "…canopy…" \
    | jq -c '.[]' | while read pr; do
        # match pr.number to a task, then:
        treehouse return --if-lease-holder "canopy:$TASK_ID" "$WT_PATH"
        # atomically set tasks/<id>.json status: merged -> done
      done
  sleep 30
done
```

**Poll vs webhook trade-off:**
| | Poll (`gh`) | Webhook (GitHub App/`repository`) |
|---|---|---|
| Infra | none; local-first; runs on the laptop | needs public endpoint (smee/ngrok/hosted) + secret verification |
| Latency | seconds–minutes (poll interval) | near-instant |
| Scale | fine to ~dozens of PRs / few repos; API rate limits bite at org scale | scales to org/many repos; event-driven, no polling cost |
| Failure mode | miss nothing (re-reads state each loop); just laggy | must handle missed deliveries + replay |
| **Use when** | **single user, local, v1 — recommended** | many repos / org-wide / low-latency SLA |

**Most scalable**: webhook via a GitHub App to a small always-on service that updates `.canopy/`
(or a DB). But it's strictly more infra; adopt only when poll's rate limits or latency hurt.

**Why not an in-model `Monitor`?** `Monitor` "runs a command in the background and feeds each
output line back to Claude" and can watch a WebSocket (source: tools-reference). It *could* poll
`gh`. But a Monitor is **bound to the session**: when you background the orchestrator, "work that
can't carry over, such as a running monitor, is stopped" (source: agent-view). It also dies on
`/clear`. So a Monitor violates the durability requirement. Keep the watcher **outside** the model.
(A Monitor is still fine for *ephemeral* watches, e.g. tailing one worker's test run.)

---

## 10. Parallelization without collisions or context bloat

- **No file collisions**: one leased worktree per task → disjoint working trees, disjoint
  branches. Two tasks physically cannot edit the same file in the same tree.
- **No context bloat in the orchestrator**: workers/reviewers are subagents; their verbose
  output (logs, test spew, file reads) stays in *their* context and only a summary returns
  (source: sub-agents). The orchestrator's own context stays near the size of `state.json`.
  Danger noted in docs: "Running many subagents that each return detailed results can consume
  significant context" — so **workers must return terse structured summaries**, and detail lives
  in `.canopy/log/<id>.md`, not in the return value.
- **Concurrency caps**: 20 concurrent / 200 per session by default (env-tunable). Beyond that,
  or if you want workers to outlive the orchestrator's context, use model **B** (background
  sessions) where each worker is its own session with its own budget.
- **Tracking N tasks**: `state.json` is the board; `tasks/*.json` are the cards; `worker_agent_id`
  is the handle to steer each. The orchestrator reconstructs the whole board from disk every turn,
  so "how many are in flight and what's each doing" never depends on model memory.

---

## 11. Proposed architecture (target)

```
        ┌─────────────────────────────────────────────────────────┐
        │  ORCHESTRATOR  (one interactive `claude` session)        │
        │  - Edit/Write DENIED. Reads .canopy/ every turn.         │
        │  - Delegates via Agent tool; steers via SendMessage.     │
        │  - AskUserQuestion (Guided mode) is its exclusive power.  │
        └───────────────┬─────────────────────────────────────────┘
                        │ reads/writes (source of truth)
                  ┌─────▼──────┐        ┌──────────────────────────┐
                  │  .canopy/  │◄───────┤  MERGE-WATCHER (external  │
                  │ brief.md   │  writes│  gh poll loop, detached)  │
                  │ state.json │        │  on merge: treehouse      │
                  │ tasks/*.json│       │  return + status=done     │
                  └─────┬──────┘        └──────────────────────────┘
        delegates       │ leases
   ┌────────────────────┼───────────────────────────┐
   ▼                    ▼                            ▼
 WORKER (subagent)   WORKER (subagent)            REVIEWER (fresh subagent,
 in treehouse WT-1   in treehouse WT-2            per round, diff-only, isolated)
 steerable in panel  steerable in panel           returns issues → orchestrator
        │
   treehouse get --lease  ──────────────►  pooled worktrees (detached HEAD)
```

Human steering surfaces: subagent panel / `/tasks` (workers as windows), `claude agents`
(FleetView, if workers are background sessions), optionally `herdr` multiplexing several
`claude` processes.

---

## 12. Phased build order (thinnest walking skeleton first)

**Phase 0 — De-risk the worktree seam (R1).** Before building anything, empirically answer:
does a `claude --bg` session started in a treehouse-leased dir still auto-create its own
`.claude/worktrees/` tree? And can a plain (`isolation`-less) subagent reliably run all Bash via
`git -C <leased-path>` given the working-dir guard? Decide worker model A vs B from the result.
(1 day of experiments; unblocks everything.)

**Phase 1 — Walking skeleton (all native, no treehouse, no external watcher):**
1. `.canopy/` with `brief.md` + `state.json` + one `tasks/<id>.json`; hand-write one task.
2. Orchestrator = `claude --agent orchestrator` (Edit/Write denied). It reads the task, spawns
   ONE worker subagent with `isolation: worktree` to implement it.
3. Spawn ONE fresh reviewer subagent on `git diff`; loop review→fix (via `SendMessage`) until
   zero issues; then `gh pr create`.
4. Orchestrator manually marks `pr-open`. No merge-watcher yet — human merges.
   *Exit criteria*: one task goes brief → PR entirely through subagents, orchestrator never edits,
   reviewer context provably fresh.

**Phase 2 — Durability + modes.**
- Move state transitions behind a disciplined schema; add `SessionStart` hook to re-inject
  `.canopy/` after compact/clear; prove a mid-task `/clear` doesn't lose the board.
- Add `/yolo` command toggling autonomous/guided; wire `AskUserQuestion` for guided arch decisions.

**Phase 3 — treehouse pool.**
- Replace `isolation: worktree` with `treehouse get --lease` (worker model chosen in Phase 0);
  `post_create` hook bootstraps each tree; store lease in task file.

**Phase 4 — Merge-watcher.**
- External `gh` poll loop → on merge, `treehouse return` + `status: done`. Detached process,
  reads/writes `.canopy/`. Prove it survives orchestrator `/clear`.

**Phase 5 — Fan-out + FleetView.**
- Multiple concurrent tasks; enforce concurrency caps; if full-session windows are wanted,
  move workers to `claude --bg` and monitor via `claude agents`. Optional `herdr` on top.

**Phase 6 — Gate hardening.**
- `SubagentStop`/`Stop` hooks (exit-2) so the never-exit loop can't terminate dirty; orthogonality
  + breaking-change checks; `gh pr checks --watch` blocking CI gate.

---

## 13. Risks & unknowns (de-risk plan)

| ID | Risk / unknown | Confidence it's a problem | De-risk |
|----|----------------|---------------------------|---------|
| **R1** | **Worktree double-management**: Claude's background sessions auto-move into `.claude/worktrees/` before editing (agent-view, documented); unclear if this collides with / nests inside a treehouse-leased worktree, or whether it can be disabled. Also: a plain subagent's Bash working-dir guard blocks `git -C` into the main checkout, and non-worktree subagents don't persist `cd`. | High it's the #1 integration hazard | Phase 0 experiments. Likely outcomes: (a) use subagent `isolation: worktree` and skip treehouse for workers (lose pooling), or (b) run workers as `claude --bg` in leased dirs and find/confirm a flag to suppress auto-worktree (UNVERIFIED such a flag exists). |
| **R2** | **In-model watchers aren't durable**: Monitor is stopped on backgrounding and dies on `/clear` (agent-view). | High (documented) | Already handled: watcher is an external process. Don't regress into a Monitor. |
| **R3** | **SessionStart auto-reinjection shape**: that SessionStart fires on `compact`/`clear` is documented; the exact `additionalContext`/output contract for that event is not fully pinned. | Med | Verify the SessionStart hook output schema; fallback: orchestrator's first instruction each turn is "read `.canopy/` before acting" (works without hooks). |
| **R4** | **Gate-loop enforcement via Stop/SubagentStop exit-2**: documented for other events; exact payload to force "keep looping" needs testing. | Med | Prototype in Phase 6; fallback is pure orchestrator control logic (no hook), which is sufficient though less tamper-proof. |
| **R5** | **Concurrency / quota**: 20 concurrent subagents cap; background sessions burn quota ~linearly (agent-view). | Med | Tune `CLAUDE_CODE_MAX_CONCURRENT_SUBAGENTS`; batch tasks; use cheaper models for workers (`model:` field) where acceptable. |
| **R6** | **PostToolUse hook parsing `gh` output** to auto-write PR state is brittle (output format changes). | Low-Med | Prefer `gh … --json` structured output in the hook; or have the orchestrator write PR state explicitly instead of via hook. |
| **R7** | **treehouse maturity/API stability**: single external repo; commands verified from README only, not run. | Med | Pin a version; wrap treehouse calls in one adapter script so a breaking change is one-file fix; `treehouse status --json` is the integration contract. |
| **R8** | **Agent teams NOT used** but tempting: experimental, no resumption, higher cost. | Low (avoided) | Keep to subagents + background sessions until teams leave experimental. |
| **R9** | **Subagent output can carry injected instructions** (from files/web/CI logs it read). Claude Code scans subagent reports but doesn't neutralize intent (sub-agents "output scanning"). | Med | Keep worker/reviewer tools least-privilege; never `bypassPermissions` on the orchestrator; treat worker summaries as untrusted data. |

---

## 14. Sources

Official Claude Code / Agent SDK docs (fetched 2026-08-01):
- Subagents: https://code.claude.com/docs/en/sub-agents
- Hooks: https://code.claude.com/docs/en/hooks
- Agent view / background agents (FleetView): https://code.claude.com/docs/en/agent-view
- Agent teams: https://code.claude.com/docs/en/agent-teams
- Tools reference (Monitor, background tasks, SendMessage, TaskStop, EnterWorktree): https://code.claude.com/docs/en/tools-reference
- Agent SDK overview: https://code.claude.com/docs/en/agent-sdk/overview
- Worktrees: https://code.claude.com/docs/en/worktrees (referenced)

treehouse:
- README: https://github.com/kunchenguid/treehouse (raw: raw.githubusercontent.com/kunchenguid/treehouse/main/README.md)

herdr (third-party multiplexer; context only):
- https://herdr.dev/
- https://www.tecmint.com/herdr-run-ai-coding-agents-in-linux-terminal/
- https://www.bitdoze.com/herdr-agent-multiplexer/

gh CLI: https://cli.github.com/manual/ (external, standard).

---

## Appendix — Phase 0 de-risk results (run empirically, 2026-08-01)

Ran the two scary unknowns in a throwaway scratch repo with real `treehouse` v2 + real Claude Code subagents (claude 2.1.212). Results are empirical, not reasoned.

**Risk #1 — worktree double-management: AVOIDABLE by design (cleared).**
- Leased a worktree with `treehouse get --lease` → detached-HEAD worktree at `.treehouse/…`, tracked in `git worktree list`. Clean.
- **Plain subagent** (no isolation flag) pointed at the leased path via `cd`, editing with raw `git`: committed **inside** the leased worktree; created **zero** `.claude/worktrees/`. No collision.
- **Subagent launched with `isolation: worktree`**: landed in `.claude/worktrees/agent-<id>` on its own `locked` branch `worktree-agent-<id>`. This is the collision — a Claude-managed worktree separate from the treehouse lease.
- **Bonus:** the Claude-managed worktree auto-removed itself once the agent finished having made no changes.
- **Design rule:** workers must NOT use Claude's `isolation: worktree` / EnterWorktree. Orchestrator leases via `treehouse`, spawns a plain worker whose cwd is the leased path, worker uses raw `git`. (Corollary: don't have the worker call EnterWorktree either.)

**Context isolation — CONFIRMED.**
- Worker held an in-context codeword (`ZEBRA-42`) it was told never to write to disk, then committed a normal edit.
- A separate **fresh** (non-fork) reviewer subagent was given the git diff and asked if it knew any prior-agent codeword → answered "NONE — I have no prior-agent context". It saw only the diff, never the worker's reasoning.
- Confirms: a non-`fork` subagent is a clean, independent reviewer by construction. (A `fork` subagent WOULD inherit context — so the reviewer must never be a fork.)

## Appendix — SessionStart contract (pinned) + merge-watcher decision

**SessionStart hook (verified against code.claude.com/docs/en/hooks):**
- Output JSON: `{"hookSpecificOutput": {"hookEventName": "SessionStart", "additionalContext": "…"}}`. Other optional fields: `initialUserMessage`, `watchPaths`, `sessionTitle`, `reloadSkills`.
- Fires on `source` values: `startup`, `resume`, `clear`, `compact`, `fork`. So it covers BOTH `/clear` and context compaction — risk retired.
- `additionalContext` is hard-capped at **10,000 chars** → inject a DIGEST, not full state.
- Separate `PreCompact` / `PostCompact` events exist (matcher `manual`/`auto`) if compaction-specific logic is ever needed; not needed for re-injection.

**Source-of-truth decision:** `.canopy/` files on disk are authoritative (durable, unbounded). The SessionStart hook is a redundancy — a ≤10k digest re-injected at session boundaries so the model is oriented before its first tool call. The orchestrator ALSO reads `.canopy/state.json` at the top of every turn, so nothing depends on the hook succeeding.

**Merge-watcher decision:** not a hand-babysat daemon. Local/now = an OS-scheduled tick (launchd on macOS / cron) running a tiny `gh-axi` reconcile script every ~60s that, for merged PRs, runs `treehouse return` + sets status=done in `.canopy/state.json`. The OS is the supervisor (survives `/clear` + reboot, self-restarts). At org/always-on/many-repo scale, graduate to a GitHub App webhook → small hosted worker. Watcher stays stateless (reads/writes `.canopy/state.json` only). GitHub ops use `gh-axi` (agent-ergonomic wrapper) per user preference.

- **Scope:** ONE watcher total, not per project. `state.json` lists every active task with `{repo, pr, worktree}`, so one launchd job covers all repos. The SessionStart hook likewise goes in user-level `~/.claude/settings.json` once, not per repo.
- **Wake model:** the watcher does NOT push into a running session (no reliable external→session inject primitive in Claude Code). It keeps `state.json` truthful; the turn-based orchestrator reconciles on its next turn. For a genuine nudge, the watcher fires an OS notification and the human continues the orchestrator.
- **File placement:** `state.json` lives in `.canopy/` (data, source of truth); the hook lives in `.claude/settings.json` and only reads `.canopy/state.json`. Distinct locations.
