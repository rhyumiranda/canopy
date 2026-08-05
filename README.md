# 🌳 Canopy

**Run many AI coding agents on one project without drowning in coordination.**

<p align="center">
  <img src="assets/canopy-demo.gif" alt="Claude Code driving Canopy end-to-end — intent → isolated worker → independent review → a gated PR" width="880">
  <br>
  <em>Real Claude Code driving the full run: one line of intent → isolated worker → independent review → a gated PR.</em>
</p>

Canopy is a thin supervisor that sits one level above your coding agents. It holds the plan, runs each task in its own isolated worktree, has a *separate* agent review every change, ships a clean PR, and only interrupts you when a decision genuinely needs a human. You steer everything from one seat. Claude Code is the stable runtime; Codex support is experimental.

MIT-licensed. Local-first. Built on [`treehouse`](https://github.com/kunchenguid/treehouse), `gh-axi`, and Claude Code.

---

## What is Canopy?

An orchestration layer for AI coding agents. You give it intent; it delegates the work to worker agents you can watch and steer live, keeps the whole plan on disk so nothing gets lost, and refuses to open a PR until an independent reviewer says the change is clean.

Think of it as the layer *above* the treehouses — the workers live in isolated worktrees down in the branches; Canopy is the canopy over all of them.

## The problem

If you've run more than two or three agents at once, you know the feeling:

- Six terminal tabs, six sessions. You can't remember which one did what.
- Two agents touch the same files and you're back in merge hell.
- You clear a session to reclaim context — and lose the plan with it.
- You let an agent review its own work, and it happily rubber-stamps itself.

You end up spending your energy *managing agents* instead of shipping. The agents are capable; the coordination is what breaks.

## The solution

Canopy takes the coordination off your plate:

- **One seat.** A single orchestrator session holds the plan; you don't juggle windows.
- **Isolation by default.** Every task gets its own `treehouse` worktree and branch — no collisions, safe parallelism.
- **Steerable workers.** Each worker is a live pane you can open, watch, and redirect mid-flight.
- **Independent review.** A *fresh* agent reviews the diff (and the code around it — call sites, invariants) but never the worker's reasoning, so it can't rubber-stamp. It grades risk and re-reviews any fix as new code. (A cheap model does this, so it stays lean.)
- **Nothing ships unreviewed.** No PR opens until the review is clean and the deterministic checks pass.
- **Never lose your place.** State and progress live on disk. Clear the orchestrator whenever you want — recovery resumes each worker from its last checkpoint.

## Why now?

Three things just became true at the same time:

1. **Agents are good enough** to take a real task from intent to a mergeable PR — but only one at a time before the human becomes the bottleneck.
2. **Cheap, fast models** (like Haiku) make an *independent* review affordable on every change, so "no echo chamber" stops being a luxury.
3. **Reusable worktree pools** (`treehouse`) and steerable subagents make safe parallelism a few commands, not a framework.

The missing piece was a lean layer that ties them together without adding a heavy, token-hungry runtime. That's Canopy.

## Before & after

| | Before | With Canopy |
|---|---|---|
| **Windows** | N tabs you mentally track | one seat, workers as panes |
| **Isolation** | agents step on each other | one worktree per task |
| **Review** | you, or the agent itself | a fresh, independent agent — reads the diff + surrounding code, grades risk |
| **Shipping** | "looks fine", open PR | blocked until review clean + checks pass |
| **Context wipe** | lose the plan | state on disk; `recover` resumes |
| **Cost** | a full session per agent | deterministic checks are free; one small review per task |

## Where to use it

- **You're one developer** running several tasks in parallel on a project.
- **Any git repo** — Canopy is glue around `git`, `treehouse`, and `gh-axi`.
- **macOS** for the launchd merge-watcher (cron works elsewhere).
- Works across all your projects: install once, `canopy init` per repo.

Not built for: hosted multi-tenant use, or replacing CI (Canopy *uses* your CI as a gate).

## How to use it

**Prereqs:** [`git`](https://git-scm.com) · [`jq`](https://jqlang.github.io/jq/) · [Claude Code](https://code.claude.com/docs) (`claude`, v2.1+) · [`treehouse`](https://github.com/kunchenguid/treehouse) (worktree pool) · `gh-axi` (agent-ergonomic GitHub CLI wrapper — a companion "axi" tool; install it before running Canopy).

**Install once:**
```bash
git clone https://github.com/rhyumiranda/canopy.git && cd canopy
./bin/canopy setup                     # agents/commands/hooks -> ~/.claude; a CLI snapshot -> ~/.local/share/canopy; canopy -> PATH
./bin/canopy setup --channel codex-preview
export PATH="$HOME/.local/bin:$PATH"   # if it isn't already
canopy watch install                   # optional (macOS): auto-closes tasks on merge and records Herdr terminal events.
                                       # writes a launchd plist; run the printed launchctl command to load it.
                                       # (Linux: schedule `canopy watch once` via cron instead.)
```

`setup` installs a snapshot of the chosen channel and records that channel locally. Supported channels:

- `stable` -> `main`
- `codex-preview` -> `rhyu/experimental-codex-package`
- `herdr-preview` -> `rhyu/experimental-herdr-tabs`

Install does **not** mutate your dev checkout. It clones a managed source under `~/.local/share/canopy/source`, checks out the branch for the chosen channel there, and installs from that managed clone. The installed `canopy` is decoupled from your dev checkout, so switching branches in the repo won't break it. **To update, just run `canopy upgrade` from anywhere** — it refreshes the recorded channel branch and reinstalls the same channel.

**Per project:**
```bash
cd your-repo && canopy init            # creates .canopy/, ensures treehouse
canopy start                           # opens Claude Code AS the orchestrator
canopy start --codex                   # opens Codex AS the orchestrator
```

`canopy start` is the whole point: it launches Claude Code with the orchestrator playbook loaded, reads `.canopy/`, recovers any in-flight work, and then just waits for your intent — you tell it what you want, it drives the rest. (`canopy init` alone only makes the repo ready; `start` is what makes Claude know what to do.)

`canopy start --codex` defaults unspecified workers to interactive Codex panes in an existing Herdr workspace. Claude remains the default when Claude is the orchestrator. Use `--agent claude` to choose a backend, or explicit `--headless`/`worker spawn` for detached work. Canopy never creates a Herdr workspace; pass `--workspace <id>` when discovery cannot use the current pane.

Herdr workers reuse one existing user workspace (for example Stashlify) and create one non-focused tab per task/backend, labeled `t5 · Claude` or `t5 · Codex`. Both backends launch as a steerable interactive session seeded with the task prompt (Codex gets its prompt as the TUI's initial message, not a one-shot headless run). Pass `--workspace <id>` when the current Herdr pane is not the desired context. Canopy never creates a Herdr workspace. Each Herdr worker also gets a one-shot launchd supervisor keyed to its task, pane, tab, and agent session; it records terminal outcomes (`done`, `failed`, `blocked`, `interrupted`) as durable lifecycle events without closing user tabs or creating workspaces. A manual `canopy worker stop` of a still-active worker also records an `interrupted` outcome. Herdr's agent status is source-pinned to the last state Canopy pushes, so a worker that finishes its turn and idles at the prompt would otherwise leave Herdr showing a stale `working` and the orchestrator blind to the completion. To close that gap, every Claude worker is launched with a seeded Stop hook (`--settings` pointing at a per-worker `.canopy/worker-settings/<id>.json`) that runs `canopy worker idle <id>` on each end-of-turn: it re-pins Herdr to `idle` and enqueues a lifecycle event so the orchestrator wakes. That command also reconciles against Herdr's live `agent explain` detection — if the worker actually entered a terminal state it emits that terminal event instead of the `idle` wake. Lifecycle events dedupe per active phase: a repeated probe of the same continuous terminal state is suppressed, but once a worker leaves a terminal state (or is restarted/resumed) a later re-entry into the same state on the same pane/session wakes the orchestrator again. The detached `worker spawn` path remains available for both Claude and Codex.

The Herdr worker commands (`worker start · attach · send · status · read · resume · reconcile · close · stop`) layer [AXI](https://github.com/kunchenguid/axi) ergonomics on top of the base worker model without changing its behavior: non-interactive with strict flag parsing (an unknown/misplaced flag or a missing required argument fails loud with exit code 2 and lists the valid flags on stdout, so an agent self-corrects in one turn), a concise `--help` per subcommand, and compact [TOON](https://toonformat.dev/) confirmation lines on the action commands `start`/`send`/`stop`/`close` (e.g. `task: t5` / `pane: …` / `stopped: ok`). The pane/tab ownership guard and the bounded, structured **JSON** output of `worker status`/`read` are unchanged — status stays JSON, not TOON. Usage errors are structured on stdout; runtime diagnostics stay on stderr so stdout is parseable. Run `canopy worker <cmd> --help` for the per-command reference.

**Under the hood** — the raw primitives the orchestrator drives (you rarely run these by hand):
```bash
id=$(canopy task add "add a /health endpoint")
canopy task set "$id" brief "adds GET /health returning 200"   # the What
canopy task set "$id" why   "the load balancer needs a liveness probe"
canopy worktree lease "$id"            # isolated worktree + feature branch
canopy worker spawn "$id"              # detached worker using the orchestrator's runtime
canopy worker spawn --agent codex "$id" # explicitly detached Codex worker (jsonl + resumable session)
                                       # (via `canopy start`, workers are steerable Herdr panes;
                                       #  `worker spawn` is the explicit detached path)
canopy worker start --agent claude --workspace <id> "$id" # Herdr tab worker (existing workspace)
canopy worker start --agent codex --workspace <id> "$id"  # Codex Herdr worker
canopy worker start --headless "$id"                   # detached worker; uses recorded task backend when present
canopy worker attach "$id"              # attach to its Herdr tab
canopy worker send "$id" "status?"       # send text to its agent
canopy worker reconcile --agent claude "$id" # clear legacy Herdr IDs after verifying old backend
canopy worker status "$id"               # bounded JSON summary + read command
canopy worker read "$id"                 # fuller bounded conversation/context
canopy worker resume --agent codex "$id" # continue a Claude task in Codex; reuses its saved Herdr workspace
canopy worker close "$id"               # requires ready_for_review + passing checks
canopy events consume                  # one pending terminal worker/PR event, then mark consumed
canopy events wait 30                  # bounded one-shot wait; not a supervisor loop
canopy review "$id"                    # one independent diff review (follows orchestrator; Claude standalone default)
canopy review --agent codex "$id"      # same gate, but with a fresh read-only Codex reviewer
canopy pr open "$id"                   # gh-axi PR — refuses unless review is clean + checks pass
canopy status                          # the board
```

### Skills / commands

| Surface | Usage | What it does |
|---|---|---|
| Claude command | `/yolo [yolo\|guided]` | Toggle autonomy — **autonomous** (auto-fix, no gate) vs **guided** (default; surfaces real decisions to you). Global. |
| Claude command | `/scribe [fact]` | Record a durable, project-intrinsic lesson to `AGENTS.md` — every agent auto-loads it, so knowledge compounds. |
| Claude command | `/hotfix "<what broke>"` | Spin a fast isolated worker (fresh worktree, yolo, no review) for an urgent fix. |
| Codex skill | `$yolo` / `$guided` | Switch Canopy autonomy mode from Codex. Installed by `canopy setup`. |
| Codex skill | `$scribe` | Record a durable project fact from Codex. Installed by `canopy setup`. |
| Codex skill | `$hotfix` | Start the urgent Canopy hotfix path from Codex. Installed by `canopy setup`. |

Resuming after a `/clear`? `canopy recover` first consumes durable terminal events from `.canopy/events/lifecycle.json`, then re-spawns in-flight workers from their last checkpoint — continue, don't restart. Herdr resume uses an explicit `--workspace` first, then the task's saved `herdr_workspace_id`, then normal global/current discovery. For legacy Herdr state without a recorded backend, identify the old backend and run `canopy worker reconcile --agent claude|codex <id>`; it validates and closes only the exact owned pane/tab, then resume explicitly. `worker status` and `worker read` reject legacy Herdr IDs until that reconciliation records a backend. A live Herdr supervisor pane may get a best-effort `agent send` and Herdr/macOS notification when a watcher sees a new terminal event, but a cleared/exited Codex session cannot be woken by a file alone. The durable event is the reliable fallback for the next `canopy recover` or `canopy events consume`.

Full CLI: `init · start · status · task · events · mode · base · worktree · worker · checks · review · pr · watch · scribe · recover · setup · upgrade`.

**Integrating on a non-default branch?** If your repo merges into `develop` (not `main`), set it once — `canopy base develop` (or `canopy init --base develop`). Every worktree is then cut from a *fresh* copy of that branch, every PR targets it, and every review diffs against it (so the gate sees only your change, not commits already merged into the base), so work never anchors to a stale `main`. `canopy base` prints the current one.

**How it works:** the *behavior* lives in `agents/` (orchestrator, worker, reviewer), `commands/` (Claude commands), and `skills/` (Codex-native skills); the `lib/` shell scripts are the deterministic glue. It's small — read the code.

## Contributing

Contributions are welcome — it's early and there's plenty to sharpen (open an issue to see what's in flight).

**Setup & tests:**
```bash
git clone https://github.com/rhyumiranda/canopy.git && cd canopy
bash test/all.sh        # runs every suite; needs jq + git (+ treehouse for worktree tests)
```

**How the code is organized:**
- `bin/canopy` — the CLI router.
- `lib/*.sh` — deterministic glue (state, worktree, worker, checks, review, pr, watch, scribe, recover, setup). Bash + `jq`, no build step.
- `agents/*.md`, `commands/*.md`, `hooks/*.sh` — the *behavior* (Claude Code config), installed by `canopy setup`.

**Ground rules (please keep these true):**
- **Deterministic-first.** If a plain command can do it, don't spend an agent. Judgment goes to prompts; guarantees go to hooks.
- **Isolation is sacred.** Workers run in `treehouse`-leased worktrees with raw `git` — never `-w` / `isolation: worktree`.
- **The reviewer stays independent.** It reads the diff and surrounding code but never the worker's reasoning; never fold it into the worker.
- **Every change adds a test.** Match the existing `test/*_test.sh` style; keep `bash test/all.sh` green.

**Sending a change:** open an issue for anything non-trivial first, keep PRs atomic, explain the *what* and *why*, and note anything you couldn't test. (Canopy dogfoods this workflow — feel free to let Canopy open the PR.)

**Releasing (automatic):** releases run on [release-please](https://github.com/googleapis/release-please). Merging `feat:`/`fix:` commits to `main` keeps a **release PR** open that bumps `CANOPY_VERSION` and writes `CHANGELOG.md`; **merge that PR** to tag `vX.Y.Z` and publish the GitHub Release. No manual version bump, tag, or push. `fix:` → patch, `feat:` → minor, `feat!:`/`BREAKING CHANGE:` → major.

## License

MIT © Rhyu Miranda. See [`LICENSE`](LICENSE).
