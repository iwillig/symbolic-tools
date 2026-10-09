// Build script: compiles the SAME vendored tree-sitter core and grammar
// sources the previous C NIF built via rebar3's `pc` plugin (see the old
// {port_specs, ...} entries in rebar.config, removed when this crate
// replaced c_src/symbolic_ts_nif.c). Compiling the exact vendored
// parser.c/scanner.c files — not crates.io grammar crates — is deliberate:
// (a) the vendored grammars are a mix of ABI 14 (erlang, json) and ABI 15
//     (bash, jsdoc, markdown, toml, typescript) against a core at
//     TREE_SITTER_LANGUAGE_VERSION 15, and published grammar crates are
//     version-advanced beyond these revisions;
// (b) the extracted fact shapes depend on the grammar's node types, so any
//     grammar revision drift silently changes the fact base. The parity
//     gate (scripts/parity_check.sh) depends on zero drift here.
use std::path::PathBuf;

const GRAMMARS: [&str; 8] = [
    "erlang",
    "typescript",
    "markdown",
    "toml",
    "json",
    "bash",
    "jsdoc",
    "rust",
];

fn main() {
    let manifest = PathBuf::from(std::env::var("CARGO_MANIFEST_DIR").unwrap());
    let repo = manifest
        .join("../..")
        .canonicalize()
        .expect("crate must live under <repo>/native/symbolic_ts");

    let core = repo.join("c_src/tree-sitter");
    let mut build = cc::Build::new();
    build.include(core.join("include"));
    build.file(core.join("src/lib.c"));

    for g in GRAMMARS {
        let dir = repo.join("c_src/grammars").join(g);
        build.include(&dir);
        build.file(dir.join("parser.c"));
        // json has no scanner; every other vendored grammar does. The old
        // rebar3 port_specs listed scanner.c explicitly per grammar —
        // the .exists() check reproduces exactly that list.
        let scanner = dir.join("scanner.c");
        if scanner.exists() {
            build.file(scanner);
        }
    }

    // The same feature-test flags the previous `pc` build needed on Linux
    // (see rebar.config's old {port_env} comment): tree-sitter's unicode.h
    // defers to glibc's <endian.h>, which only declares le16toh etc. under
    // these macros — without them the .so fails to dlopen at runtime with
    // "undefined symbol: le16toh".
    build.flag("-std=c11");
    build.flag("-D_POSIX_C_SOURCE=200112L");
    build.flag("-D_DEFAULT_SOURCE");
    // The grammar parser.c files are machine-generated; they are not warning
    // clean and never will be.
    build.warnings(false);
    build.compile("tree_sitter_core");

    println!("cargo:rerun-if-changed={}", repo.join("c_src").display());
}
