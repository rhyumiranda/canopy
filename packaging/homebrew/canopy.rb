# Homebrew formula for the Canopy CLI (build-from-source bash, no compile).
#
# CANONICAL COPY, versioned + reviewed here. The PUBLISHED tap lives at
# rhyumiranda/homebrew-tap as Formula/canopy.rb — mirror every change there.
# The url/sha256 bump on each release is documented in
# packaging/homebrew/README.md (the sha256 can only be computed after the tag
# exists, so it is a PLACEHOLDER here and the publisher fills it in).
class Canopy < Formula
  desc "Orchestration layer for AI coding agents"
  homepage "https://github.com/rhyumiranda/canopy"
  url "https://github.com/rhyumiranda/canopy/archive/refs/tags/v0.13.0.tar.gz"
  sha256 "PLACEHOLDER_SHA256"
  license "MIT"

  # Pure bash — nothing to compile. Runtime prereqs on Homebrew:
  depends_on "git"
  depends_on "jq"
  # claude (v2.1+), treehouse, and gh-axi are NOT on Homebrew — see caveats.
  depends_on :macos

  def install
    # Stage the whole CLI under libexec, then put `canopy` on PATH via a symlink.
    # bin/canopy follows its readlink chain to find lib/: the PATH symlink ->
    # libexec/bin/canopy resolves to the real file, and CANOPY_ROOT climbs one
    # dir to libexec, where lib/ and agents/ sit alongside bin/. So lib/ loads
    # correctly through the brew symlink (test/bin_symlink_test.sh covers the
    # chained-symlink resolution).
    libexec.install "bin", "lib", "agents"
    bin.install_symlink libexec/"bin/canopy"
  end

  def caveats
    <<~EOS
      Canopy — an orchestration layer for AI coding agents.

      brew installs the CLI only. Three prereqs are NOT on Homebrew — install
      them separately:
        - claude (Claude Code, v2.1+)  https://code.claude.com/docs
        - treehouse (worktree pool)    https://github.com/kunchenguid/treehouse
        - gh-axi (GitHub CLI wrapper)
      Run `canopy doctor` to check every prereq and its version.

      Claude/Codex agent defs wire automatically on first run (idempotent).

      macOS merge-watcher (optional): canopy watch install
    EOS
  end

  test do
    assert_match version.to_s, shell_output("#{bin}/canopy --version")
  end
end
