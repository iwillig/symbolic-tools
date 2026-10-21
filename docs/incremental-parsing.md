# Incremental syntax extraction

Every CLI or MCP parse still walks the configured paths (and applies the
current ignore rules). Overlapping paths are deduplicated before extraction.
For each discovered file, the scanner hashes its bytes with SHA-256 and
compares that hash with its previous per-file syntax-fact record. Unchanged
files reuse their facts; changed and new files are extracted; deleted and
newly ignored files are absent from the assembled snapshot. Extraction
failures do not create cache entries. Files modified during extraction are
reported as failed instead of caching facts under the wrong hash.

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
