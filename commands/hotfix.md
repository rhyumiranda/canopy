---
description: Urgent fix — spawn a fast isolated worker (fresh worktree, yolo, no review)
argument-hint: <what broke>
allowed-tools: Bash(canopy:*)
---

The user needs an urgent fix outside the normal flow: **$ARGUMENTS**

Run `canopy hotfix "$ARGUMENTS"`. This leases a fresh treehouse worktree and spawns a fast worker in YOLO with review budget 0 to fix it, then opens a PR. You (the orchestrator) still do not edit project code yourself — this is the fast isolated path, not a bypass of isolation.

Report the task id and where it landed.
