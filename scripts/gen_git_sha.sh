#!/bin/sh
# Writes priv/git_sha with the current commit's full SHA, so a running
# `symbolic` MCP server/CLI can report which build it's actually
# running (see the `git_sha` field on `parse`/`overview`) — the thing
# that tells you whether a rebuilt release has actually been picked up
# yet, since the server is a long-running BEAM node that doesn't reload
# code on its own.
#
# Run as a rebar3 pre_hook on `compile` (see rebar.config), so it's
# regenerated before every compile/eunit/release. "unknown" when built
# outside a git checkout (e.g. from a source tarball with no .git) —
# never a hard failure, since a stale-but-present value beats breaking
# the build.
set -e
mkdir -p priv
git rev-parse HEAD > priv/git_sha 2>/dev/null || echo unknown > priv/git_sha
