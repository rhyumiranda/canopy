# no-mistakes — evaluation as Canopy's quality-gate engine

**Date:** 2026-08-01 · **Author:** research pass for Canopy
**Verdict:** **USE wholesale as the gate engine.** no-mistakes already *is* the
review→test→docs→lint→push→PR→CI pipeline with an **independent, fresh,
diff-only reviewer** — the exact thing Canopy said was its differentiator.
Canopy should not rebuild it; Canopy should invoke it and spend its own effort
on cost/model orchestration around it.

## Sources actually read (not descriptions)

- Installed skill: `/Users/rhyu/.claude/skills/no-mistakes/SKILL.md` (248 lines — the full driving contract).
- GitHub source (cloned `github.com/kunchenguid/no-mistakes`, MIT, © 2026 Kun Chen):
  - `internal/pipeline/steps/review.go` — the review step (prompt, diff build, session call). **Decisive for the independence question.**
  - `internal/pipeline/sessions.go` — `SessionRole` reviewer/fixer isolation.
  - `internal/pipeline/executor.go` — step loop + auto-fix + gate parking.
  - `docs/src/content/docs/concepts/{pipeline,gate-model,auto-fix}.md`
  - `docs/src/content/docs/reference/pipeline-steps.md` (per-step behavior)
  - `docs/src/content/docs/guides/agents.md` (agent architecture, session reuse, intent extraction)
  - `LICENSE` (MIT), `go.mod` (module `github.com/kunchenguid/no-mistakes`, no firstmate dep), `.no-mistakes.yaml` (its own dogfood config).
- Local downstream port: `/Users/rhyu/Documents/Repository/utils/rhyu/ship-and-sleep/docs/{TECH-DESIGN,PRD}.md` — Rhyu's own fork that "ports the proven git-safety core from the MIT-licensed no-mistakes."
- firstmate coupling direction: `~/.claude/jobs/9d1a7d4d/tmp/firstmate/.no-mistakes.yaml` + `.github/workflows/no-mistakes-required.yml` — firstmate is a **consumer** of no-mistakes, not the other way around.

---

## 1. Pipeline stages — exact order

Fixed, non-configurable 9-step order (`docs/concepts/pipeline.md`, `pipeline-steps.md`):

```
intent → rebase → review → test → document → lint → push → pr → ci
```

| # | Step | What it runs | Default auto-fix limit |
|---|------|--------------|------------------------|
| 1 | Intent | Use supplied `--intent`, else infer from local agent transcripts | n/a |
| 2 | Rebase | Fetch fresh upstream + push-target, rebase onto them; stop if bundling unpushed local-default commits | 3 |
| 3 | **Review** | **AI code review of the diff** (fresh agent, structured findings + risk level) | **0 (requires approval)** |
| 4 | Test | *Targeted* local validation + evidence for intent (explicitly **not** a full CI suite) | 3 |
| 5 | Document | Update docs for changed code, report unresolved gaps | initial pass |
| 6 | Lint | `commands.lint`, or agent-driven detect+fix (shares document housekeeping pass when no lint cmd) | 3 |
| 7 | Push | Force-with-lease safe push to configured target; refuses to discard un-incorporated remote commits | n/a |
| 8 | PR | Create/update PR via `gh`/`glab`/`az`/Bitbucket API; conventional-commit title, `## Intent`/`## What Changed`/`## Pipeline` body | n/a |
| 9 | CI | Poll CI + mergeability; auto-fix failures/conflicts; background-monitor until merged/closed/idle-timeout | 3 |

You can configure *what* each step runs (commands, agent, auto-fix limits,
ignore paths) but **not the order and not which steps exist**. That's a
deliberate design choice so "passed the gate" means the same thing everywhere.

---

## 2. Is its review INDEPENDENT or self-review? — **INDEPENDENT.** (the key answer)

**The review is a fresh, separate agent that reads only the diff + intent. It is
NOT the coding worker reviewing its own in-session work.** This is the single
most important finding for Canopy, and it is unambiguous in the code.

Evidence:

- **The driving/worker agent is explicitly *not* the reviewer.**
  `docs/guides/agents.md`:
  > "The coding agent that calls `no-mistakes axi` drives approval gates, but it
  > does not automatically become the pipeline agent that performs review,
  > evidence testing, documentation… Those jobs run in the **daemon's disposable
  > worktree through the configured pipeline agent**."

  The worker commits code and calls `axi run`. A **separate agent subprocess**,
  spawned by the daemon in a throwaway worktree, does the review. They do not
  share a session or context.

