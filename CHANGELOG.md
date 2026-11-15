# Changelog

This file records notable user-facing changes for each release.

## [Unreleased]

### Fixed

- ASK `callers` and `callers_count` answers for a Python-defined callee no
  longer claim complete caller coverage: they now set `evidence_complete`
  to `false` and include a `caveat` explaining that most Python call sites
  are syntax-only `py_call_site/11` facts, so an empty caller list does not
  mean no callers.
- The `symbolic` CLI now supports `-h`/`--help` at the top level and after
  any subcommand: it prints that command's usage and exits 0 without running
  the command. Invalid arguments still exit non-zero.
- The `parse` launcher's RSS sampler no longer delays a caller that reads
  the script's output pipe by up to 5 seconds after the CLI exits.
- `sub_text/5` no longer falls back to the quadratic split enumerator for a
  bound non-ASCII needle: any bound needle now matches at the byte level, so
  real-paragraph-length haystacks (e.g. `paragraph/3` text) stay well inside
  the query timeout instead of hanging. A needle containing codepoints above
  255 (such as a quoted em dash through a codepoint-decoded goal) is
  normalized to its UTF-8 bytes, so the same needle matches through both
  byte-decoded and codepoint-decoded entry paths. Empty needles and
  Latin-1-range needles keep their existing byte-list semantics.

## [0.6.0] - 2026-10-27

### Added

- Preserve Python definition identities and lexical qualified names in `py_definition/9`, including methods and nested definitions with the same name.
- Record all parsed Python calls as unresolved `py_call_site/11` facts, including calls with keyword arguments and unpacking; call sites can be joined to their lexical enclosing definition without claiming callee resolution.

### Fixed

- Do not attribute calls inside nested class bodies to an outer function's `calls/5` facts. Existing `calls/5` remains conservative.

[0.6.0]: https://github.com/iwillig/symbolic-tools/compare/v0.5.0...v0.6.0

## [0.5.0] - 2026-10-27

### Added

- Scan Python `.py` files for syntax-only definitions, comments, and conservatively representable calls; ambiguous calls are omitted rather than treated as resolved.
- Expose source-written TypeScript types and opt-in project-checker facts with explicit partial/failed status.
- Discover function definitions by name, including via MCP, and report live parse/query progress.

### Changed

- Keep repeated scans and large-project queries responsive while bounding TypeScript checker work. Checker-cache candidates remain non-reusable until input freshness can be proved.
- Reject incomplete scans and stale or insufficient evidence rather than presenting them as complete answers.

### Fixed

- Restore the full-suite recursion performance guard as the call graph grows, without changing its mutual-recursion result.
- Refresh ASK benchmark source-line expectations after code moved; answer and evidence checks remain intact.

[0.5.0]: https://github.com/iwillig/symbolic-tools/compare/v0.4.0...v0.5.0

## [0.4.0] - 2026-10-12

### Added

- Add Ruby and Clojure source analysis.
- Add local English sentence and token analysis, with candidate query frames in CLI and MCP workflows.
- Make external Markdown documentation for Erlang APIs searchable and available to code checks.

### Changed

- **Breaking:** CLI and MCP `parse` now take no arguments and scan only paths listed in `.symbolic/config.json`. Configure each project before parsing; run one MCP server per project.
- Share the configured DETS database between CLI and MCP. MCP refreshes its in-memory view on the next successful parse after a CLI update.
- Keep claim validation grounded in project facts and distinguish unverifiable claims from false claims.

### Fixed

- Reject invalid tool routes and proof goals instead of treating them as valid claim-check results.
- Recognize inline Erlang documentation so documented APIs are not reported as undocumented.

[0.4.0]: https://github.com/iwillig/symbolic-tools/compare/v0.3.0...v0.4.0
