# Local Agent

A phone assistant that can actually act: call, message, open apps, set alarms,
search, read your calendar, take notes — and it runs either on a fast cloud
model with your own key, or entirely on-device if you prefer privacy.

Built with Flutter. The on-device path uses LiteRT-LM via `flutter_gemma`; the
cloud path speaks the OpenAI chat-completions protocol, so it works with Groq,
DeepSeek, OpenRouter, Ollama or any compatible endpoint (Gemini is supported
natively too).

## What it does

- **Chat** with streaming tokens, multi-step tool calls, and a real tool loop.
- **Assistant gesture**: set it as your phone's assistant, then long-press the
  power button (on phones that map assistant there) or use the home gesture to
  get a blurred voice overlay with live captions at the bottom.
- **Voice mode**: listen → think → speak loop with barge-in and hands-free
  follow-ups.
- **Share to assistant**: share text from any app (or use the text-selection
  menu) and it answers in a new turn.
- **Memory**: durable facts ("my name is…", "I live in…", "remember that…") are
  captured on-device, injected into every prompt, and editable or deletable in
  Settings → Memory.
- **Tools** (33): device/battery/storage/RAM, connectivity, apps, files,
  screenshots, clipboard, contacts, calendar, alarms, timers, dialer, SMS,
  email, WhatsApp, Play Store, settings, weather, notes, notifications, web
  search.
- **Model store**: if you choose the local path, it scans RAM/cores/free
  storage, estimates tokens/second per model, and marks what will fit.

## Providers

| Provider | Default model | Notes |
| --- | --- | --- |
| OpenRouter | `deepseek/deepseek-v4.1-flash` | **Default free path.** Verified live: tool call in ~1.5 s, 1M context. Fallbacks: `openrouter/free`, `deepseek/deepseek-v4-flash` |
| Groq | `openai/gpt-oss-20b` | Fallback provider. Verified: tool calls, `reasoning_effort: low` |
| DeepSeek | `deepseek-chat` | Direct API (needs a DeepSeek key); text-only |
| Gemini | `gemini-2.5-flash` | Native function calling; the only remote provider wired for images |
| Custom | any | Any OpenAI-compatible base URL |

> Groq free-tier keys do **not** include the Llama models most tutorials
> mention — they answer `403`. The provider screen has **"Test key & list
> models"**, which calls `GET /models` with your key and lets you pick one that
> actually works on that account.

### Fallbacks

Three layers, in order:

1. **Model chain** — 403/404/"model does not support tools" moves to the next
   model for that provider; a 429 after two retries tries another model, since
   quotas are per-model.
2. **Transient retry** — 429/5xx retried twice with backoff, but only before
   anything has been streamed, so a reply is never duplicated.
3. **Provider fallback** — if the selected key is rejected outright, another
   provider you already configured is tried for that session only. The saved
   choice is not changed.

### Demo key (optional, trial only)

Build with:

```bash
flutter build appbundle --release \
  --dart-define=GROQ_DEMO_KEY=gsk_... \
  --dart-define=GROQ_DEMO_MODEL=openai/gpt-oss-20b
```

For local testing you can do the same with `flutter run` and those
`--dart-define` flags. The key is read from the build environment, never from a
file in this repository.

There is a per-install limit of 25 demo messages/day, and the UI labels it as a
shared demo key. **A key compiled into an APK is extractable** — treat it as a
trial funnel, rotate it, and move production traffic to your own proxy (see
AUDIT.md §7).

## Requirements

- Android 7.0+ (API 24), arm64 recommended
- A phone with ≥ 4 GB RAM for the 1.5B model, ≥ 6 GB for the 3.8B model
- 2–4 GB free storage per model

## Build

```bash
flutter pub get
flutter run            # debug
flutter build appbundle --release
```

### Release signing

Create `android/key.properties` (git-ignored):

```properties
storeFile=../upload-keystore.jks
storePassword=…
keyAlias=upload
keyPassword=…
```

Generate the keystore once and **back it up** — losing it means you can never
update the app on Play:

```bash
keytool -genkey -v -keystore upload-keystore.jks -keyalg RSA -keysize 4096 \
        -validity 10000 -alias upload
```

Without that file, `--release` falls back to debug signing so local runs work,
but such a build must not be uploaded.

### Models

Models are **not** bundled. They download on first use into
`ApplicationDocumentsDirectory/models/` from the URLs in
`lib/services/model_registry.dart`. Add a model by adding a `ModelSpec` there
(see the doc comments for the CPU/GPU reasoning per model).

## Configuration

No `.env` file is used or bundled. API keys are entered in the app and stored in
SharedPreferences (see the audit for the planned move to the Android keystore).

## Architecture

```
lib/
  main.dart                     boot: prefs → route → runApp
  screens/
    onboarding/                 first-run flow (animated, device-aware)
    splash_screen.dart          model load + warmup
    chat_screen.dart            streaming chat, tools, confirmations
    voice_mode_screen.dart      voice state machine
    home_screen.dart            model store
    settings_screen.dart
    api_key_setup_screen.dart
  services/
    agent_service.dart          routes local vs remote, owns the chat session
    gemini_service.dart         Gemini transport
    llm/                        provider config + OpenAI-compatible client
    tool_runtime.dart           kToolCatalog, dispatch, coercion, timeouts
    device_capability.dart      device scan + model fit/tok-s estimates
    memory_service.dart         persistent facts + heuristic capture
    assistant_service.dart      ACTION_ASSIST / share channel
    model_benchmarks.dart       measured tok/s per model on this device
    startup_trace.dart          [startup] timing marks (--profile)
    model_downloader_service.dart  resumable, integrity-checked downloads
    permission_flow.dart        contextual permissions
    file_service.dart, personal_service.dart, utility_service.dart, ...
    embedding/                  MiniLM ONNX + tool/memory retrieval
```

## Privacy

Local mode: inference, storage and history stay on the device. Network is used
only for model downloads and for tools that inherently need it (web search,
public IP).

Cloud mode: messages and tool results are sent to Google's Gemini API with your
key. Read `AUDIT.md` before enabling it in a published build.

## Status

See [`AUDIT.md`](AUDIT.md) for the current audit, the list of fixed defects, and
the prioritized backlog (Play compliance, search backend, notification tool,
tests).
