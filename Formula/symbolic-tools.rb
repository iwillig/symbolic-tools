class SymbolicTools < Formula
  desc "Prolog fact database and MCP server for reasoning over a codebase"
  homepage "https://github.com/iwillig/symbolic-tools"
  # No `revision:` pin here — this formula lives in the same repo as the
  # source it builds, so pinning a revision would mean the tagged commit
  # needs to already contain this exact file, including the SHA of the
  # commit that contains it (impossible to satisfy). `tag:` alone is
  # enough for a single-maintainer personal tap; a separate tap repo
  # (not sharing history with the source) wouldn't have this problem.
  url "https://github.com/iwillig/symbolic-tools.git", tag: "v0.1.1"
  version "0.1.1"
  license "MIT"

  depends_on "erlang"
  depends_on "rebar3" => :build

  def install
    system "rebar3", "release"
    # bin/symbolic is already inside the release tree (via rebar.config's
    # relx overlay, copied from scripts/symbolic) — installing the whole
    # tree under `prefix` already puts it at exactly `bin/symbolic`
    # (`bin` is `#{prefix}/bin`), so no separate bin.install_symlink is
    # needed. Confirmed by testing: adding one anyway pointed a symlink
    # at that exact same path, onto itself, silently destroying the real
    # file instead of doing nothing.
    prefix.install Dir["_build/default/rel/symbolic_tools/*"]
  end

  test do
    output = shell_output("#{bin}/symbolic 2>&1", 1)
    assert_match "Subcommands", output
  end
end
