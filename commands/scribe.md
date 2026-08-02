---
description: Record durable, project-intrinsic knowledge to AGENTS.md (curate, don't hoard)
argument-hint: "[fact]"
allowed-tools: Bash(canopy:*)
---

AGENTS.md is read by every agent, every session — so every line costs forever. Your job is to keep only what earns its place, and to clean up as you add. Run this ladder.

**1. Inspect first.** Run `canopy scribe list` to see the numbered entries already there.

**2. For each thing the recent work taught you, apply the gate:**
- **Durable?** Useful to *almost every* future session here — not just this task. (else → drop)
- **Non-obvious?** You'd have gotten it wrong without being told; not visible by reading one file. If the code already shows it → record a *pointer* to that file/function/command, not the fact itself.
- **Changes future action?** Next time it changes what an agent would *do*.

Skip anything that fails a gate: task-specific notes, chronology, what-happened-today, obvious facts, or anything re-derivable from the code.

**3. Placement — pick the action, don't default to add:**
- Already an entry on this topic? → `canopy scribe replace <n> "<better one-line fact>"` (rewrite/merge; don't add a near-duplicate).
- Stale or now-wrong entry? → `canopy scribe rm <n>`.
- Genuinely new, no existing owner? → `canopy scribe add "<one-line fact, action first>"`.

**4. Proportionality.** Trivial task that taught nothing durable → record nothing. That's a valid outcome.

If **$ARGUMENTS** is provided, treat it as a candidate fact: still inspect and prefer replace over add if it overlaps an existing entry.

Then briefly report what you added / replaced / removed (or that nothing qualified). If `canopy scribe add` warns that the file is over its soft budget, prune or merge the weakest entries before finishing.

This edits the committed `AGENTS.md`, which every agent auto-loads — so the knowledge compounds *and stays lean*. It is NOT the per-change "document" step.
