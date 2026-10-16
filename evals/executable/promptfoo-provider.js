'use strict';
const path = require('node:path');
const { spawnSync } = require('node:child_process');

const SYSTEM = `Classify a question about this code snapshot. Supported operations: defines, calls (direct local calls only), callers_count. Emit exactly one JSON object, no prose. Supported example: {"decision":"supported","operation":"calls","slots":{"caller":"foo/1","callee":"bar/1"}}. Unsupported: {"decision":"unsupported","reason":"unsupported_relation"}. Ambiguous: {"decision":"needs_clarification","reason":"ambiguous_entity"}. Never emit Prolog, an answer, or evidence. Function names include exact arity as name/N.`;
const FIXTURES = path.join(__dirname, 'fixtures');
const BRIDGE = path.join(__dirname, 'symbolic-eval');

function runErlang(input) {
  const result = spawnSync(BRIDGE, [], {
    input: JSON.stringify(input), encoding: 'utf8', timeout: 120000,
    maxBuffer: 8 * 1024 * 1024,
  });
  if (result.error) throw result.error;
  if (result.status !== 0) {
    throw new Error(`Erlang evaluator exited ${result.status}: ${(result.stderr || '').trim()}`);
  }
  try {
    return JSON.parse(result.stdout.trim());
  } catch (error) {
    throw new Error(`Erlang evaluator returned invalid JSON: ${String(error)}; stderr=${(result.stderr || '').trim()}`);
  }
}

module.exports = class BoundedVerificationProvider {
  constructor(options = {}) {
    this.providerId = options.id || 'bounded-verification';
    this.config = options.config || {};
  }

  id() { return this.providerId; }

  async callApi(prompt, context = {}) {
    const vars = context.vars || {};
    const fixtureName = vars.fixture || 'dev';
    if (!['dev', 'holdout'].includes(fixtureName)) {
      return { error: `Unknown benchmark fixture: ${fixtureName}` };
    }
    const fixturePath = path.join(FIXTURES, fixtureName);
    const expected = typeof vars.expected === 'string' ? JSON.parse(vars.expected) : (vars.expected || {});
    let rawRequest;
    let usage = {};

    try {
      if (process.env.BOUNDED_EVAL_MOCK === '1') {
        // Harness-only smoke mode. This intentionally uses gold labels and is
        // never evidence of model performance.
        rawRequest = expected.decision === 'supported'
          ? JSON.stringify({ decision: 'supported', operation: expected.operation, slots: expected.slots })
          : JSON.stringify({ decision: expected.decision, reason: expected.reason || 'mock_abstention' });
      } else {
        const apiKey = process.env.UNSLOTH_API_KEY;
        const model = process.env.UNSLOTH_MODEL;
        if (!apiKey) return { error: 'UNSLOTH_API_KEY is required' };
        if (!model) return { error: 'UNSLOTH_MODEL must match an id returned by /v1/models' };
        const baseUrl = (process.env.UNSLOTH_BASE_URL || this.config.base_url || 'http://127.0.0.1:8888/v1').replace(/\/$/, '');
        const response = await fetch(`${baseUrl}/chat/completions`, {
          method: 'POST',
          headers: { Authorization: `Bearer ${apiKey}`, 'Content-Type': 'application/json' },
          body: JSON.stringify({
            model,
            messages: [{ role: 'system', content: SYSTEM }, { role: 'user', content: vars.question || prompt }],
            temperature: 0,
            max_tokens: 256,
            stream: false,
            response_format: { type: 'json_object' },
            chat_template_kwargs: { enable_thinking: false },
          }),
          signal: AbortSignal.timeout(120000),
        });
        if (!response.ok) return { error: `Local model API returned HTTP ${response.status}: ${(await response.text()).slice(0, 1000)}` };
        const payload = await response.json();
        rawRequest = payload.choices?.[0]?.message?.content;
        usage = payload.usage || {};
        if (typeof rawRequest !== 'string') return { error: 'Model response had no text content' };
      }

      const evaluated = runErlang({
        fixture_path: fixturePath,
        raw_request: rawRequest,
        expected,
      });
      return {
        output: JSON.stringify(evaluated),
        tokenUsage: {
          prompt: usage.prompt_tokens || 0,
          completion: usage.completion_tokens || 0,
          total: usage.total_tokens || 0,
        },
      };
    } catch (error) {
      return { error: `Benchmark infrastructure error: ${error.name || 'Error'}: ${error.message || error}` };
    }
  }
};