- **The reviewer receives only the diff, base/head SHAs, and intent — no coding
  transcript.** `internal/pipeline/steps/review.go` builds the prompt from
  `branch`, `baseSHA`, `sctx.Run.HeadSHA`, `reviewScope`, `ignorePatterns`, and
  a structured-output schema, then instructs: *"Read the relevant history and
  diff yourself."* The changed-file set comes from a raw
  `git diff --name-only … baseSHA..headSHA`. The reviewer starts cold from the
  diff.

- **Reviewer and fixer sessions are isolated by role.**
  `internal/pipeline/sessions.go`:
  > "The reviewer role spans the initial full review and every full rereview in
  > a run; the fixer role spans every review-fix turn. The two are never mixed,
  > so **the reviewer never inherits the fixer's working context**."

  And in `review.go`: *"the session only carries the reviewer's own prior
  context, never the fixer's."* So even across fix rounds, the thing that
  *judges* the code is never contaminated by the thing that *wrote/fixed* it.

- **Intent is used as acceptance criteria to check against, not instructions to
  obey.** `internal/pipeline/steps/intent_prompt.go`: *"the reviewer is asked to
  check the diff against the stated criteria, not to obey them."* A change that
  removes required behavior or adds forbidden behavior becomes an `ask-user`
  finding rather than being waved through.

**Nuance Canopy must note:** "independent" here means *fresh session, diff-only,
no worker context* — which is exactly what Canopy wanted. It does **not** by
default mean a *different model*. The reviewer runs on the configured "pipeline
agent" (e.g. `claude`), which may be the same model family as the worker. If
Canopy wants adversarial *model diversity* on top of session independence, it
gets it for free by setting a repo/global `agent` override so the pipeline agent
is a different model than the worker (e.g. worker = Sonnet, gate = a different
provider). No code change needed — it's a config field.

**Conclusion:** no-mistakes' review is a genuine independent diff-only reviewer,
not an echo chamber. **Canopy does not need to build one — this is already it.**

---

## 3. Loop behavior — bounded auto-fix + gates; git-hook-enforced (not Stop-hook)

- **Per-step auto-fix loop, bounded.** `internal/pipeline/executor.go` +
  `docs/concepts/auto-fix.md`: a step runs → returns findings → if auto-fix is
  enabled and findings are `auto-fix`-eligible, the agent fixes and the step
  re-runs, up to the step's limit (default 3; **review defaults to 0 = always
  parks for approval**). When the limit is hit or blocking/`ask-user` findings
  remain, it **parks at a gate** for the driving agent/human.
- **Not an infinite "never-exit until clean" by itself.** The loop-until-green
  behavior is a property the *driving agent* enforces by looping
  `axi respond` → gate → respond until `outcome: checks-passed|passed`. With
  `--yes` the agent drives every gate unattended (fixes all findings, approves
  fix-review, approves no-op gates). On a `failed`/`cancelled` outcome the agent
  must `rerun`. So "never exit until CI-green" = SKILL.md's documented driving
  loop, not a hardcoded infinite loop.
