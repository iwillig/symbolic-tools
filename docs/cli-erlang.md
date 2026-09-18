# Design: The CLI (escript / escriptize)

This document covers how the symbolic-tools **command-line tool** (`symbolic`) is
structured, built, and shipped. It is the Erlang counterpart to the MCP server
in [`erlang-mcp-design.md`](erlang-mcp-design.md) and the extraction layer in
[`tree-sitter-erlang.md`](tree-sitter-erlang.md): the CLI and the MCP server
share the same core modules and differ only in the front end (argv vs. MCP
messages). A design/research document only — no CLI is implemented here.

**Recommendation up front:** write normal compiled modules with a thin `main/1`
entry point, parse args with the built-in `getopt`, and ship a single
self-contained binary via **`rebar3 escriptize`** (distributed through a
Homebrew tap or a Nix flake).

## 1. Packaging

Three models exist for running Erlang as a CLI:

| Model | What it is | Use when |
|---|---|---|
| **`escript`** (built-in) | a single `.erl` file run by the `escript` runtime; shebang `#!/usr/bin/env escript` | quick throwaway scripts |
| **`rebar3 escriptize`** | bundles the OTP app **+ all Hex deps + a BEAM** into one self-contained executable | ✅ **the standard "ship one binary" path for `symbolic`** |
| **`rebar3 release`** (or `relx`) | full OTP release: `sys.config`, start scripts, `releases/` tree | long-running nodes, multiple apps, config/upgrade story |

Avoid escript **"script mode"** for real logic — it is interpreted (slow) and
disallows compile-only features. The idiomatic shape is: **normal modules + a
thin `main/1`**, then let `escriptize` embed the compiled release.

`rebar.config`:

```erlang
{escriptize, [
  {main_app, symbolic_tools},        % required: the app to run
  {main_module, symbolic_cli},      % module exporting main/1
  {name, "symbolic"},               % output file name
  {embed_release, true},            % default: self-contained (VM included)
  {env, [{kernel, [
              {stdout, ...}, ...     % optional VM args
   ]}]}
]}.
```

Build with `rebar3 escriptize`; the result is a single executable `symbolic` file.

## 2. Entry point and subcommands

`main/1` is a thin dispatcher. There is no subcommand framework in Erlang —
branch on the first arg and hand off to a per-subcommand module. Each
subcommand is independently testable and keeps `main/1` trivial.

```erlang
-module(symbolic_cli).
-export([main/1]).

-spec main([arg()]) -> no_return() when arg() :: atom() | binary() | string().
main(Argv) ->
  {Opts, Rest} = parse_opts(Argv),
  case Rest of
    []       -> usage(), halt(2);
    [Sub|Tail] -> dispatch(Sub, Opts, Tail)
  end.

dispatch(parse, Opts, Tail)  -> symbolic_parse:run(Opts, Tail),
dispatch(query, Opts, Tail)  -> symbolic_query:run(Opts, Tail),
dispatch(_Unknown, _, _)     -> usage(), halt(2).
```

- `parse` — walk a folder, run the tree-sitter extraction
  ([`tree-sitter-erlang.md`](tree-sitter-erlang.md)), emit Prolog facts.
- `query` — load a facts file and run a Prolog query through
  [`erlog`](https://github.com/rvirding/erlog)
  ([`erlang-mcp-design.md`](erlang-mcp-design.md)).
- A future `serve` subcommand would start the MCP server supervisor instead.

Conventions: exit code `0` on success, non-zero on error; results to
`stdout`, diagnostics to `stderr`.

## 3. Argument parsing

Start with the **built-in `getopt`** (ships in the OTP `kernel` app — zero
dependency):

```erlang
parse_opts(Argv) ->
  % {Name}        -> boolean flag
  % {Name, Char}  -> option that requires a value (Char = short form)
  % {Name, V, Char}-> option with an optional value (V = default)
  Specs = [{quiet, $q}, {output, $o}, {format, $f}],
  getopt:parse(Argv, Specs).   % -> {[Opt | {Opt, Value}], Remaining}
```

If you need GNU-style long options and richer spec handling, use
**[`jcomellas/getopt`](https://github.com/jcomellas/getopt)** (256★, BSD-3).
Note the name collision: stdlib `getopt` (built-in) vs. that package — pick one.
Other community parsers are thin or unmaintained; not recommended.

## 4. Output

- **`io:format/1,2`** for the basics. **Keep `stdout` clean** (machine-readable
  results) and send progress/errors to `stderr` (`io:put_chars(stderr, ...)`),
  so `symbolic … | other-tool` composes.
- **ANSI color:** [`erlang_color`](https://github.com/julianduque/erlang-color)
  (87★, maintained) — `erlang_color:red("error")`, `:green/1`, `:yellow/1`.
  Disable color when `NO_COLOR` is set or stdout is not a TTY.
- **Progress bars / tables:** no dominant maintained lib. Roll your own with
  ANSI — a progress bar is `\r` + a redrawn `[####----] n/N` line; tables are
  padded columns. Cheap, and it avoids another dependency.

## 5. Distribution

The one real gotcha: `escriptize` **embeds a BEAM built for the host
OS/arch**, so the output binary is **platform-specific**. There is no true
cross-compile of the VM via `escriptize`. Practical channels:

- **Homebrew tap** — `brew install <tap>/symbolic` (or a manual copy to your
  `PATH`) is the natural model. Build one bottle per target (macOS arm64,
  macOS x86_64, Linux).
- **Nix flake** — reproducible build matrix across platforms.
- **Install script** — detects OS/arch, downloads the right escript.
- **Docker** image — for CI and container users.

## 6. Testing

Test the **logic modules directly** (`symbolic_parse`, `symbolic_query`, the extraction
and resolution code) — `main/1` is a thin wrapper, don't test through it. For
integration tests of the real binary, invoke the `escriptize` output via
`os:cmd/1` / `open_port` and assert on stdout, stderr, and the exit code.
`rebar3 ct` runs the same Common Test suite as the server.

## 7. Recommended stack (summary)

| Concern | Pick | Source |
|---|---|---|
| Build / ship | `rebar3 escriptize` → one binary | rebar3 |
| Arg parsing | `getopt` (stdlib) → `jcomellas/getopt` | OTP kernel · [github](https://github.com/jcomellas/getopt) |
| ANSI color | `erlang_color` | [github](https://github.com/julianduque/erlang-color) |
| Subcommands | first-arg dispatch in `main/1` | (idiomatic) |
| Real CLI to read | `observer_cli` (1.5k★) | [github](https://github.com/zhongwencool/observer_cli) |
| Distribution | Homebrew tap / Nix flake / install script | per §5 |

## References

- [`erlang-mcp-design.md`](erlang-mcp-design.md) — the MCP server this CLI
  shares core modules with.
- [`tree-sitter-erlang.md`](tree-sitter-erlang.md) — the extraction the `parse`
  subcommand drives.
- [`cfclavijo/erl_ts`](https://github.com/cfclavijo/erl_ts) — tree-sitter NIF
  dependency for `parse`.
- [`getopt`](https://www.erlang.org/doc/man/getopt.html) — stdlib arg parser.
- [`observer_cli`](https://github.com/zhongwencool/observer_cli) — a real
  Erlang CLI, as a structural reference.
