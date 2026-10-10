# English text analysis with nlprule

`symbolic analyze` and the MCP `analyze_text` tool split English text into sentences and tokens. Each token includes byte and character spans, POS/lemma alternatives, whitespace-before, and chunks. The MCP response also includes bounded `query_frames` candidates to support an LLM-mediated claim-validation workflow; these are suggestions, not verified facts. Neither interface corrects text or returns grammar suggestions.

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

The CLI result contains `language: "en"` and `sentences`. The MCP result also has `query_frames`, JSON objects with `answer_type`, `relation`, `arguments`, optional `answer_slot`, source sentence, and token evidence. An empty list means the bounded frame mapper did not recognize a candidate; it does not prevent an LLM from mapping a clearly worded claim to a known fact schema. Do not infer semantics from raw tags alone. A frame is a candidate interpretation, not proof: the LLM must map the claim to the loaded fact schema and call `query` to validate it.

Each sentence has text, a span, and tokens. Each span has `byte` and `char` objects with inclusive `start` and exclusive `end` offsets. Each token's `tags` list preserves nlprule's possible lemma/POS pairs; `chunks` preserves its chunk labels.

## Integration and licensing

The Rustler NIF calls `Tokenizer::pipe`, runs on a dirty CPU scheduler, and keeps one tokenizer instance behind a mutex. The CLI emits analyzer output; the MCP handler adds the bounded query-frame candidates. No subprocess runs per request.

The nlprule crate is MIT OR Apache-2.0. Its distributed tokenizer/rule data derives from LanguageTool resources and is licensed under LGPL-2.1 according to nlprule's upstream README. This project does not redistribute those data files. See the [nlprule README](https://github.com/bminixhofer/nlprule#license), [nlprule releases](https://github.com/bminixhofer/nlprule/releases), and [LanguageTool license](https://github.com/languagetool-org/languagetool/blob/master/LICENSE.txt).
