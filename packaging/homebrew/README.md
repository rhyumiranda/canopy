# Homebrew packaging

`canopy.rb` here is the **canonical, reviewed** Homebrew formula. Users install
via a tap:

```sh
brew install rhyumiranda/tap/canopy
```

That resolves to the repo `rhyumiranda/homebrew-tap`, file `Formula/canopy.rb`.
This directory's copy is the source of truth; the tap copy is a mirror.

## Build model

Build-from-source with **no compile step** — Canopy is pure bash. `install`
stages the CLI under `libexec` and puts `canopy` on `PATH` via a symlink:

```ruby
libexec.install "bin", "lib", "agents"
bin.install_symlink libexec/"bin/canopy"
```

`bin/canopy` follows a `readlink` chain to locate its own `lib/` (it is designed
to run through a PATH symlink). Through the brew symlink the chain resolves to
`libexec/bin/canopy`, and `CANOPY_ROOT` climbs one dir to `libexec`, where
`lib/` and `agents/` sit next to `bin/` — so `lib/` loads correctly. The
existing `test/bin_symlink_test.sh` covers this chained-symlink resolution.

The formula installs the **CLI only**. The Claude/Codex agent defs (the
`~/.claude` + `~/.codex` wiring) are **not** written by the formula — brew must
not write to `$HOME`. They wire automatically on the first `canopy` run
(idempotent). The prereqs `claude` (v2.1+), `treehouse`, and `gh-axi` are not on
Homebrew; they are listed in `caveats` and checked by `canopy doctor`.

## Publishing a release (manual, run by the maintainer)

The `sha256` cannot be known until the tag's tarball exists, so it is a
`PLACEHOLDER_SHA256` here until publish. After `release-please` tags `vX.Y.Z`:

1. Download the release tarball and hash it:
   ```sh
   VERSION=X.Y.Z
   curl -sL "https://github.com/rhyumiranda/canopy/archive/refs/tags/v${VERSION}.tar.gz" -o canopy.tar.gz
   shasum -a 256 canopy.tar.gz
   ```
2. In `packaging/homebrew/canopy.rb`, update:
   - `url` -> the `v${VERSION}` tarball,
   - `sha256` -> the hash from step 1.
   (Homebrew derives `version` from the `url` tag, so there is no separate
   `version` line to bump.)
3. Mirror the updated `canopy.rb` to `rhyumiranda/homebrew-tap` as
   `Formula/canopy.rb`, add a row to that repo's formula table, commit, and
   push. `brew install rhyumiranda/tap/canopy` now installs the new version.
4. Verify: `brew install rhyumiranda/tap/canopy` then `canopy --version` should
   print `canopy ${VERSION}`.

## Future nice-to-have

Automate steps 1-3 with a GitHub Action triggered on the release tag (compute
the sha256, patch `canopy.rb`, and open a PR / push to the tap repo) so releases
stay installable without a manual bump. Not wired up yet — the process above is
the current source of truth.
