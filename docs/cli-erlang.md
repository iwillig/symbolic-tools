# Design: The CLI (rebar3 release)

This document covers how the symbolic-tools **command-line tool** (`symbolic`) is
structured, built, and shipped. It is the Erlang counterpart to the MCP server
in [`erlang-mcp-design.md`](erlang-mcp-design.md) and the extraction layer in
[`tree-sitter-erlang.md`](tree-sitter-erlang.md): the CLI and the MCP server
share the same core modules and differ only in the front end (argv vs. MCP
messages). A design/research document only — no CLI is implemented here.

**Recommendation up front, implemented and working:** write normal compiled
modules with a thin `main/1` entry point, parse args with stdlib `argparse`
(§2), and ship via **`rebar3 release`**, run through a small custom wrapper
script (§1.2) — **not `rebar3 escriptize`**, which was the original plan
here but turned out to be fundamentally incompatible with NIFs (like
`symbolic_ts`, [`tree-sitter-erlang.md`](tree-sitter-erlang.md)) once one
entered the dependency tree. See §1.1.

## 1. Packaging

Three models exist for running Erlang as a CLI:

| Model | What it is | Use when |
|---|---|---|
| **`escript`** (built-in) | a single `.erl` file run by the `escript` runtime; shebang `#!/usr/bin/env escript` | quick throwaway scripts |
| **`rebar3 escriptize`** | bundles the OTP app **+ all deps' `.beam`/`.app` files** into one self-contained executable | fine as long as nothing in the dependency tree is a NIF (§1.1) — no longer used here once tree-sitter extraction (a NIF) was added |
| **`rebar3 release`** (or `relx`) | full OTP release: `sys.config`, start scripts, `releases/` tree, `priv/` kept as real files on disk | ✅ **what `symbolic` actually ships as**, specifically because `priv/` staying real files is what lets `symbolic_ts`'s NIF load at all |

Avoid escript **"script mode"** for real logic — it is interpreted (slow) and
disallows compile-only features.

### 1.1 Confirmed: NIFs cannot be shipped inside an escript

Found while implementing `symbolic parse`'s tree-sitter extraction, and the
reason this project moved off `escriptize`: `escript_incl_apps` only
bundles a dependency's `.beam`/`.app` files into the escript's zip archive
— never `priv/` — and `erlang:load_nif/2` cannot `dlopen` a shared library
from inside a zip archive at all. Embedding the tree-sitter NIF app in
`escript_incl_apps` produced a module that *looks* loaded
(`code:which/1` finds it) but crashes with `undefined function` the
moment any of its NIF functions are called — worse than not embedding
it, since the failure is silent until the crash. `symbolic_parse` still
guards this defensively with `code:ensure_loaded(symbolic_ts)`, but the
real fix was switching packaging entirely, not routing around it — see
§1.2.

### 1.2 The release, and why relx's own script doesn't work as the CLI

`rebar.config` (the real, verified config keys — an earlier draft of this
document used a fictional `{escriptize, [...]}` tuple):

```erlang
{relx, [
    {release, {symbolic_tools, "0.1.3"}, [sasl, erlog, erlmcp, symbolic_tools]},
    {dev_mode, true},        % symlinked app dirs, fast local builds —
    {include_erts, false},   % flip both for an actually portable/shippable release
    {extended_start_script, true},
    {overlay, [{copy, "scripts/symbolic", "bin/symbolic"}]}
]}.
```

`symbolic_ts` (the tree-sitter NIF) isn't listed separately — it lives
inside the `symbolic_tools` app itself, not as its own dependency; see
`docs/tree-sitter-erlang.md` §2. Build with plain `rebar3 release` — no
special env var needed, since `symbolic_ts` builds through the standard
rebar3 `pc` plugin rather than a hand-rolled Makefile.

**relx's own generated `bin/symbolic_tools` script is not usable as the
CLI entry point.** It's built for managing a long-running node
(`start`/`stop`/`console`/`foreground`/`rpc`/`pid`/`ping`), and its two
subcommands that look like one-shot execution — `eval` and `escript` —
both call `ping_or_exit` first and then RPC into an **already-running**
node. There is no built-in "run this and exit" mode for a node that isn't
started yet, which is exactly what a CLI needs.

The fix: a small wrapper script (`scripts/symbolic`, copied into
`bin/symbolic` in the release via the `overlay` config above) that runs
`erl` directly against the release's own `lib/*/ebin` directories:

