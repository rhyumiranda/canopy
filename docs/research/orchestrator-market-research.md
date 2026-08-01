# Orchestration Layer for AI Coding Agents — Market Research

**Question:** Does a product already exist that does what our "Orchestration Layer" concept does? Adopt if yes; quantify the gap if no.

**Date:** 2026-08-01. **Confidence in landscape coverage:** high. **Confidence in per-product feature detail:** medium — most claims are from vendor pages / reviews / READMEs, not hands-on testing. Flagged where thin.

---

## Our concept, distilled to 10 testable features

1. **Single supervisor orchestrator** that ONLY delegates, never edits code (a Claude Code session).
2. **Persistent brief + state on disk** (`.canopy/` brief.md + state.json) that survives clearing/compacting the orchestrator.
3. **Reusable worktree POOL** — one branch per task; on merge the worktree is *returned* to the pool (keeps build cache), not destroyed.
4. **Worker subagents**, one task per worktree, many in parallel.
5. **Fresh, ephemeral, INDEPENDENT reviewer** that reviews the git **diff only** (never the worker's chat) — anti "grade own homework".
6. **Modes** toggled by command (`/yolo`): Autonomous (reviewer self-fixes) vs Guided (architectural calls surface to human).
7. **Never-exit loop:** diff review → fix → tests + orthogonality (don't break unrelated features) → lint → then PR; repeats until zero issues.
8. **High-empathy PRs** (conventional-commit title, what/why, linked issues, touched files, atomic, breaking-change flags, repro steps, CI green).
9. **One background merge-watcher** for all PRs; on merge → return worktree → mark done.
10. **Human steers/interrupts** any worker from one seat.

The hard, rare combination is **3 + 5 + 7** (reusable pool, *independent* diff-only reviewer, and a never-exit quality loop). Almost everyone has 1/4/8/9/10; few have 5+7 together; very few have 3.

---

## Scorecard (serious contenders)

Legend: ✓ yes · ~ partial/unclear · ✗ no

| Product | 1 Orch-only | 2 Persist state | 3 Worktree POOL (reuse) | 4 Parallel isolate | 5 Independent diff-only reviewer | 6 Auto/Guided modes | 7 Never-exit loop | 8 Rich PRs | 9 Merge-watcher | 10 Steer many | OSS/Paid | Maturity |
|---|---|---|---|---|---|---|---|---|---|---|---|---|
| **firstmate** (kunchenguid) | ✓ | ✓ | ✓ (treehouse) | ✓ | ✗ | ✓ (+yolo) | ✗ | ~ | ~ | ✓ | OSS MIT | Young, active (2.6k★) |
| **Conductor** (Melty Labs) | ~ | ~ (checkpoints) | ✗ (worktree, not pooled) | ✓ | ✗ (you review) | ✗ | ✗ | ~ (opens PR) | ✗ | ✓ | Free app, Mac only | Funded, mature UX |
| **Sculptor** (Imbue) | ~ | ~ | ✗ (Docker containers) | ✓ | ✗ | ✗ | ~ (TDD skills) | ~ | ✗ | ✓ | OSS MIT, beta | Well-funded |
| **Claude Squad** | ✗ (peer sessions) | ✗ | ✗ (worktree, not pooled) | ✓ | ✗ (review workflow=human) | ~ (auto-accept) | ✗ | ~ | ✗ | ✓ | OSS AGPL-3 | Popular |
| **Vibe Kanban** (Bloop) | ~ | ~ | ✗ | ✓ | ✗ (built-in review = human) | ~ | ✗ | ~ | ~ | ✓ | OSS Apache-2 | **Bloop shut down Apr 2026; community-maintained** |
| **Factory.ai** (Droid) | ✓ (coordinator) | ✓ (persistent computer) | ✗ (isolated Codex workspaces) | ✓ | ~ (review droid = a role, not guaranteed independent/diff-only) | ~ (missions) | ✗ | ✓ | ~ | ✓ | Paid/enterprise | Mature |
| **Devin** (Cognition) | ✓ (Devin spawns Devins) | ✓ | ✗ (cloud sandboxes) | ✓ | ✓ (**Devin Review** separate agent) | ~ | ~ (autofix loop) | ✓ | ~ | ✓ | Paid (pricey) | Mature |
| **Cursor 3** (Agents Window) | ✗ | ✗ | ~ (worktree per agent, not pooled) | ✓ (up to 8) | ✗ | ✗ | ✗ | ~ (opens PR) | ✗ | ✓ | Paid IDE | Mature |
| **GitHub Agent HQ / Copilot app** | ~ (mission control) | ~ | ✗ | ✓ (multi-vendor) | ✗ | ~ (steer mid-run) | ✗ | ✓ (native PR) | ~ (GitHub merge) | ✓ | Paid | Mature, GitHub-native |
| **Sourcegraph Amp** | ~ | ✗ | ✗ | ✓ (subagents) | ✗ ("can't orchestrate them") | ✗ | ✗ | ~ | ✗ | ~ | Paid | Mature |
| **OpenHands** (OpenDevin) | ~ (delegation) | ~ | ✗ (sandboxes) | ✓ | ✗ | ✗ | ~ | ✓ (PRs) | ✗ | ~ | OSS (60k★) | Mature |
| **Google Jules** | ✗ | ~ | ✗ (cloud VM) | ✓ (10 tasks) | ✗ | ✗ | ✗ | ✓ (PR) | ~ | ~ | Paid tiers | Mature |
| **claude-swarm** (ruby) | ✓ | ✓ (FAISS memory) | ✗ | ✓ | ~ (can spawn reviewers) | ✗ | ✗ | ~ | ✗ | ✓ | OSS framework | DIY |
| **Terragon/Terry** | ~ | ✓ | ✗ (remote sandboxes) | ✓ | ✗ | ~ | ✗ | ✓ (PR) | ~ | ✓ | **Open-sourced at shutdown Jan 2026** | Dead as product |

Notes on thin evidence: firstmate's row is from its README claims (not tested). Factory's "review droid" independence and Devin Review's diff-only isolation are inferred from marketing, not verified against our exact definition. "Merge-watcher" (col 9) is rarely a named feature; most tools open PRs and let GitHub/human merge, so I scored ✓ only where a merge queue exists.

---

## The distinctive primitives, and who has each

**Reusable worktree POOL (feature 3)** — rare. The only clean match is **treehouse** (github.com/kunchenguid/treehouse): "manage a pool of reusable, isolated Git worktrees… worktrees are preserved in a pool when done, with dependencies and build cache intact, ready for the next agent." Everyone else (Conductor, Cursor, Claude Squad) makes a worktree per task and tears it down, or uses containers/cloud sandboxes instead of worktrees (Sculptor=Docker, Devin/Jules/Terragon=cloud VMs). This is the exact primitive our concept already picked.

**Independent, diff-only reviewer (feature 5)** — rare as a first-class, *independent* step.
- **Devin Review** is the strongest productized version: a separate review agent that reviews the diff of any PR (human- or agent-authored) and can autofix. It is a distinct agent, not the author grading itself. (cognition.com/blog/devin-review)
- **Factory** ships a dedicated "review" droid role alongside code/test/docs droids — but it's a role in the same crew, independence-from-author not guaranteed by design.
- Small OSS projects implement blind/independent review explicitly: **loki-mode** ("blind three-reviewer code review"), **kodo** ("separate agent independently verifies results"), **ralphex** ("fresh session per task… multi-phase review"). These prove the pattern but are hobby-grade.
- Everyone else's "review" is a **human** looking at diffs before merge (Conductor, Claude Squad, Vibe Kanban, Cursor) — not an independent agent.

**Never-exit quality loop with orthogonality gate (feature 7)** — essentially nobody ships the full "review→fix→tests+don't-break-unrelated→lint→PR, repeat until zero issues." Closest partials: Devin's autofix-review loop, Aperant's "self-validating QA loop", ralph-orchestrator/ralphex "loop until done." The **orthogonality check** (don't break unrelated features) is not a named feature anywhere I found.

**Persistent brief surviving compaction (feature 2)** — this is a known Claude Code pattern (externalize plan/decisions to disk; SessionStart hook re-injects on `source=compact`), used by firstmate ("all state lives on disk… next session reconciles"), claude-swarm (FAISS memory), Factory ("persistent computer"). Not unique to us, but not universal either.

---

## Closest match and exactly where it falls short

**Closest = firstmate** (github.com/kunchenguid/firstmate), by the same author as treehouse. It is essentially our design's skeleton: one "first mate" orchestrator you talk to that dispatches "crewmates," each in a **treehouse worktree pool**, all state on disk and reconciled across sessions, delivers finished PRs / approved local merges, human makes captain-level calls, and a `+yolo` autonomy flag plus project modes (no-mistakes / direct-PR / local-only) = our Autonomous-vs-Guided toggle. That's **features 1, 2, 3, 4, 6, 9(~), 10** — the whole coordination substrate, including the exact worktree-pool primitive we chose.

**Where firstmate falls short of our concept (the gap):**
- **No dedicated independent reviewer (feature 5).** No fresh, ephemeral agent that reviews the *diff only* (never the worker's chat) to break the echo chamber.
- **No never-exit quality loop (feature 7).** No enforced review→fix→tests+**orthogonality**→lint gate that repeats until zero issues before a PR opens.
- PR richness (8) and merge-watcher (9) exist but aren't specified to our "high-empathy PR" / single-background-watcher bar.

Second-closest = **Devin** (has the independent reviewer via Devin Review + autofix loop + orchestrates sub-Devins) but it's a closed, pricey cloud product using cloud sandboxes, not a local Claude Code + reusable-worktree-pool design — you can't own/self-host it and it doesn't use the pool primitive.

---

## Verdict

**No single product ships all 10 features.** But the honest read is **not** "build from scratch." The coordination substrate (1,2,3,4,6,9,10) already exists in **firstmate**, built on the same **treehouse** pool we independently chose. The genuinely unfilled gap — the market opportunity — is the **independence + quality-loop half of the design**: a **fresh ephemeral reviewer that reads the diff only**, driving a **never-exit review→fix→tests+orthogonality→lint loop until zero issues**, before a high-empathy PR opens. Devin proves the independent-reviewer value but only inside a closed cloud product; the OSS local-worktree world (firstmate, Conductor, Sculptor, Claude Squad, Cursor) still leaves "review" to a human.

**Recommendation: ADOPT-as-base + BUILD-the-gap.**
- **Adopt** firstmate + treehouse as the orchestrator/worktree-pool/state/modes/steering substrate (don't rebuild features 1–4, 6, 9, 10).
- **Build** our differentiator on top: features **5 + 7** — the independent diff-only reviewer and the never-exit orthogonality/test/lint loop — plus the high-empathy PR spec (8).

**Confidence:** medium-high on the landscape and on the location of the gap; medium on firstmate's exact maturity/fit (README-based, untested, young project — validate hands-on before committing).

---

## Sources

- Claude Squad — https://dev.to/stevengonsalvez/claude-squad-run-multiple-ai-agents-in-parallel-without-the-mess-1hfl , https://vibecodinghub.org/tools/claude-squad
- Vibe Kanban (status/shutdown) — https://www.vibekanban.com/blog/shutdown , https://github.com/BloopAI/vibe-kanban , https://nimbalyst.com/blog/vibe-kanban-after-bloop-whats-next/
- Conductor — https://conductor.build , https://chatgate.ai/post/conductor , https://alternativeto.net/software/conductor
- Sculptor (Imbue) — https://imbue.com/product/sculptor , https://imbue.com/blog/sculptor-announce , https://github.com/imbue-ai/sculptor
- Terragon/Terry — https://github.com/terragon-labs/terragon-oss , https://terragon.devdocs.ai/
- tmux-orchestrator / claude-swarm-orchestration — https://github.com/absmartly/Tmux-Orchestrator , https://github.com/MaTriXy/claude-swarm-orchestration
- Devin (parallel + orchestration) — https://aidevsetup.com/insider/devin-agents-can-now-orchestrate-other-devins-what-it-means , https://devincentral.com/news/editorial-devin-review-bottleneck/
- Devin Review (independent reviewer) — https://cognition.com/blog/devin-review , https://docs.devin.ai/work-with-devin/devin-review , https://cognition.com/blog/closing-the-agent-loop-devin-autofixes-review-comments
- Cursor 3 parallel agents/worktrees — https://www.agentpatterns.ai/tools/cursor/agents-window/ , https://agentmarketcap.ai/blog/2026/04/05/cursor-april-2026-agent-mode-overhaul-background-agents-ide-convergence
- OpenHands — https://agentwiki.org/openhands , https://aiagentslist.com/agents/openhands
- Factory.ai Droid — https://www.digitalapplied.com/blog/factory-ai-multi-agent-coding-platform-review , https://rywalker.com/research/factory-ai , https://factory.ai/news/terminal-bench
- Sourcegraph Amp — https://deepwiki.com/x1xhlol/system-prompts-and-models-of-ai-tools/5.3-amp-by-sourcegraph , https://baeseokjae.github.io/posts/amp-code-review-2026/
- Google Jules / Copilot coding agent — https://www.tembo.io/blog/jules-alternatives , https://www.respan.ai/market-map/compare/github-copilot-vs-google-jules
- GitHub Agent HQ / mission control — https://github.blog/news-insights/company-news/welcome-home-agents/ , https://github.blog/ai-and-ml/github-copilot/how-to-orchestrate-agents-using-mission-control/ , https://visualstudiomagazine.com/articles/2025/10/28/github-introduces-agent-hq-to-orchestrate-any-agent-any-way-you-work.aspx
- claude-swarm (ruby) — https://www.ruby-toolbox.com/projects/claude_swarm , https://github.com/affaan-m/claude-swarm
- treehouse (worktree pool) — https://github.com/kunchenguid/treehouse , https://context7.com/kunchenguid/treehouse
- firstmate (closest match) — https://github.com/kunchenguid/firstmate
- awesome-agent-orchestrators (loki-mode, kodo, ralphex, Aperant, gastown, Fusion, etc.) — https://github.com/andyrewlee/awesome-agent-orchestrators
- Persistent-state-across-compaction patterns — https://github.com/anthropics/claude-code/issues/25999 , https://hidekazu-konishi.com/entry/claude_code_compaction_and_long_session_guide.html
</content>
</invoke>
<invoke name="WebSearch">
<parameter name="query">Conductor Melty Labs website conductor.build features diff review merge