---
description: Set/toggle Canopy autonomy — yolo (autonomous) or guided (human-gated), global
argument-hint: "[yolo|guided]"
allowed-tools: Bash(canopy:*)
---

If **$ARGUMENTS** is given, run `canopy mode "$ARGUMENTS"`. Otherwise run `canopy mode` to show the current mode.

- **yolo** — autonomous: the review→fix loop resolves and fixes on its own; don't ask the human.
- **guided** (default) — surface real architectural decisions to the human (AskUserQuestion), then delegate the answer back to the worker and re-review.

Report the resulting mode.
