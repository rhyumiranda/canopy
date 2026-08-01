---
description: Record durable, project-intrinsic knowledge to AGENTS.md (not task notes)
argument-hint: "[fact]"
allowed-tools: Bash(canopy:*)
---

Distill what the recent work **taught us** about this project, and record only facts that pass BOTH gates:
1. **Non-obvious** — you'd have gotten it wrong without being told; not visible by reading one file.
2. **Changes future action** — next time it changes what an agent would *do*.

For each such fact, run `canopy scribe add "<one-line fact, action first>"`. Skip anything task-specific, obvious, or re-derivable from the code. If **$ARGUMENTS** is provided, record that directly. Then briefly report what you added (or that nothing qualified).

This appends to the committed `AGENTS.md`, which every agent auto-loads — so the knowledge compounds. It is NOT the per-change "document" step.
