# Incremental syntax extraction

Every CLI or MCP parse still walks the configured paths (and applies the
current ignore rules). Overlapping paths are deduplicated before extraction.
For each discovered file, the scanner hashes its bytes with SHA-256 and
compares that hash with its previous per-file syntax-fact record. Unchanged
files reuse their facts; changed and new files are extracted; deleted and
newly ignored files are absent from the assembled snapshot. Extraction
failures do not create cache entries. Files modified during extraction are
reported as failed instead of caching facts under the wrong hash.

## Failure diagnostics

A file that cannot be read, cannot be re-read after extraction, or changes
while it is being extracted is reported in `failed_files` with
`scan_complete: false`. Its path and the reason are logged. The CLI sends error logs and incomplete-scan warnings to stderr while keeping
its JSON summary on stdout; unexpected CLI crashes also print a short error
to stderr and exit nonzero. The MCP server logs an incomplete-scan summary in
`serve.log`
under Erlang's platform user log directory for `symbolic` (the directory
returned by `filename:basedir(user_log, "symbolic")`). A partial scan still
returns a result; do not treat absent facts as proof that skipped files lack
them. A fatal MCP parse error leaves the previous in-memory cache untouched.

For a configured database, the cache lives at `<database>.files_cache`. It is
staged and installed with the DETS facts and scan metadata, and its random
snapshot ID must match the committed metadata before it can be read. A legacy
direct database write invalidates the cache. A missing, mismatched, or
unreadable sidecar causes a full syntax extraction, not a parse failure.
Without a database the MCP server keeps the records in its project entry for
subsequent parses in that process; the CLI has no cross-run cache without a
database. The cache identity incorporates the extraction modules' BEAM MD5s,
the native parser binary, and a format version. It is a trusted local Erlang
term snapshot, like the DETS database; do not load it from an untrusted
source.

TypeScript project analysis, erlog state construction, DETS snapshot writes,
and text-index construction still operate on the full assembled fact set each
parse. TypeScript semantic facts are *not* reusable per file because changes
in one file can affect other files. This optimization skips syntax extraction,
not the entire parse pipeline or the cost of reading files to hash them.
