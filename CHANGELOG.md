# Changelog

## [0.15.0](https://github.com/rhyumiranda/canopy/compare/v0.14.0...v0.15.0) (2026-08-16)


### Features

* **dist:** curl one-liner install.sh for non-Homebrew installs ([87e49d6](https://github.com/rhyumiranda/canopy/commit/87e49d67543863a8f4b4f4a1eb6d86b2d04e3811))

## [0.14.0](https://github.com/rhyumiranda/canopy/compare/v0.13.0...v0.14.0) (2026-08-16)


### Features

* **cli:** add canopy doctor install/prereq health check ([8ad7264](https://github.com/rhyumiranda/canopy/commit/8ad726488049c43c653fe344f008503e273875e4))
* **dist:** add Homebrew formula + tap release workflow docs ([20bc319](https://github.com/rhyumiranda/canopy/commit/20bc3190fce35213df475d4e3c8e378ffd5d55b6))
* **upgrade:** make canopy upgrade brew-aware ([dab800a](https://github.com/rhyumiranda/canopy/commit/dab800a7c9c55051b12a0c275ffdf9d21b6934fc))


### Bug Fixes

* **dist:** ship def sources (commands, hooks, skills, dist) in Homebrew formula for first-run auto-wire ([21604b9](https://github.com/rhyumiranda/canopy/commit/21604b9b6d99217e47383d8a84291491a742ecf2))

## [0.13.0](https://github.com/rhyumiranda/canopy/compare/v0.12.0...v0.13.0) (2026-08-16)


### Features

* **review:** merge an adversarial reviewer-edge pass into canopy review ([#80](https://github.com/rhyumiranda/canopy/issues/80)) ([3735ea3](https://github.com/rhyumiranda/canopy/commit/3735ea3c597af17e75b395da32fe1692c3b49354))

## [0.12.0](https://github.com/rhyumiranda/canopy/compare/v0.11.4...v0.12.0) (2026-08-15)


### Features

* **cli:** add worker-callable oracle + plan-gate launch path ([#78](https://github.com/rhyumiranda/canopy/issues/78)) ([9fcc403](https://github.com/rhyumiranda/canopy/commit/9fcc4037c35794d5ff1bd4bb36a2b2264c796601))

## [0.11.4](https://github.com/rhyumiranda/canopy/compare/v0.11.3...v0.11.4) (2026-08-15)


### Bug Fixes

* **reviewer:** verify 'missing symbol' against the whole worktree, not the diff ([#76](https://github.com/rhyumiranda/canopy/issues/76)) ([1d92720](https://github.com/rhyumiranda/canopy/commit/1d927204fb55e59e7267c2b32d10bffc78db4111))

## [0.11.3](https://github.com/rhyumiranda/canopy/compare/v0.11.2...v0.11.3) (2026-08-14)


### Bug Fixes

* four regressions that only affect the installed CLI ([#74](https://github.com/rhyumiranda/canopy/issues/74)) ([2042e63](https://github.com/rhyumiranda/canopy/commit/2042e638568fb1ff6350dddf716c7e78cd10bbb7))

## [0.11.2](https://github.com/rhyumiranda/canopy/compare/v0.11.1...v0.11.2) (2026-08-14)


### Bug Fixes

* **ci:** let auto-merge step resolve repo without a checkout ([#71](https://github.com/rhyumiranda/canopy/issues/71)) ([a2cb732](https://github.com/rhyumiranda/canopy/commit/a2cb732b62b770dbd05505999a2b339952bc8740))

## [0.11.1](https://github.com/rhyumiranda/canopy/compare/v0.11.0...v0.11.1) (2026-08-14)


### Bug Fixes

* **orchestrator:** default stable playbook to built-in Agent worker, isolate Herdr as experimental ([#69](https://github.com/rhyumiranda/canopy/issues/69)) ([187d8c7](https://github.com/rhyumiranda/canopy/commit/187d8c7aa67e78757a56e879bd5cb7f13f307174))
* **pr:** compute PR-body diff scope against fresh remote base ([#67](https://github.com/rhyumiranda/canopy/issues/67)) ([80aa9c1](https://github.com/rhyumiranda/canopy/commit/80aa9c1811f2d011293eae2b26adc1b73bf0d3dc))

## [0.11.0](https://github.com/rhyumiranda/canopy/compare/v0.10.0...v0.11.0) (2026-08-14)


### Features

* **agents:** OMO pre-execution agents + real worker model pin ([#65](https://github.com/rhyumiranda/canopy/issues/65)) ([15f76db](https://github.com/rhyumiranda/canopy/commit/15f76dbe612692a066b41f88c7d9873fa0fa8f28))

## [0.10.0](https://github.com/rhyumiranda/canopy/compare/v0.9.0...v0.10.0) (2026-08-14)


### Features

* **cli:** AXI-ergonomic output — TOON board, task show --full, structured usage errors ([#63](https://github.com/rhyumiranda/canopy/issues/63)) ([9b58a86](https://github.com/rhyumiranda/canopy/commit/9b58a868bd9b88c8715b4b3e8e200484f8ffa385))

## [0.9.0](https://github.com/rhyumiranda/canopy/compare/v0.8.4...v0.9.0) (2026-08-14)


### Features

* **state:** add task dependencies and a contract-first lease gate ([#60](https://github.com/rhyumiranda/canopy/issues/60)) ([011e9dd](https://github.com/rhyumiranda/canopy/commit/011e9dd5a825addc1ed6014e167b3cb6ccb447d6))

## [0.8.4](https://github.com/rhyumiranda/canopy/compare/v0.8.3...v0.8.4) (2026-08-12)


### Bug Fixes

* **scribe:** target the current worktree's AGENTS.md, not the main tree ([#58](https://github.com/rhyumiranda/canopy/issues/58)) ([4a08079](https://github.com/rhyumiranda/canopy/commit/4a08079db4d5d3d1818410bc212b404d7295728f))

## [0.8.3](https://github.com/rhyumiranda/canopy/compare/v0.8.2...v0.8.3) (2026-08-12)


### Bug Fixes

* backport 5 general (non-Herdr) fixes from experimental branch to main ([#51](https://github.com/rhyumiranda/canopy/issues/51)) ([c624e7b](https://github.com/rhyumiranda/canopy/commit/c624e7b390bbd472cb924eba733879c03451a538))

## [0.8.2](https://github.com/rhyumiranda/canopy/compare/v0.8.1...v0.8.2) (2026-08-03)


### Bug Fixes

* **cleanup:** close merged Herdr tabs ([1802957](https://github.com/rhyumiranda/canopy/commit/1802957188ea47666d7e69806ca4dae91dc6006b))
* **cleanup:** close merged Herdr tabs ([6541103](https://github.com/rhyumiranda/canopy/commit/6541103afac173ea927fa8b505675af0f5b2082f))

## [0.8.1](https://github.com/rhyumiranda/canopy/compare/v0.8.0...v0.8.1) (2026-08-03)


### Bug Fixes

* **cleanup:** stop workers after merged PRs ([043cc5d](https://github.com/rhyumiranda/canopy/commit/043cc5d2ab27961fce4eb480a030aa5dfec59320))

## [0.8.0](https://github.com/rhyumiranda/canopy/compare/v0.7.1...v0.8.0) (2026-08-03)


### Features

* **worker:** add Herdr terminal worker workflow ([568e6d8](https://github.com/rhyumiranda/canopy/commit/568e6d829f8ba1bd704146f53194a191f40e38e2))

## [0.7.1](https://github.com/rhyumiranda/canopy/compare/v0.7.0...v0.7.1) (2026-08-03)


### Bug Fixes

* **review:** follow orchestrator harness ([d116c84](https://github.com/rhyumiranda/canopy/commit/d116c84cf3d5ff04cf062a6142c9b7581d4963e2))
* **review:** keep Claude as default reviewer ([1a414b1](https://github.com/rhyumiranda/canopy/commit/1a414b18b597db0f149e24423a7759d516e2f531))
* **setup:** use canonical channel upstream ([f66fc1c](https://github.com/rhyumiranda/canopy/commit/f66fc1cd7a48b91c8b5678926c75f6a1bf216902))
* stabilize Codex setup and start ([d268d19](https://github.com/rhyumiranda/canopy/commit/d268d198855a03a64560229cf7ef68086f1834b4))
* **start:** bypass Codex permission prompts ([53e5b03](https://github.com/rhyumiranda/canopy/commit/53e5b0337452ba3117da57a5cf81031b79a56e4f))

## [0.7.0](https://github.com/rhyumiranda/canopy/compare/v0.6.0...v0.7.0) (2026-08-03)


### Features

* **setup:** install codex skills ([cc8be9b](https://github.com/rhyumiranda/canopy/commit/cc8be9bb17342b1cad0036e177e5674b435d696c))
* **setup:** install codex skills ([6281313](https://github.com/rhyumiranda/canopy/commit/62813137cab6f55a69d9b25bb1db78a4f30e971e))

## [0.6.0](https://github.com/rhyumiranda/canopy/compare/v0.5.0...v0.6.0) (2026-08-03)


### Features

* **setup:** add stable and codex-preview channels ([be0f602](https://github.com/rhyumiranda/canopy/commit/be0f6027777f7a19c5d8c704f7f27bc1fb4f09d2))
* **setup:** add stable and codex-preview channels ([7923c5b](https://github.com/rhyumiranda/canopy/commit/7923c5b93879a78f248c6fc57952e05b473930d2))

## [0.5.0](https://github.com/rhyumiranda/canopy/compare/v0.4.0...v0.5.0) (2026-08-03)


### Features

* **base:** control which branch worktrees are cut from and PRs target ([408a0ff](https://github.com/rhyumiranda/canopy/commit/408a0ff38feb60ab02b9b944aa51ca6f63c381bd))
* **base:** control which branch worktrees are cut from and PRs target ([af13f2b](https://github.com/rhyumiranda/canopy/commit/af13f2bc55aee9a260219d99d95f59422decf9a7))

## [0.4.0](https://github.com/rhyumiranda/canopy/compare/v0.3.0...v0.4.0) (2026-08-03)


### Features

* **review:** strengthen the reviewer with no-mistakes' review brief ([8fe5c3d](https://github.com/rhyumiranda/canopy/commit/8fe5c3d8e4927339062a2d165219d2886f0f35e6))
* **review:** strengthen the reviewer with no-mistakes' review brief ([871ae69](https://github.com/rhyumiranda/canopy/commit/871ae69bf6ca6392babba5070618d8b4c8fa5c82))

## [0.3.0](https://github.com/rhyumiranda/canopy/compare/v0.2.0...v0.3.0) (2026-08-02)


### Features

* **worker:** run the scribe ladder so durable lessons get captured ([00b20df](https://github.com/rhyumiranda/canopy/commit/00b20df1f4c0488d2eb2dd38b4190a90293914df))

## [0.2.0](https://github.com/rhyumiranda/canopy/compare/v0.1.0...v0.2.0) (2026-08-02)


### Features

* **pr:** auto-derive triage labels so PRs are never unlabeled ([696879e](https://github.com/rhyumiranda/canopy/commit/696879e661a6f65d23cf0439e702920146eb41a2))
* **pr:** auto-derive triage labels so PRs are never unlabeled ([b955293](https://github.com/rhyumiranda/canopy/commit/b9552934579ca988d8d5858c41c06648dfed494f))
* **pr:** standardize the PR format and enforce the single open path ([a4e3176](https://github.com/rhyumiranda/canopy/commit/a4e3176889a6c5916974bebec479fa4bb8dde2e2))
* **pr:** standardize the PR format and enforce the single open path ([41fc915](https://github.com/rhyumiranda/canopy/commit/41fc915ac72341d6153db2eac243d99699c0b344))
* **release:** automate releases with release-please ([c221110](https://github.com/rhyumiranda/canopy/commit/c2211109e99f8033fd5afee7fc6a22c9dd3665a7))
* **release:** automate releases with release-please ([3b6c3ef](https://github.com/rhyumiranda/canopy/commit/3b6c3efc29c2082c7fbf36420105d29437cc0f11))
* **upgrade:** 'canopy upgrade' — update from any directory ([ec65eeb](https://github.com/rhyumiranda/canopy/commit/ec65eeb999865b974c8c363a336a2060fe4d0487))
* **upgrade:** 'canopy upgrade' — update from any directory ([3a17355](https://github.com/rhyumiranda/canopy/commit/3a173554574b45402251fc163e10a685d3b6d597))
* **watch:** harden the merge-watcher — self-reconcile, re-arm, status ([6a80e67](https://github.com/rhyumiranda/canopy/commit/6a80e67677bfc6e59bcbce68b84aac232165bf19))
* **watch:** harden the merge-watcher — self-reconcile, re-arm, status ([e6915d2](https://github.com/rhyumiranda/canopy/commit/e6915d27fe4c63558bb2bb3d6fd37e6519204f66))


### Bug Fixes

* **setup:** install a stable CLI snapshot so branch-switching can't break canopy ([f15fc05](https://github.com/rhyumiranda/canopy/commit/f15fc05dac1b6fc105f5ac8030c5ee8d679aca07))
* **setup:** install a stable CLI snapshot so branch-switching can't break canopy ([ed1e63d](https://github.com/rhyumiranda/canopy/commit/ed1e63d649003764019e8593a07aa020549d1ec7))
* **watch:** parse PR state without awk (mawk-safe) ([ad49247](https://github.com/rhyumiranda/canopy/commit/ad49247b65b99e9df4a290bbfed1fbaf6782a49a))
* **watch:** record done before worktree return (can't be aborted) ([4946db5](https://github.com/rhyumiranda/canopy/commit/4946db58152ad4c971e4d2d22227e145b1bf13ee))
