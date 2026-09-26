Title: symbolic-tools
Slug: home
Save_as: index.html
URL:

## Introduction

symbolic-tools builds a Prolog database from your codebase. An LLM agent,
or a person, can query it and get an answer proven by resolution.

It parses a source tree with tree-sitter. It extracts facts: function
definitions, call sites, comments, decision points. It loads those facts
into an in-process Prolog engine ([erlog](https://github.com/rvirding/erlog),
running on the BEAM). You can then ask it a real question and get an
answer proven by resolution, not guessed from a snippet.

The five examples below are live queries against this project's own
source, not made up. The last two are things an ESLint-style, per-file
AST rule has no way to express at all, not just a rule nobody wrote
yet.

## Why Prolog

Research on pairing language models with a symbolic reasoner has found
large accuracy gains on problems that need multi-step logical
correctness. symbolic-tools applies this to codebases. Build the fact
base once. Let a query prove the answer against it.

## How it works

<div class="grid">
  <div>
    <p>A rules library sits on top of the raw facts. It finds dead code,
    duplicate names, mutual recursion, undocumented functions, and
    oversized or overly complex definitions. Each rule is a few more
    Prolog clauses over the same facts.</p>
  </div>
  <div>
    <img src="theme/img/architecture.svg" alt="Architecture: source files are parsed by a tree-sitter extractor into facts, loaded into a Prolog session (erlog), queried by an MCP server or the symbolic CLI">
  </div>
</div>

## What calls this function

```prolog
?- calls(Caller, CallerArity, local(git_sha, 0), File, Line).
Caller = info, CallerArity = 0,
File = 'src/symbolic_version.erl', Line = 18.
```

## Which functions have no doc comment

```prolog
?- undocumented(walk_pair, Arity, File, Line).
Arity = 4, File = 'src/ts_extract_json.erl', Line = 69 ;
Arity = 4, File = 'src/ts_extract_toml.erl', Line = 85.
```

`walk_pair` is defined once in the JSON extractor and once in the TOML
extractor. Both come back, because the query doesn't care which file
it's in.

## Is this pair mutually recursive and undocumented

`undocumented/4` is a rule, not a raw fact — two lines of Prolog over
`defines/5` and `doc/5`:

```prolog
undocumented(Fun, Arity, File, Line) :-
    defines(Fun, Arity, _Params, File, Line),
    \+ doc(Fun, Arity, _, _, _).
```

Combined with a mutual-recursion check, one goal proves both halves of
the claim at once:

```prolog
?- mutual_recursion(walk_object, walk_pair),
   undocumented(walk_object, Arity, File, Line).
Arity = 4, File = 'src/ts_extract_json.erl', Line = 64.
```

`walk_object` and `walk_pair` call each other, and `walk_object` has no
doc comment. The engine performs the join. Nothing here was pieced
together from two separate lookups.

## Does this function eventually touch the filesystem or a shell

An ESLint visitor only ever sees the one function it's standing inside.
It has no notion of "reachable" — a risky call three functions away,
behind a name that gives no hint of it, is invisible to a per-node rule
by construction. Answering "does this function's call chain eventually
reach `os:cmd`, `file:*`, or similar" needs a real call graph and a walk
over arbitrary-depth chains, which is two lines here:

```prolog
hidden_risky_call(Fun, Module, Target) :-
    reaches(Fun, RiskyCaller),
    risky_call(RiskyCaller, Module, Target),
    \+ risky_call(Fun, Module, Target).
```

```prolog
?- hidden_risky_call(scan, Module, Target).
Module = file, Target = list_dir.
```

`scan/1` never calls `file:list_dir` itself. It calls `walk/3`, which
calls further functions that eventually do. A reviewer auditing `scan/1`
by reading its body alone would never see it.

## Which function does the whole project rely on most

This needs an aggregate over every call site in every file at once, not
a rule applied one file at a time — the kind of question a separate
whole-program tool (madge, dependency-cruiser) exists to bolt on
because a linter's rule model can't ask it:

```prolog
?- top_fan_in(3, Top).
Top = [45-line/1, 34-to_atom/1, 19-caller_info/2].
```

`line/1` — a small line-number helper — is called from 45 distinct
places across the codebase. Ranking every function in the project by
how many places call it is one goal, not a separate static-analysis
pass.

## Status

Early implementation. Under active development. See the
[GitHub repository](https://github.com/iwillig/symbolic-tools) for the
full README, the Prolog fact schema, and the rules library.
