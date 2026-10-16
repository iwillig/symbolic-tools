# Executable bounded-verification benchmark

This pilot measures **model JSON → Erlang request validation → fixed Prolog goal → real facts → deterministic score**. The model never supplies executable Prolog. It does not evaluate private chain-of-thought. Supported pilot operations are `defines`, direct local `calls`, and `callers_count`.

## Components

- `fixtures/dev`, `fixtures/holdout`: independent TypeScript projects; `manifest.json` pins source/config hashes.
- `cases.dev.jsonl`, `cases.holdout.jsonl`: labeled pilot cases; the default Promptfoo config uses only dev.
- `src/symbolic_eval.erl`: Erlang owns fixture hash validation, scan/extraction, request validation, safe goal templates, Prolog execution, evidence and scoring.
- `symbolic-eval`: Erlang launcher using the compiled project/application and JSON on stdin/stdout.
- `promptfoo-provider.js`: thin Promptfoo-compatible JavaScript provider; calls the local model and forwards its raw structured response to the Erlang bridge. It contains no goal-rendering or scoring logic.
- `promptfooconfig.yaml`: Promptfoo metrics and assertions.

## Deterministic tests

From the project root:

```sh
rebar3 compile
rebar3 eunit --module=symbolic_eval_tests
```

EUnit checks request rejection, fixed goal construction, fixture hashes, both fixture case sets, and live queries against the project's Erlang Prolog engine. No Python dependency is required. `evals/executable/symbolic-eval` expects compilation first.

## Promptfoo wiring smoke test

```sh
cd evals/executable
BOUNDED_EVAL_MOCK=1 promptfoo eval -c promptfooconfig.yaml --no-cache --output /tmp/bounded-mock-smoke.json
```

Mock mode intentionally uses gold labels as model output. It validates Promptfoo → JS adapter → Erlang bridge → assertions only; **it is not a model benchmark or quality result.**

## Local-model evaluation

Set the endpoint credentials in the shell, never in config or committed files:

```sh
export UNSLOTH_BASE_URL='http://127.0.0.1:8888/v1' # use Studio's actual displayed URL
export UNSLOTH_API_KEY='...'                        # local secret
export UNSLOTH_MODEL='...'                           # exact id from authenticated /v1/models
cd evals/executable
promptfoo eval -c promptfooconfig.yaml --no-cache --output /tmp/bounded-dev.json
```

The JS provider makes one non-streaming OpenAI-compatible request per case, requesting JSON output and disabling thinking, then passes the response to Erlang. If Studio rejects `response_format` or `chat_template_kwargs`, treat that as an integration failure and adapt after confirming the endpoint contract. Missing key/network/API failures are provider errors, not successful abstentions. Review output locally before sharing.

To evaluate holdout, deliberately make a separate config pointing at `cases.holdout.jsonl`; do not tune prompts/training on those cases. This benchmark does not implement SFT, adapter export, or a production typed API.
