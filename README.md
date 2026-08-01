# 🌳 Canopy

**Run many AI coding agents on one project without drowning in coordination.**

Canopy is a thin supervisor that sits one level above your coding agents. It holds the plan, runs each task in its own isolated worktree, has a *separate* agent review every change, ships a clean PR, and only interrupts you when a decision genuinely needs a human. You steer everything from one seat.

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
- **Independent review.** A *fresh* agent reviews the diff only — it never sees the worker's reasoning, so it can't rubber-stamp. (A cheap model does this, so it stays lean.)
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
| **Review** | you, or the agent itself | a fresh, independent agent on the diff |
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

**Prereqs:** [`treehouse`](https://github.com/kunchenguid/treehouse), `gh-axi`, `claude` (v2.1+), `jq`, `git`.

**Install once:**
```bash
git clone https://github.com/rhyumiranda/canopy.git && cd canopy
./bin/canopy setup                     # agents/commands/hooks -> ~/.claude, canopy -> PATH
export PATH="$HOME/.local/bin:$PATH"   # if it isn't already
canopy watch install                   # writes a launchd plist; run the printed launchctl command to start it
```

**Per project:**
```bash
cd your-repo && canopy init            # creates .canopy/, ensures treehouse
```

**Run a task** (the orchestrator agent normally drives this; here's the raw flow):
```bash
id=$(canopy task add "add a /health endpoint")
canopy task set "$id" brief "…what & why…"
canopy worktree lease "$id"            # isolated worktree + feature branch
# orchestrator spawns a steerable worker in that worktree: implement -> document -> checks -> commit
canopy review "$id"                    # one independent diff review (cheap model)
canopy pr open "$id"                   # gh-axi PR — refuses unless the review is clean
canopy status                          # the board
```

**Handy:**
- `/yolo` toggles autonomous vs guided (default) mode.
- `/scribe` records durable lessons to `AGENTS.md`.
- `/hotfix "<what broke>"` spins a fast isolated worker.
- `canopy recover` resumes in-flight tasks after a `/clear`.

Full CLI: `init · status · task · mode · worktree · worker · checks · review · pr · watch · scribe · recover · setup`.

**Learn more:** [`docs/PRD.md`](docs/PRD.md) (full design), [`docs/architecture-map.html`](docs/architecture-map.html) (diagrams), [`docs/SPRINT-10-day.md`](docs/SPRINT-10-day.md) (how it was built).

## Contributing

Contributions are welcome — it's early and there's a clear backlog in `docs/SPRINT-10-day.md`.

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
- **The reviewer stays independent.** It reads only the diff; never fold it into the worker.
- **Every change adds a test.** Match the existing `test/*_test.sh` style; keep `bash test/all.sh` green.

**Sending a change:** open an issue for anything non-trivial first, keep PRs atomic, explain the *what* and *why*, and note anything you couldn't test. (Canopy dogfoods this workflow — feel free to let Canopy open the PR.)

## License

MIT © Rhyu Miranda. See [`LICENSE`](LICENSE).
