class SymbolicTools < Formula
  desc "Prolog fact database and MCP server for reasoning over a codebase"
  homepage "https://github.com/iwillig/symbolic-tools"
  # No `revision:` pin here — this formula lives in the same repo as the
  # source it builds, so pinning a revision would mean the tagged commit
  # needs to already contain this exact file, including the SHA of the
  # commit that contains it (impossible to satisfy). `tag:` alone is
  # enough for a single-maintainer personal tap; a separate tap repo
  # (not sharing history with the source) wouldn't have this problem.
  url "https://github.com/iwillig/symbolic-tools.git", tag: "v0.3.0"
  version "0.3.0"
  license "MIT"

  depends_on "erlang"
  depends_on "rebar3" => :build
  # erllama (the symbolic_extract_llm model runtime) vendors llama.cpp,
  # whose first compile runs cmake — Homebrew's build sandbox does not put
  # an undeclared cmake on PATH, and the build dies in erllama's
  # do_cmake.sh with `cmake: command not found` (verified live while
  # cutting v0.1.4; the repo's own Brewfile already listed cmake for the
  # same reason). See docs/reviewing-llm-output.md §4.2 Phase 0.
  depends_on "cmake" => :build
  # The symbolic_ts tree-sitter NIF is a Rustler crate (native/symbolic_ts):
  # rebar3's compile pre-hook (scripts/build_nif.sh) invokes cargo, so the
  # Homebrew build sandbox needs a Rust toolchain on PATH — same pattern
  # as the cmake declaration above for erllama's vendored llama.cpp.
  depends_on "rust" => :build

  def install
    # The symbolic_nlp statistical-tier NIF (rust-bert) needs a ~500MB
    # libtorch download at build time and its runtime rpath points into
    # the build sandbox, which Homebrew deletes after install — the NIF
    # could never load here. It degrades gracefully when absent (ask
    # falls back to the deterministic grammar), so packaged builds skip
    # it via build_nif.sh's escape hatch. Must be set INSIDE install:
    # a class-level ENV does not survive Homebrew's superenv scrub.
    ENV["SYMBOLIC_SKIP_NLP"] = "1"
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