- **Enforcement is at the git layer, stronger than a Claude Stop/SubagentStop
  hook.** `docs/concepts/gate-model.md`: `init` puts a **local bare "gate" repo**
  between your working repo and the real target, with a `pre-receive` admission
  hook + `post-receive` notification hook. You push to a named `no-mistakes`
  remote; the daemon runs the pipeline in a disposable worktree and only forwards
  to the real target after the gate passes. **A raw `git push` that tries to
  bypass the CLI is refused** ("An active validation-step descendant is refused,
  including a direct push that bypasses the CLI"). This is a hard, process-level
  gate — you cannot ship un-reviewed code to the target without disabling the
  remote.
- **CI is background-monitored.** `axi run` returns `checks-passed` the moment CI
  is green + mergeable (does not block on human merge); the daemon keeps watching
  and auto-rebases/fixes conflicts in the background until merged/closed/idle.

---

## 4. Token cost — **LEAN from the orchestrator's context perspective**

- **No big always-on contract.** Unlike firstmate's ~22k-token always-loaded
  instructions, no-mistakes' only always-on footprint in the driving agent is
  the on-demand **SKILL.md (~248 lines, a few k tokens)**, and it only matters
  when `/no-mistakes` is invoked. Everything else is a **compiled Go binary +
  background daemon**.
- **The heavy LLM work runs in isolated daemon subprocesses, not in the
  orchestrator's context window.** Review, test-evidence, doc, lint-fix, PR-draft
  and CI-fix agent calls are spawned by the daemon in its own worktree with their
  own sessions (`docs/guides/agents.md`, `agent.RunOpts`). Those tokens are spent
  by the gate's subprocess agents; they never pollute or inflate the driving
  agent's window. From Canopy's orchestration-layer view this is the ideal
  shape: **a CLI you call, not a prompt you carry.**
- **What actually drives cost** (real LLM spend, wherever it lands): number of
  pipeline agent invocations × diff size — one full-diff review per review turn
  (+ one per rereview), fix rounds (≤ limit per step), targeted test-evidence
  generation, doc/lint housekeeping, PR-body draft, and CI-failure fixes. Session
  reuse (`session_reuse: true`) keeps one reviewer + one fixer session per run to
  cut re-priming cost, and the fixer is explicitly forbidden from re-running the
  whole test/lint suite (a measured optimization: a forensic audit found the
  fixer re-running the full suite ~5×/round, ~784s of a 2419s review step — see
  the comment block in `review.go`). Cost scales with change size and how many
  fix rounds are needed, which is inherent to any real gate.

**Bottom line:** lean where Canopy cares (context window / always-on cost);
the unavoidable LLM spend is per-run and isolated, and is roughly the minimum a
real review+test+fix gate can cost.

---

## 5. Invocation & I/O

- **Invoked** three ways: (a) the `/no-mistakes` **skill** in Claude Code / any
  skill-aware agent; (b) directly via the **`no-mistakes axi`** command family
  (machine-readable TOON on stdout, progress on stderr); (c) implicitly by
  **`git push no-mistakes <branch>`** (the git-hook gate).
- **Input:** committed work on a **feature branch** (not default) in a repo that
  ran `no-mistakes init`, plus a `--intent "<what the user set out to
  accomplish>"` string. Task-first mode (`/no-mistakes <task>`) has the agent do
  the work, commit on a branch, then validate with the task as intent.
- **Output:** TOON `gate:` objects (findings table with `id/severity/file/
  action`) that the driving agent responds to (`--action approve|fix|skip`,
  optional `--yes`), terminating in `outcome: checks-passed | passed | failed |
  cancelled`. Successful outcomes carry the PR URL and a `fixes` table of what
  the pipeline fixed that the original change missed.
- **Does it use `-axi` tools?** **No.** The `axi` here is no-mistakes' *own*
  non-interactive command surface (`no-mistakes axi …`), unrelated to Canopy's
  `gh-axi` / `treehouse` / `-axi` family. no-mistakes talks to GitHub via the
  plain **`gh`** CLI (and `glab`/`az`/Bitbucket API), **not `gh-axi`**. It does
  not use `treehouse`. So if Canopy standardizes on `gh-axi`, note that
  no-mistakes owns PR/CI itself through `gh` — you'd let it, or not use its
  PR/CI steps.

---

## 6. Coupling & license — **standalone, MIT**

- **Standalone.** `go.mod` module is `github.com/kunchenguid/no-mistakes` with
  **no firstmate dependency**. The coupling runs the *opposite* direction from
  the concern in the brief: **firstmate is a consumer of no-mistakes** — the
  firstmate repo ships a `.no-mistakes.yaml` (per-repo gate overrides) and a
  `no-mistakes-required.yml` workflow enforcing "PR must be raised via
  no-mistakes." no-mistakes is the engine; firstmate is one distro that uses it.
- **License: MIT**, © 2026 Kun Chen. Permits use, vendoring, and forking. Rhyu's
  own `ship-and-sleep` already exercises this: it "ports the proven git-safety
  core from the MIT-licensed no-mistakes" and layers a tightened, risk-aware
  pipeline (adversarial verify, convergence loop, risk scoring, instinct ledger)
  on top.
- **Runtime deps:** git, a supported agent CLI (`claude`/`codex`/`opencode`/
  `rovodev`/`pi`/`copilot`/`cursor+acpx`), and `gh`/`glab`/`az` for PR/CI. Ships
  as a single binary + background daemon (SQLite state, Unix socket, bare gate
  repos under `~/.no-mistakes/`).

---

## 7. Fit for Canopy — **USE wholesale; add cost/model orchestration around it**

Canopy's stated core: *independent fresh diff-only reviewer* driving a
*review→fix→test→lint→PR loop*, *hook-enforced*, *CI-green gated*, *lean*.
Map that against no-mistakes:

| Canopy requirement | no-mistakes today | Gap? |
|---|---|---|
| Independent, fresh, diff-only reviewer | ✅ Review step: separate daemon-spawned agent, diff+intent only, reviewer/fixer sessions isolated | **None** — this is the differentiator, already built |
| review→fix→test→lint→docs→push→PR→CI loop | ✅ Full fixed 9-step pipeline with bounded auto-fix | **None** |
| Hook-enforced (can't bypass) | ✅ git `pre-receive` bare-gate — stronger than a Claude Stop hook; raw push refused | **None** (different mechanism than Stop/SubagentStop, but hard-enforced) |
| Ships PRs, CI-green gated | ✅ Push/PR/CI steps via `gh`; returns `checks-passed` only when green+mergeable | Uses `gh`, **not `gh-axi`** |
| Lean, no big always-on cost | ✅ Skill + binary; heavy work in isolated subprocesses | **None** |
| Ships via `gh-axi` / uses `treehouse` | ❌ owns PR/CI via `gh` itself | Minor — let it own PR/CI, or skip its PR/CI steps |

**Recommendation: USE-wholesale as the quality-gate engine.** no-mistakes is not
"parts to harvest" — it's a shipped, MIT, self-contained gate that already
delivers Canopy's differentiator. Harvesting its Go internals into Canopy would
be reinventing a mature daemon. Invoke it instead.

### Concrete integration

1. **`no-mistakes init`** in each managed repo (installs the bare gate + daemon +
   the `/no-mistakes` skill; idempotent).
2. Canopy's **worker** does the task and commits on a **feature branch**.
3. Worker (or Canopy's orchestrator) calls
   **`no-mistakes axi run --intent "<goal + decisions/tradeoffs>"`**. This *is*
   the gate: independent review → test → docs → lint → safe push → PR → CI, all
   in the daemon's disposable worktree.
4. Canopy's **orchestrator drives the respond loop** (relay `ask-user` findings,
   `--action fix/approve`, or `--yes` for unattended) until
   `outcome: checks-passed`, then hands the PR to a human to merge.
5. **For stronger independence,** set the pipeline `agent` (repo/global config)
   to a **different model than the worker** so the reviewer is adversarial by
   model as well as by session. Free, config-only.
6. **Canopy spends its own build effort on what no-mistakes does NOT do:** cost
   accounting / model routing / cheap-worker + independent-gate economics — i.e.
   Canopy becomes the *cost-aware orchestrator that drives no-mistakes*, not a
   reimplementation of the gate.

### What Canopy does NOT need to build

- An independent reviewer (review step already is one).
- A test→lint→docs→push→PR→CI pipeline (all nine steps exist).
- Force-push safety, rebase-onto-fresh-upstream, PR body generation, CI
  auto-fix/conflict-rebase (all present, battle-tested, with regression tests).

### Honest caveats / risks

- **You adopt a daemon + bare-gate architecture as a dependency.** no-mistakes is
  infrastructure (background daemon, SQLite, git hooks, `~/.no-mistakes/`), not a
  lightweight library. A "lean orchestration layer" taking it on means taking on
  that operational surface. It is exactly the pipeline Canopy chose not to
  rebuild — but it is still a real dependency to run and keep alive.
- **PR/CI is via `gh`, not `gh-axi`/`treehouse`.** If Canopy wants everything
  through its `-axi` tooling, either let no-mistakes own PR/CI (recommended — it's
  robust) or skip its `pr`/`ci` steps (`--skip=pr,ci`) and wire your own after
  `checks-passed`… but that gives up its CI auto-fix loop, so prefer letting it
  own them.
- **Independence is session-level by default, not model-level.** True adversarial
  independence (different model) needs the `agent` override (step 5). Cheap but
  don't forget it.
- **Alternative worth weighing:** Rhyu's own **`ship-and-sleep`** already forks
  the no-mistakes safety core and adds an adversarial skeptic + convergence loop
  + risk routing + instinct ledger — closer to Canopy's ambitions than upstream.
  If Canopy wants the risk-aware/adversarial layer too, building on
  `ship-and-sleep` (or merging its ideas) may beat plain upstream no-mistakes.
  Decide: upstream (simpler, maintained by Kun Chen) vs. the local fork (richer,
  self-owned).

---

## One-line answer

no-mistakes is the fresh-diff-only-reviewer + full ship pipeline Canopy was about
to rebuild — MIT, standalone, lean on context. **Use it wholesale as the gate;
point a different model at its reviewer for adversarial independence; and put
Canopy's energy into cost/model orchestration around it, not into a second
reviewer or a second pipeline.**
