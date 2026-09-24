// "Free cloud" proxy for Local Agent.
//
// The app speaks the Gemini REST API to this Worker; the Worker checks the
// request, swaps in the developer's API key (a Worker secret, never in the
// APK) and streams Google's response back. Protections, since anything in
// an APK can be extracted: per-install rate limits, an optional daily quota,
// a model allowlist, a request size limit and an output-token cap.

const GEMINI = 'https://generativelanguage.googleapis.com/v1beta';

const defaults = {
  ALLOWED_MODELS: 'gemini-flash-lite-latest,gemini-flash-latest',
  MAX_OUTPUT_TOKENS: '2048',
  MAX_BODY_BYTES: '400000',
  DAILY_LIMIT: '150',
};

function setting(env, name) {
  return (env[name] ?? defaults[name] ?? '').toString();
}

// Errors in Gemini's format, so the app shows its usual friendly messages.
function geminiError(code, status, message) {
  return new Response(JSON.stringify({ error: { code, status, message } }), {
    status: code,
    headers: { 'content-type': 'application/json', 'cache-control': 'no-store' },
  });
}

function allowedModels(env) {
  return setting(env, 'ALLOWED_MODELS').split(',').map((m) => m.trim()).filter(Boolean);
}

async function checkQuota(env, installId, ctx) {
  if (env.RATE_LIMITER) {
    const { success } = await env.RATE_LIMITER.limit({ key: installId });
    if (!success) {
      return geminiError(429, 'RESOURCE_EXHAUSTED', 'Too many messages in a short time. Wait a minute and try again.');
    }
  }
  if (env.QUOTA) {
    const day = new Date().toISOString().slice(0, 10);
    const key = `${day}:${installId}`;
    const used = parseInt((await env.QUOTA.get(key)) ?? '0', 10);
    const limit = parseInt(setting(env, 'DAILY_LIMIT'), 10);
    if (used >= limit) {
      return geminiError(429, 'RESOURCE_EXHAUSTED',
        `You've used today's ${limit} free messages. Add your own API key in Settings for unlimited use.`);
    }
    ctx.waitUntil(env.QUOTA.put(key, String(used + 1), { expirationTtl: 60 * 60 * 36 }));
  }
  return null;
}

export default {
  async fetch(request, env, ctx) {
    const url = new URL(request.url);

    const tokens = setting(env, 'APP_TOKENS').split(',').map((t) => t.trim()).filter(Boolean);
    const token = request.headers.get('x-goog-api-key') ?? '';
    if (tokens.length === 0 || !tokens.includes(token)) {
      return geminiError(401, 'UNAUTHENTICATED', 'This app build is not allowed to use the free cloud.');
    }
    if (!env.GEMINI_API_KEY) {
      return geminiError(503, 'UNAVAILABLE', 'The free cloud is not configured yet.');
    }

    // Model list: only what the proxy allows.
    if (request.method === 'GET' && url.pathname === '/v1beta/models') {
      return new Response(JSON.stringify({
        models: allowedModels(env).map((id) => ({
          name: `models/${id}`,
          displayName: id,
          supportedGenerationMethods: ['generateContent', 'streamGenerateContent'],
        })),
      }), { headers: { 'content-type': 'application/json' } });
    }

    // "Report this response": Play requires AI apps to let users flag
    // output to the developer. Reports appear in the Worker logs and, if the
    // REPORTS namespace is bound, are kept for 90 days.
    if (request.method === 'POST' && url.pathname === '/report') {
      const installId = request.headers.get('x-install-id') ?? '';
      const raw = await request.text();
      if (raw.length > 8000) return geminiError(413, 'INVALID_ARGUMENT', 'Report too large.');
      let report;
      try {
        report = JSON.parse(raw);
      } catch {
        return geminiError(400, 'INVALID_ARGUMENT', 'Invalid JSON.');
      }
      const entry = {
        at: new Date().toISOString(),
        installId,
        reason: String(report.reason ?? '').slice(0, 100),
        model: String(report.model ?? '').slice(0, 100),
        response: String(report.response ?? '').slice(0, 2000),
      };
      console.log(JSON.stringify({ type: 'report', ...entry }));
      if (env.REPORTS) {
        ctx.waitUntil(env.REPORTS.put(`report:${entry.at}:${installId}`, JSON.stringify(entry), { expirationTtl: 60 * 60 * 24 * 90 }));
      }
      return new Response(JSON.stringify({ ok: true }), { headers: { 'content-type': 'application/json' } });
    }

    const match = url.pathname.match(/^\/v1beta\/models\/([A-Za-z0-9._-]+):(streamGenerateContent|generateContent)$/);
    if (request.method !== 'POST' || !match) {
      return geminiError(404, 'NOT_FOUND', 'Not found.');
    }
    const [, model, method] = match;
    if (!allowedModels(env).includes(model)) {
      return geminiError(403, 'PERMISSION_DENIED', `The free cloud doesn't offer ${model}.`);
    }

    const installId = request.headers.get('x-install-id') ?? '';
    if (!/^[0-9a-f]{16,64}$/i.test(installId)) {
      return geminiError(400, 'INVALID_ARGUMENT', 'Missing install id. Update the app.');
    }
    const limited = await checkQuota(env, installId, ctx);
    if (limited) return limited;

    const raw = await request.text();
    if (raw.length > parseInt(setting(env, 'MAX_BODY_BYTES'), 10)) {
      return geminiError(413, 'INVALID_ARGUMENT', 'That message (or image) is too large for the free cloud.');
    }
    let body;
    try {
      body = JSON.parse(raw);
    } catch {
      return geminiError(400, 'INVALID_ARGUMENT', 'Invalid JSON.');
    }
    const cap = parseInt(setting(env, 'MAX_OUTPUT_TOKENS'), 10);
    body.generationConfig = { ...(body.generationConfig ?? {}) };
    body.generationConfig.maxOutputTokens = Math.min(body.generationConfig.maxOutputTokens ?? cap, cap);

    const upstream = await fetch(`${GEMINI}/models/${model}:${method}${url.search}`, {
      method: 'POST',
      headers: { 'content-type': 'application/json', 'x-goog-api-key': env.GEMINI_API_KEY },
      body: JSON.stringify(body),
    });
    // Stream straight through; never forward Google's headers wholesale.
    return new Response(upstream.body, {
      status: upstream.status,
      headers: {
        'content-type': upstream.headers.get('content-type') ?? 'application/json',
        'cache-control': 'no-store',
      },
    });
  },
};
