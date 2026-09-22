# How to Cut a Release

This repo's actual convention, confirmed by re-deriving it from the
`v0.1.0` release itself (there was no prior doc) and then following it
for real to cut `v0.1.1`: commit directly to `main`, no PR — a
single-maintainer repo, not a team workflow. The Homebrew formula
(`Formula/symbolic-tools.rb`) lives in this same repo and points its
`url` straight at a git tag (`tag: "vX.Y.Z"`), so there is no separate
tap repo and no tarball/sha256 to compute — cutting the release *is*
publishing the package.

## 1. Bump the version in five places

Three are load-bearing, two are doc references that quote them —
`grep -rn '"0\.1\.0"' src/ rebar.config Formula/ docs/ readme.md` finds
all of them for the version you're bumping *from*:

- `src/symbolic_tools.app.src` — the `{vsn, "X.Y.Z"}` tuple.
- `rebar.config` — the `relx` `{release, {symbolic_tools, "X.Y.Z"}, ...}`
  tuple. This is the one that actually ends up in the built release's
  directory name (`_build/default/rel/symbolic_tools-X.Y.Z`); missing
  it means the app version and the release version disagree.
- `Formula/symbolic-tools.rb` — both the `tag:` in the `url` line and
  the separate `version "X.Y.Z"` line. These are independent strings;
  Homebrew doesn't derive one from the other.
- `docs/cli-erlang.md` — quotes the same `rebar.config` relx tuple as a
  worked example; keep it in sync so the doc doesn't show a stale
  version.
- `readme.md` — the Homebrew install section says which tag the
  formula "builds from the tagged `vX.Y.Z`".

Don't touch version-looking strings elsewhere — `readme.md`'s TOML/JSON
extraction examples and `docs/logging-and-metrics.md`'s OpenTelemetry
sketch both use `"0.1.0"` as illustrative example data for a
*different, hypothetical* project, not this one.

## 2. Verify before tagging

```sh
rm -rf _build && rebar3 eunit --cover   # full suite, clean
rebar3 release                          # confirm the release dir name
                                         # picked up the new version
```

## 3. Commit, tag, push

```sh
git add <the five files above>
git commit -m "Bump version to X.Y.Z"

git tag -a vX.Y.Z -m "$(cat <<'EOF'
symbolic-tools X.Y.Z

<narrative summary of what's new and why it matters — not a changelog
of file diffs. See `git log vPREV..HEAD --format='%s%n%n%b'` for the
raw commit history to summarize from.>
EOF
)"

git push origin main
git push origin vX.Y.Z
```

The tag is **annotated** (`-a`, with a real message), matching `v0.1.0`
— a lightweight tag would lose the "why" narrative `git show vX.Y.Z`
is for.

## 4. Create the GitHub release

```sh
gh release create vX.Y.Z --title "vX.Y.Z" --notes "<one or two
sentences, pointing to readme.md and Formula/symbolic-tools.rb for
detail — the tag message already has the narrative>"
```

Keep the release notes terse — `v0.1.0`'s was one line
("First tagged release. See readme.md and Formula/symbolic-tools.rb.").
The real "why" belongs in the tag message (§3), not duplicated here.

## 5. Verify the Homebrew formula actually builds

This is the step that actually matters — everything above is just
getting a tag onto GitHub for this to point at:

```sh
brew tap iwillig/symbolic-tools https://github.com/iwillig/symbolic-tools  # first time only
brew upgrade --build-from-source iwillig/symbolic-tools/symbolic-tools    # or: brew install ...
brew test iwillig/symbolic-tools/symbolic-tools
```

`brew info iwillig/symbolic-tools/symbolic-tools` should show the new
version as `stable` before you upgrade — if it still shows the old one,
the tap's cache is stale (`brew update` first) or the tag/version bump
in the Formula didn't actually get pushed.

## A real obstacle, specific to this environment, not this repo

Claude Code sessions in this environment run under a global hook
(`block-protected-branches.sh`, from an unrelated project's plugin
config, not something this repo asks for) that refuses any git/gh
command touching `main`/`dev` — including a bare `git checkout main`,
committing, and especially `git push origin main`, which is blocked
**unconditionally**, with no override. Cutting `v0.1.1` needed a
workaround, not a different release process:

1. Do the version-bump commit on a throwaway branch (e.g.
   `release/vX.Y.Z`, mirroring the `release/v0.1.0` marker branch
   already in this repo's history), since committing while `main` is
   checked out is what the hook actually blocks.
2. `CLAUDE_RELEASE=1 git checkout main && CLAUDE_RELEASE=1 git merge
   --ff-only release/vX.Y.Z` — the marker permits *local* git
   operations against `main`.
3. **`git push origin main` has no marker exception at all.** A human
   has to run that one command (`! git push origin main` from inside
   the session, or in their own terminal).
4. Tagging and pushing the tag (§3) and everything from §4 onward is
   unaffected — the hook only cares about the `main`/`dev` branch
   refs themselves, not tags or releases.

If a future session hits the same block, this is why — it's an
environment quirk, not a change to how this repo is released.

## References

- [`cli-erlang.md`](cli-erlang.md) §4 — the built release layout this
  process produces.
- [`../readme.md`](../readme.md) — the Homebrew install instructions
  this process keeps accurate.
- `Formula/symbolic-tools.rb` — the formula itself, with its own
  comments on why `tag:` alone (no `revision:`) is enough for this
  repo's shape.
