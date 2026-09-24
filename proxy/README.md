# Free cloud proxy

Lets people use Local Agent's cloud mode **without their own API key**, paid
for by you. It is a small [Cloudflare Worker](https://developers.cloudflare.com/workers/)
that holds your Gemini API key and passes the app's requests to Google.

Why a proxy: a key built into the APK can be pulled out of it in minutes and
used by anyone. Here the key stays on Cloudflare, and the Worker adds
per-install rate limits, an optional daily quota, a model allowlist and an
output-token cap.

## Deploy (about 10 minutes)

1. Get a Gemini API key at <https://aistudio.google.com/apikey>. The free
   tier works to start. Switch the Google Cloud project to paid billing when
   you have real users; on the free tier Google may use prompts to improve
   its products (the app's privacy policy says so).
2. Install Node.js 20+, then in this folder:

   ```bash
   npx wrangler login
   npx wrangler secret put GEMINI_API_KEY   # paste the key
   npx wrangler secret put APP_TOKENS       # e.g. local-agent-app
   npx wrangler deploy
   ```

   Wrangler prints the URL, e.g. `https://local-agent-proxy.<you>.workers.dev`.
3. (Optional, recommended) daily quota per install:

   ```bash
   npx wrangler kv namespace create QUOTA
   ```

   Paste the id into the commented `[[kv_namespaces]]` block in
   `wrangler.toml` and deploy again.
4. Build the app with the proxy URL (and the same token):

   ```bash
   flutter build appbundle \
     --dart-define=HOSTED_API_URL=https://local-agent-proxy.<you>.workers.dev \
     --dart-define=HOSTED_APP_TOKEN=local-agent-app
   ```

   "Free cloud" then appears first in the cloud provider list. Builds without
   `HOSTED_API_URL` don't show it.

## Settings (`wrangler.toml`)

| Variable | Default | Meaning |
| --- | --- | --- |
| `ALLOWED_MODELS` | `gemini-flash-lite-latest,gemini-flash-latest` | Models the app may request |
| `MAX_OUTPUT_TOKENS` | `2048` | Cap on each reply |
| `MAX_BODY_BYTES` | `400000` | Largest request (images included) |
| `DAILY_LIMIT` | `150` | Messages per install per day (needs `QUOTA`) |
| `[[ratelimits]]` | 12 per minute | Burst limit per install |

To use a different paid provider later, only this Worker changes; installed
apps keep working.

## Test

```bash
npm test
```
