# English text analysis with nlprule

`symbolic analyze` and the MCP `analyze_text` tool split English text into sentences and tokens. Each token includes byte and character spans, POS/lemma alternatives, whitespace-before, and chunks. The tool analyzes structure only; it does not correct text or return grammar suggestions.

## Data setup

The Rust code uses nlprule 0.6.4. Its English tokenizer data is a separate upstream release artifact. The application does not bundle it or download it during normal startup. Install it with the checksum-verifying Just task:

```sh
just install-nlprule-data
symbolic analyze "The quick fox jumps."
```

The NIF checks `SYMBOLIC_NLPRULE_DATA` first, then defaults to `$XDG_DATA_HOME/symbolic/nlprule` or `~/.local/share/symbolic/nlprule`. Set the environment variable only when using a non-default location. For MCP, install the file before the server's first analysis call. The tokenizer is loaded once and reused.

Only `en_tokenizer.bin` is needed for this analysis feature. The separate `en_rules.bin` supports grammar correction and suggestions, which this tool does not expose.

## Use

```sh
symbolic analyze "The quick fox jumps. It runs."
```

MCP call:

```json
{"text":"The quick fox jumps. It runs."}
```

The result contains `language: "en"` and `sentences`. Each sentence has text, a span, and tokens. Each span has `byte` and `char` objects with inclusive `start` and exclusive `end` offsets. Each token's `tags` list preserves nlprule's possible lemma/POS pairs; `chunks` preserves its chunk labels.

## Integration and licensing

The Rustler NIF calls `Tokenizer::pipe`, runs on a dirty CPU scheduler, and keeps one tokenizer instance behind a mutex. Erlang formats the same JSON result for the CLI and MCP. No subprocess runs per request.

The nlprule crate is MIT OR Apache-2.0. Its distributed tokenizer/rule data derives from LanguageTool resources and is licensed under LGPL-2.1 according to nlprule's upstream README. This project does not redistribute those data files. See the [nlprule README](https://github.com/bminixhofer/nlprule#license), [nlprule releases](https://github.com/bminixhofer/nlprule/releases), and [LanguageTool license](https://github.com/languagetool-org/languagetool/blob/master/LICENSE.txt).