```sh
DIR="$(cd "$(dirname "$0")/.." && pwd)"
exec erl -pa "$DIR"/lib/*/ebin \
    -noshell \
    -eval "symbolic_cli:main(init:get_plain_arguments())" \
    -extra "$@"
```

This is the same shape the old escript invocation had — `main/1` receives
argv, `argparse` (§2) dispatches — except it runs against the release's
real on-disk `ebin`/`priv` directories instead of a zip, so `symbolic_ts`'s
NIF loads correctly. `symbolic parse` now works from the built binary
(`_build/default/rel/symbolic_tools/bin/symbolic`), verified end-to-end
including composing with `query` (parse -db facts.dets → query -db
facts.dets).

## 2. Entry point, subcommands, and argument parsing

**Implemented as designed, with one correction.** An earlier version of
this document assumed a built-in stdlib `getopt` module — that doesn't
exist (`code:which(getopt)` returns `non_existing` on OTP 29). The real
answer, found and verified against a real build, is stdlib's
**[`argparse`](https://www.erlang.org/doc/apps/stdlib/argparse.html)**
(OTP 25+): a declarative command tree — commands are branches, arguments
are leaves — that owns dispatch, usage/help text, and the
error-message-then-`halt(1)` path itself. `main/1` becomes a single call:

```erlang
-module(symbolic_cli).
-export([main/1]).

main(Argv) ->
    argparse:run(Argv, cli(), #{progname => "symbolic"}).

cli() ->
    #{commands => #{"query" => query_cmd(), "parse" => parse_cmd()}}.

query_cmd() ->
    #{
        help => "Load a fact database and prove a goal against it",
        arguments => [
            #{name => db, long => "db", required => true,
              help => "Path to a fact database (.dets)"},
            #{name => rules, long => "rules", required => false,
              help => "Hand-written Prolog rule file (.pl) to consult alongside the facts"},
            #{name => no_rules, long => "no-rules", type => boolean, default => false,
              help => "Skip the automatic .symbolic/rules.pl lookup"},
            #{name => goal, help => "Goal to prove, e.g. \"foo(X)\""}
        ],
        handler => fun(Args) ->
            #{db := Db, goal := Goal} = Args,
            symbolic_query:run(Db, maps:get(rules, Args, undefined),
                maps:get(no_rules, Args, false), Goal)
        end
    }.
```

- `query` — load a DETS-backed fact database
  ([`prolog-store.md`](prolog-store.md)) and run a Prolog query through
  [`erlog`](https://github.com/rvirding/erlog)
  ([`erlang-mcp-design.md`](erlang-mcp-design.md)), consulting a
  hand-written rule file alongside the facts (for derived rules like
  [`lint-queries.md`](lint-queries.md)'s). Which file that is gets decided
  by `symbolic_query:resolve_rules/3`: an explicit `-rules` wins;
  otherwise the project's own `.symbolic/rules.pl` is found by walking up
  from the database's directory and then from the cwd — the same "find the
  project root" shape git uses for `.git`, so the command works from any
  subdirectory; `-no-rules` skips that lookup, and finding nothing is fine
  (facts alone). Note `run_result/3` — the halt-free core the tests and any
  library caller use — keeps the stricter contract: there, `undefined`
  means "consult nothing", never "go looking". **Implemented.**
- `parse` — walk a folder, run the tree-sitter extraction
  ([`tree-sitter-erlang.md`](tree-sitter-erlang.md)), print facts as JSON,
  and optionally write them into a fact database via `-db`. **Implemented.**
- `serve` starts the MCP server supervisor
  ([`erlang-mcp-design.md`](erlang-mcp-design.md)). **Implemented.**

**Sharp edge, verified by running the built escript**: `argparse`'s
default prefix is a *single* dash — `long => "file"` produces `-file`, not
`--file`. This is Erlang's own flag convention (matching `erl -pa`,
`-name`), not GNU's. A switch with no value is `type => boolean` plus a
`default` (that's how `-no-rules` works — verified against a real
`argparse:run/3`, since the key is then always present in the handler's
Args map). There is also no automatic `-help`/`--help` — running
`symbolic` with no subcommand, or any parse error, prints usage and exits
non-zero on its own, but an explicit help flag would need to be added as
its own argument if wanted.

Conventions: exit code `0` on success, non-zero on error; results to
`stdout`, diagnostics to `stderr`.

## 3. Output

- **`io:format/1,2`** for the basics. **Keep `stdout` clean** (machine-readable
  results) and send progress/errors to `stderr` (`io:put_chars(stderr, ...)`),
  so `symbolic … | other-tool` composes.
- **ANSI color:** [`erlang_color`](https://github.com/julianduque/erlang-color)
  (87★, maintained) — `erlang_color:red("error")`, `:green/1`, `:yellow/1`.
  Disable color when `NO_COLOR` is set or stdout is not a TTY.
- **Progress bars / tables:** no dominant maintained lib. Roll your own with
  ANSI — a progress bar is `\r` + a redrawn `[####----] n/N` line; tables are
  padded columns. Cheap, and it avoids another dependency.

## 4. Distribution

**Status: a Homebrew tap exists and is verified** (`Formula/symbolic-
tools.rb`, `readme.md`'s Install section) — via a real local `brew
install --build-from-source` test, not just written and assumed to
work.

Two separate settings matter here, and confirmed by testing they're
genuinely independent concerns:

- **`include_erts`** stays **off**. It would embed a full ERTS build for
  the host OS/arch, making the release self-contained but
  platform-specific (no true cross-compile either way) — not needed,
  since a Homebrew formula declares `depends_on "erlang"` and the
  release is happy calling out to that.
- **`dev_mode`** is what actually had to change, and is now **off**
  (`rebar.config`'s `relx` section) — confirmed directly: with it on,
  every app directory under the release's `lib/` (`erlog-*`,
  `symbolic_tools-*`, ...) is a **symlink back into this exact
  checkout's `_build/` tree**, not a real copy. Harmless for local
  development, but it means the release cannot survive being copied
  anywhere else — exactly what a Homebrew install does (build in a
  throwaway sandbox, then the result lives permanently in the Cellar).
  With `dev_mode` off, relx copies real files, and the release is fully
  relocatable — verified by copying a built release to an unrelated
  path and running `symbolic parse` from there successfully.

Other channels, not yet built, for reference:

- **Nix flake** — reproducible build matrix across platforms.
- **Install script** — detects OS/arch, downloads the right release tarball.
- **Docker** image — for CI and container users.

## 5. Testing

Test the **logic modules directly** (`symbolic_parse`, `symbolic_query`, the extraction
and resolution code) with EUnit — `main/1` is a thin wrapper, don't test
through it. For integration tests of the real binary, invoke the release's
`bin/symbolic` via `os:cmd/1` / `open_port` and assert on stdout, stderr,
and the exit code. `rebar3 ct` runs the same Common Test suite as the
server. See [`testing-erlang.md`](testing-erlang.md) for the rebar3
EUnit/Common Test/PropEr/coverage setup this relies on.

## 6. Recommended stack (summary)

| Concern | Pick | Source |
|---|---|---|
| Build / ship | `rebar3 release` + a custom `bin/symbolic` wrapper (§1.2) — **not** `escriptize`, incompatible with NIFs (§1.1) | rebar3 / relx |
| Arg parsing / subcommands | [`argparse`](https://www.erlang.org/doc/apps/stdlib/argparse.html) (stdlib, OTP 25+) | OTP stdlib |
| ANSI color | `erlang_color` | [github](https://github.com/julianduque/erlang-color) |
| Real CLI to read | `observer_cli` (1.5k★) | [github](https://github.com/zhongwencool/observer_cli) |
| Distribution | Homebrew tap (done) / Nix flake / install script | per §4 |

## References

- [`erlang-mcp-design.md`](erlang-mcp-design.md) — the MCP server this CLI
  shares core modules with.
- [`tree-sitter-erlang.md`](tree-sitter-erlang.md) — the extraction the `parse`
  subcommand drives.
- [`tree-sitter-erlang.md`](tree-sitter-erlang.md) §2 — `symbolic_ts`, the
  project's own tree-sitter NIF that `parse` runs on.
- [`argparse`](https://www.erlang.org/doc/apps/stdlib/argparse.html) —
  stdlib arg parser and subcommand dispatcher, verified present on OTP 29
  (`code:which(argparse)`), superseding the nonexistent-`getopt` assumption
  this document made earlier.
- [`observer_cli`](https://github.com/zhongwencool/observer_cli) — a real
  Erlang CLI, as a structural reference.
- [`testing-erlang.md`](testing-erlang.md) — the rebar3 test/coverage
  tooling §5 uses.
