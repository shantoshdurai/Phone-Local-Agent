// Run from proxy/: npm test
import { test } from 'node:test';
import assert from 'node:assert/strict';
import worker from '../src/index.js';

const INSTALL = '0123456789abcdef0123456789abcdef';

function env(extra = {}) {
  return { APP_TOKENS: 'local-agent-app', GEMINI_API_KEY: 'server-key', ...extra };
}

function ctx() {
  const pending = [];
  return { waitUntil: (p) => pending.push(p), pending };
}

function req(path, { method = 'POST', token = 'local-agent-app', install = INSTALL, body = { contents: [] } } = {}) {
  return new Request(`https://proxy.example${path}`, {
    method,
    headers: {
      'content-type': 'application/json',
      ...(token ? { 'x-goog-api-key': token } : {}),
      ...(install ? { 'x-install-id': install } : {}),
    },
    body: method === 'GET' ? undefined : JSON.stringify(body),
  });
}

test('forwards to Gemini with the server key and caps output', async () => {
  let seen;
  globalThis.fetch = async (url, init) => {
    seen = { url, init };
    return new Response('data: {"candidates":[]}\n\n', { headers: { 'content-type': 'text/event-stream' } });
  };
  const res = await worker.fetch(
    req('/v1beta/models/gemini-flash-lite-latest:streamGenerateContent?alt=sse', {
      body: { contents: [], generationConfig: { maxOutputTokens: 99999 } },
    }),
    env(),
    ctx(),
  );
  assert.equal(res.status, 200);
  assert.equal(seen.url, 'https://generativelanguage.googleapis.com/v1beta/models/gemini-flash-lite-latest:streamGenerateContent?alt=sse');
  assert.equal(seen.init.headers['x-goog-api-key'], 'server-key');
  assert.equal(JSON.parse(seen.init.body).generationConfig.maxOutputTokens, 2048);
  assert.equal(res.headers.get('content-type'), 'text/event-stream');
});

test('rejects unknown app tokens, models and missing install ids', async () => {
  globalThis.fetch = async () => { throw new Error('should not be called'); };
  assert.equal((await worker.fetch(req('/v1beta/models/gemini-flash-latest:generateContent', { token: 'nope' }), env(), ctx())).status, 401);
  assert.equal((await worker.fetch(req('/v1beta/models/gemini-3.5-pro:generateContent'), env(), ctx())).status, 403);
  assert.equal((await worker.fetch(req('/v1beta/models/gemini-flash-latest:generateContent', { install: '' }), env(), ctx())).status, 400);
  const err = await (await worker.fetch(req('/v1beta/models/x:generateContent', { token: 'nope' }), env(), ctx())).json();
  assert.equal(err.error.status, 'UNAUTHENTICATED', 'errors use the Gemini shape the app understands');
});

test('lists only allowed models', async () => {
  const res = await worker.fetch(req('/v1beta/models', { method: 'GET' }), env({ ALLOWED_MODELS: 'gemini-flash-latest' }), ctx());
  const body = await res.json();
  assert.deepEqual(body.models.map((m) => m.name), ['models/gemini-flash-latest']);
});

test('rate limit and daily quota', async () => {
  globalThis.fetch = async () => new Response('{}');
  const limited = await worker.fetch(
    req('/v1beta/models/gemini-flash-latest:generateContent'),
    env({ RATE_LIMITER: { limit: async () => ({ success: false }) } }),
    ctx(),
  );
  assert.equal(limited.status, 429);

  const store = new Map();
  const kv = { get: async (k) => store.get(k) ?? null, put: async (k, v) => { store.set(k, v); } };
  const e = env({ QUOTA: kv, DAILY_LIMIT: '2' });
  for (let i = 0; i < 2; i++) {
    const c = ctx();
    assert.equal((await worker.fetch(req('/v1beta/models/gemini-flash-latest:generateContent'), e, c)).status, 200);
    await Promise.all(c.pending);
  }
  const over = await worker.fetch(req('/v1beta/models/gemini-flash-latest:generateContent'), e, ctx());
  assert.equal(over.status, 429);
  assert.match((await over.json()).error.message, /own API key/);
});

test('oversized bodies are refused', async () => {
  const res = await worker.fetch(
    req('/v1beta/models/gemini-flash-latest:generateContent', { body: { contents: [{ parts: [{ text: 'x'.repeat(500) }] }] } }),
    env({ MAX_BODY_BYTES: '100' }),
    ctx(),
  );
  assert.equal(res.status, 413);
});
