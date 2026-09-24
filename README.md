# Local Agent

An AI assistant for Android that **does things on your phone**: timers,
alarms, calls, WhatsApp messages, music, weather, web search, photos. It can run
**entirely on your phone** with an open model, or use a cloud model when your
phone is too slow.

- **On-device:** any GGUF model from Hugging Face through llama.cpp, with a
  curated pick for your phone (Qwen3.5 0.8B, MiniCPM5 2B, Gemma 4 E2B/E4B),
  image understanding, and a Models hub that shows what fits your phone's
  memory and how fast it will be.
- **Cloud:** bring your own key for Google Gemini, Anthropic Claude, OpenAI,
  Groq, OpenRouter or your own Ollama / LM Studio server, or use the
  developer-hosted Free cloud (no key).
- **Instant commands:** "flashlight on", "timer 10 minutes", "text mom on
  WhatsApp that I'm running late", "play lofi on YouTube", "remember that my
  sister's name is Priya" run in milliseconds without any model, so the app is
  useful on low-end phones too.
- Voice mode, per-model settings (temperature, top-k, top-p, context,
  threads, GPU), memory, 11 colour themes, confirmation before calls, messages,
  calendar changes and uninstalls.

## How it works

```
message ──► instant command router ──► tool runs, reply in ms
                │ (not a command)
                ▼
         on-device agent (llama.cpp)  or  cloud agent (Gemini / Claude / OpenAI-compatible)
                │                               │
                └──────── tool calls ───────────┘
                           ▼
        ToolRuntime: validation, confirmation, 29 phone and web tools
```

| Path | What's there |
| --- | --- |
| `lib/services/agent/` | `AgentService` (the one object screens use), on-device and cloud agent loops, instant commands, prompts |
| `lib/services/local/` | llama.cpp engine, curated models, Hugging Face hub client, device profile and speed estimates, per-model settings |
| `lib/services/llm/` | Streaming clients for Gemini, Claude and OpenAI-compatible APIs |
| `lib/services/tools/` | Tool catalog, argument handling, execution |
| `lib/screens/` | Chat, voice mode, Models hub, model settings, memory, settings, onboarding |
| `proxy/` | Cloudflare Worker behind Free cloud |
| `MODELS.md` | Model evaluation and history |

## Build

Requires Flutter 3.38+.

```bash
flutter pub get
flutter run                  # debug on a connected phone
flutter test                 # unit tests
```

llama.cpp's native libraries are downloaded by llamadart's build hook on the
first build (no NDK or C++ toolchain needed). `pubspec.yaml` limits them to what
phones use: three CPU variants and OpenCL for Adreno GPUs.

End-to-end test with a real model (downloads nothing; point it at a GGUF):

```bash
flutter test test/local_agent_e2e_test.dart \
  --dart-define=LOCAL_MODEL_DIR=/path/to/models \
  --dart-define=LOCAL_MODEL_FILE=gemma-4-E2B_q4_0-it.gguf
```

Optional build settings:

| Define | Effect |
| --- | --- |
| `HOSTED_API_URL` | URL of your Free cloud proxy (see `proxy/README.md`); adds "Free cloud" |
| `HOSTED_APP_TOKEN` | Must match the proxy's `APP_TOKENS` |
| `SUPPORT_EMAIL` | Where "Report this response" goes if there is no proxy |

For a Play Store release see [PLAY_STORE.md](PLAY_STORE.md).

## Privacy

On-device chats never leave the phone. See [PRIVACY.md](PRIVACY.md) for what
each feature sends where.
