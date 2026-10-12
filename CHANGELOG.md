# Changelog

This file records notable user-facing changes for each release.

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
