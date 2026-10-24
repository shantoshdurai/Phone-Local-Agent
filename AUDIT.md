# Local Agent — code audit & release readiness

_Last updated after the fix pass in this session. Static analysis: `dart analyze lib` → **0 errors, 0 warnings**._

---

## 0. Headline

The project **did not compile** when this audit started. `AgentService` called
`debugPrint` without importing `package:flutter/foundation.dart`, which is two
hard errors (`agent_service.dart:451`, `:455`). Any `flutter build` would have
failed. That is fixed, and the analyzer is now clean.

Beyond that, the app had four kinds of problems:

| Area | Verdict before | Verdict now |
| --- | --- | --- |
| Build | ❌ did not compile | ✅ clean analyze |
| Voice chat | ❌ restart storm, double-submit, silent permission failure | ✅ rewritten state machine |
| Onboarding | ⚠️ 3 static screens, 6 permissions up-front, cloud dead-end | ✅ animated, device-aware, 1 optional permission |
| Model picking | ❌ recommendation ignored the device (`defaultForDevice` returned a constant) | ✅ RAM/cores/storage scan → fit + predicted tok/s |
| Downloads | ❌ truncated download counted as success; UI blocked during write | ✅ integrity-gated, async, resumable, space-checked |
| Tool calls | ⚠️ casts threw on `"true"`/`"50%"`, no timeout, unbounded outputs | ✅ coercion + deadline + structural caps + confirm gate |
| Play policy | ❌ `MANAGE_EXTERNAL_STORAGE`, `QUERY_ALL_PACKAGES`, no FGS type, debug signing, `.env` in APK | ✅ manifest/gradle rewritten |

---

## 1. What was actually broken (and is now fixed)

### P0 — could not ship

1. **Build failure** — `debugPrint` not imported in `agent_service.dart`.
   Fixed by importing `package:flutter/foundation.dart`.

2. **Cloud mode was unreachable after onboarding** — choosing Cloud wrote
   `mode=cloud`, then navigated to `HomeScreen`, which is the *local model
   downloader*. There was no path from there to cloud chat; the only working
   cloud route was a boot-time sentinel. Fixed: the key screen now routes to
   `SplashScreen(kCloudModelSentinel)`.

3. **"Skip" on the cloud key screen created a permanent loop** — onboarding had
   already set `onboarding_seen=true` and `mode=cloud`; skipping only navigated
   away, so the next launch saw "cloud with no key" and returned to the same
   screen. Fixed: skipping writes `mode=local` first.

4. **API key screen accepted a key then silently did nothing offline** — save
   required a live `generateContent` ping. Fixed: network failures save the key
   with a warning; only an actual rejection blocks.

5. **A truncated model download was treated as a successful install** — the
   old downloader renamed `.part` → final on any non-cancelled exit, so a
   dropped connection produced a model that crashed the engine at load with no
   actionable error. Fixed: byte count is verified before publish, and the
   `.part` file is kept for resume.

6. **`MANAGE_EXTERNAL_STORAGE` + `QUERY_ALL_PACKAGES`** — both are Play
   restricted and this app is not a qualifying file manager / launcher. Removed;
   replaced with granular media permissions and a `<queries>` block.

7. **Release builds were signed with the debug key** and had no minification.
   Now configured for a real upload key (`android/key.properties`), R8 +
   resource shrinking, and per-ABI splits.

### P1 — features that did not work

8. **Voice mode** (`voice_mode_screen.dart`) — rewritten. Root causes of the
   "it cuts off / repeats / does nothing" behaviour:
   - `onStatus(notListening|done)` **and** `onError` **and** the submit path all
     scheduled `_startListening()` independently. `_startListening` cancels then
     re-arms the recogniser, which fires `onStatus` again → a cancel/re-arm
     storm while the final transcript was still being delivered.
   - `_handleSubmit` had no idempotency guard, so the final result callback and
     a mic tap could submit the same utterance twice.
   - `_startListening` cleared `_userTranscript` on every re-arm, discarding
     partial text.
   - A denied microphone permission produced no UI at all: `initialize()`
     returned false and the screen simply sat on "TAP TO START".
   - TTS reopened the mic with no drain delay, so the recogniser sometimes
     transcribed the agent's own reply.

   The new implementation has one owner of the mic, a generation token that
   invalidates stale callbacks, a `_submitting` guard, a 380 ms audio drain, a
   barge-in path, lifecycle handling, mic-level-reactive ring, and real error
   states with "Open settings".

9. **The chat mic did nothing without a prior permission grant** —
   `_ensureSpeechReady()` returned false silently. Now requests the mic
   contextually and surfaces success/failure.

10. **`_handleSubmitted` could hang forever** — it awaited `stopGeneration()`
    then spun `while (_isTyping)` with no timeout. If the native engine never
    acknowledged the stop, the composer stayed disabled. Now bounded to 3 s.

11. **Stream subscription leak** — `ChatScreen.initState` created a status
    stream listener that was never cancelled, one per chat screen instance.

12. **The greeting was persisted as an assistant message** on every new chat.
    It was then replayed into the model's context, so a fresh chat could start
    with the model quoting its own welcome line, and it consumed KV budget on a
    1280-token window. It is now a UI-only element.

13. **Settings switches were `State`-only and one was a lie** — "Confirm before
    actions" reset on every visit and was wired to nothing. Now persisted, and
    actually enforced: `ToolRuntime` asks the UI before `uninstall_app`,
    `make_phone_call`, `send_whatsapp`, `schedule_event`.

14. **Settings claimed "MediaPipe · GPU delegate / GPU"** while both models run
    on LiteRT-LM with `preferredBackend: cpu`. Corrected, and "Active model" now
    reflects the last-used model instead of a constant.

15. **Tool arguments threw on realistic model output** — `args['on'] as bool?`
    fails for `"true"`, `args['hour'] as int?` fails for `7.0` or `"7"`,
    `args['level'] as num?` fails for `"50%"`. Added a coercion layer, plus:
    - 20 s deadline per tool (previously a stalled request blocked the turn
      forever),
    - structural output shrink (a 60-app list was ~3 KB of prefill on a
      1280-token cache),
    - clipboard capped at 400 chars,
    - contacts require a non-empty query and return ≤ 5 (an empty query used to
      match the entire address book),
    - `open_url` restricted to http/https (no `intent://` injection),
    - alarm/timer range validation, and `SKIP_UI=false` so the user confirms,
    - volume accepts `0.5`, `50`, `"50%"` and reports the normalised value.

16. **`check_connectivity` took up to ~15 s** — three sequential HTTP calls with
    5 s timeouts — and returned neither SSID nor local IP despite promising both
    in its description (which made models invent an SSID). Now one DNS probe
    with a 3 s timeout, plus the real connection types.

17. **`list_files` blocked the UI isolate** with recursive `listSync` over four
    trees plus an awaited `stat()` per file. Moved into an isolate, capped, and
    made permission-aware.

### P2 — packaging / polish

18. Dark launch window (was a white flash before the first frame), including the
    Android 12+ system splash.
19. `.env` was bundled as an asset into every APK while only `main.dart`
    "read" it (and nothing used the values). Removed from assets; `.env`,
    `*.jks` and `android/key.properties` are git-ignored.
20. Removed `android:enableJetifier=true` and a forced `androidx.core:1.13.1`
    pin that conflicts with compileSdk 36.
21. Hardcoded personal name "shantosh"/"SD" in the drawer, `android:label=
    "local_agent"`, and a stale version string.
22. Deleted the superseded onboarding screens (`intro`, `permissions`,
    `mode_selection`) so there is exactly one first-run flow.

---

## 2. New pieces

| File | Purpose |
| --- | --- |
| `lib/services/device_capability.dart` | One cached scan (RAM, cores, free storage, SDK, ABIs) + model-fit scoring and predicted tok/s |
| `lib/services/permission_flow.dart` | Contextual permission topics; never prompts blind, detects permanent denial, `READ_MEDIA_*` vs legacy storage by SDK |
| `lib/services/app_settings.dart` | Persisted, synchronously readable settings (confirm / stream / history) |
| `lib/services/model_benchmarks.dart` | Records real decode tok/s per model on this device (EMA), so the store can show *measured* instead of *estimated* |
| `lib/services/startup_trace.dart` | `[startup]` marks on a Stopwatch — makes cold-start claims measurable with `flutter run --profile` |
| `lib/screens/onboarding/onboarding_screen.dart` | 3-step animated flow: welcome → device check + recommended model → optional mic |
| `lib/screens/home_screen.dart` (rewritten) | Model store: fit badges, predicted speed, storage requirement, resume/pause/delete |
| `lib/screens/voice_mode_screen.dart` (rewritten) | See §1.8 |

### How the model recommendation works

`DeviceCapability.fitFor()` scores every registry entry:

```
requiredStorage = sizeMB * 1.12
coreFactor      = (cores / 8) ^ 0.7        // clamped 0.35 … 1.35
tps             = baselineTps * coreFactor // ×0.75 if RAM ≤ minRamGB
                                           // ×0.6 if not arm64
unsupported     = freeStorage < requiredStorage || RAM < minRamGB
heavy           = RAM ≤ minRamGB + 1 || tps < 3.5
```

`baselineTps` lives on `ModelSpec` (8-core reference measurement), so adding a
model is still a data change. The UI always labels the number **estimated** —
over-promising tokens/s is worse than being pleasantly surprised.

Once a model has answered one message, `ModelBenchmarks` replaces the prediction
with the measured value for that model on that device, and the UI switches its
label from `estimated` to `measured`. The prediction therefore only ever shows
before the first turn.

---

## 3. Still open — prioritized backlog

### P0 before you upload

1. **Two signing artefacts, one Play console.** Create the upload key
   (`keytool -genkey -v -keystore upload.jks -keyalg RSA -keysize 4096 -validity 10000 -alias upload`),
   put it in `android/key.properties`, and back it up. Debug-signed builds are
   rejected for new uploads on modern Play.
2. **Data safety form must match reality.** Local mode collects nothing. Cloud
   mode sends message text + tool results to Google. Declare that, and link a
   privacy policy that names Gemini.
3. **Sensitive permissions declaration.** `READ_CONTACTS`, `READ_CALENDAR`,
   `NotificationListenerService` and `RECORD_AUDIO` all need in-app rationale
   plus the Play "sensitive permissions" form. The notification listener is the
   riskiest one — if you are not shipping the feature, **delete the service
   declaration** (it currently returns `success:true` with no data, which is
   worse than not having it).
4. **Model download size.** 1.7–3.8 GB over Play-installed app + first-run
   download is fine, but you need: Wi-Fi-only default, a visible "this is
   ~2 GB" step, and resumability (done). Consider downloading *after* the user
   says which model, never automatically.
5. **Cloud mode sends all 26 tools**, including clipboard, contacts and
   notifications, with no tiering and no per-tool consent. At minimum reuse
   `selectForBudget` and gate personal-data tools behind an explicit toggle.

### P1 — correctness

6. **`search_service.dart:65-100` scrapes Google's HTML** with a spoofed desktop
   Chrome UA and obfuscated class names. That violates Google's ToS, breaks on
   captcha, and fails silently. Replace with Brave Search API / DuckDuckGo HTML
   / Tavily — one API key, structured JSON.
7. **Wikipedia fallback has no relevance gate** (`search_service.dart:102-129`):
   "weather in london" returns the Wikipedia article for London and the model
   presents it as the answer. Require a title/keyword match or drop the fallback.
8. **`read_notifications` cannot work as written.** No service declaration was
   present (now added), but the Dart side returns a message instead of the
   cached notifications. Needs: subscribe to
   `NotificationListenerService.notificationsStream`, cache the last N in memory
   with a TTL, return them, and return a real error when ungranted. Otherwise
   remove the tool.
9. ~~Database caps chat history at 5 sessions~~ — **resolved**: the cap is 100,
   and the drawer now has rename/delete/search. A per-chat delete confirmation
   replaces the silent eviction.
10. **`personal_service.dart:31,62-64`** null-asserts `permissions.data!` /
    `calendars.data!` on the success path → `Null check operator used on a null
    value`. Use `?? false` / `?? const []`, filter `isReadOnly`, validate
    `start < end`.
11. **`app_service.dart` re-enumerates every package** and calls
    `File.length()` per APK on every `list_apps`, and returns `[]` on failure
    (so the model says "you have no apps"). Add a TTL cache + invalidation and
    an explicit error result.
12. **Deep links depend on the removed `QUERY_ALL_PACKAGES`.** I added
    `<queries>` for https/market/tel/SEND/WhatsApp; verify each `canLaunchUrl`
    path on a real device (Play Store search, WhatsApp, dialer).
13. **`google_fonts` fetches fonts at runtime.** On first launch (or offline)
    text renders in a fallback and swaps — a visible flash, a network call that
    contradicts "fully offline", and a cold-start cost. Bundle Inter Tight +
    JetBrains Mono in `pubspec.yaml` and set
    `GoogleFonts.config.allowRuntimeFetching = false`.

### P2 — quality, performance, polish

14. **Cold start.** Done in this pass:
    - `ToolIndex.build()` (ONNX session + 26 embeddings + 22 MB first-run asset
      extraction) **no longer runs during model warmup**. It now starts after
      the first turn completes — previously it competed for CPU on the exact
      path that produces the first token.
    - The splash clock no longer `setState`s the whole subtree once a second;
      it is a `ValueNotifier` around one `Text`.
    - The white launch window is black (previously a full-screen flash before
      the first frame), including Android 12+ system splash.
    - `.env` is no longer loaded at boot or bundled.
    - `[startup]` marks (`app_main`, `first_frame`, `initialize_start`,
      `model_ready`, `chat_ready`) make the remaining cost measurable:
      `flutter run --profile` and filter for `[startup]`.

    Remaining options, once you have a device trace:
    - `_warmupModel()` runs a throwaway 4-token generation on every launch.
      Measure it; on CPU it may cost more than it saves.
    - `initialize()` re-`installModel`s the file each process. If the SDK call
      is not a cheap no-op for an already-installed model, cache the installed
      state.
    - `ChatScreen._initAgent` re-runs `initialize()` and then 4–5 DB calls
      before the composer appears.
15. **RAG hint injection into the user message** perturbs the prompt on small
   models. A cleaner design is retrieval → *tool subset* (which tools to declare)
   rather than a sentence inside the user turn. You already have the tiers;
   retrieval could replace `toolBudget` as the selector.
16. **Tool catalogue has four hand-synced sources**: `kToolCatalog`,
    `agent_service._tools`, `kToolTiers`, `kToolDocs`. A missing tier entry
    silently becomes `niche` and disappears at Qwen's budget of 9. Put `tier` on
    the catalogue entry and add a test that the four name sets are equal.
17. **Accessibility**: zero `Semantics` in the old UI, 9–10 px text, a 22 dp
    switch target, `muted2 #4A4A4A` on black ≈ 2.4:1 (fails WCAG AA), and no
    `textScaler` handling on non-scrolling screens. The new onboarding handles
    scaling and reduced motion; the rest of the app does not.
18. **Message bubble performance**: no `RepaintBoundary`, a `MarkdownStyleSheet`
    plus five `GoogleFonts` calls per bubble per build, and entrance animations
    that replay when `ListView.builder` recycles off-screen items.
19. **No tests.** `test/widget_test.dart` is the Flutter template. Highest-value
    first tests: `DeviceCapability.fitFor` (RAM/storage boundaries),
    `selectForBudget`, `_Arg` coercion, `_stripForTts`, and a golden test for the
    onboarding first frame.
20. **Cloud tool-result privacy**: `read_clipboard` and `search_contacts` results
    are sent to Gemini verbatim (clipboard now capped at 400 chars). Add a
    per-tool "local only" class and refuse to forward those in cloud mode.

---

## 4. What would make this stand out

Not more features — fewer, sharper ones. In rough order of leverage:

1. **A model store that is a manifest, not code.** Serve `models.json` from your
   own CDN (version, SHA-256, size, min RAM, baseline tok/s, tool budget,
   license). Adding Qwen3-1.7B or Gemma-3-1B becomes a JSON edit, and you can
   retire broken models without an app update. Verify downloads against the
   SHA-256 — the current integrity check only compares byte counts.
2. **Self-calibrating speed — implemented.** After every turn,
   `AgentService` records `tokens / evalTime` per model into
   `ModelBenchmarks` (EMA, outlier-guarded). `DeviceCapability.fitFor` prefers
   that measured value over the core/size prediction, and the model store labels
   it `measured` instead of `est.` So the first message converts the estimate
   into a real number, and it keeps correcting for thermals and CPU governors.
   Next step: show a per-turn `tok/s` badge in the chat bubble for transparency.
3. **Region-of-context tool routing.** Your RAG index embeds tool docs; use the
   top-k to decide *which tool declarations to send* (dynamic `toolBudget`)
   instead of fixing it per model. That is what lets a 1.5B model be reliable at
   tool calling without a 26-tool prompt.
4. **One-tap "undo" for destructive actions.** Calls and messages now confirm,
   but the next step is a 10-second undo toast for things like volume/flashlight
   /alarm, so the agent feels safe to try things.
5. **Offline voice that does not leave the device.** `speech_to_text` on Android
   routes through Google's recogniser unless an on-device engine is present.
   Adding `whisper.cpp`/`sherpa-onnx` for a small multilingual model would make
   the privacy claim true end-to-end — and is the single strongest differentiator
   versus every cloud assistant.
6. **Battery-aware model switching.** On low battery or thermal throttling,
   offer the smaller model automatically (you now have per-model speed
   estimates, so this is a cost function, not a guess).

---

## 5. Play Console checklist

- [ ] Upload key created, `android/key.properties` populated and backed up.
- [ ] `flutter build appbundle --release` (AAB, not APK, for Play).
- [ ] Version code bumped (`pubspec.yaml` → `version: x.y.z+n`).
- [ ] Data safety form: local = none collected; cloud = message content shared
      with Google, declared.
- [ ] Privacy policy URL live and linked in-app.
- [ ] Sensitive permissions: contacts, calendar, microphone, notification
      listener — each with in-app rationale (onboarding covers mic + media).
- [ ] Content rating questionnaire: an assistant that can place calls / send
      messages / open URLs needs honest answers.
- [ ] Target API level = current Play requirement (`flutter.targetSdkVersion`).
- [ ] 64-bit: `arm64-v8a` included (gradle `abiFilters`).
- [ ] Test on a clean install with no Play services model cache.
- [ ] Test in airplane mode: onboarding, model store, chat, voice errors.
- [ ] Test permission "Don't allow" twice → in-app "Open settings" path.
- [ ] Test a killed download mid-way → resume completes and verifies.
- [ ] Test low-storage device: model cards must show "Won't fit", not crash.

---

## 6. Product features added after the audit

These target daily use rather than correctness, and they are why someone keeps
the app installed after the novelty wears off.

### Default assistant (system role)

- `AndroidManifest.xml` declares `ACTION_ASSIST` (with `DEFAULT`), so the app is
  eligible in the system "digital assistant" chooser.
- `MainActivity.kt` exposes `com.localagent/assistant`:
  `isDefaultAssistant`, `requestDefaultAssistant` (RoleManager, API 29+), and
  `consumeLaunchEvent`.
- Launch intents that arrive before Dart is ready are parked in
  `pendingLaunch`; runtime ones are pushed to Dart. The action is nulled after
  handling so rotation cannot replay a share.
- `AssistantService` (Dart) parses events and exposes a broadcast stream.
- `Settings → Personal → Default assistant` requests the role and re-checks on
  `didChangeAppLifecycleState(resumed)`.
- Routing: assist → voice mode; share → one-shot summarization turn.

### Share / process-text targets

`ACTION_SEND` (text/plain) and `ACTION_PROCESS_TEXT` are handled by the same
channel. `ChatScreen._handleLaunch` clips the payload to 1800 chars (≈450
tokens, leaving room in a 1280-token window) and sends it as a summarization
request, so the user gets an answer rather than a composer full of their own
text.

### Persistent memory

- `memories` table (DB v5) with `text`, `kind`, `created_at`, `use_count`.
- `MemoryService` captures durable facts with 15 high-precision patterns
  (name, city, workplace, birthday, timezone, favourites, likes/dislikes,
  explicit "remember that…"), **not** a second model call — extraction by a 1.5B
  model would double latency for worse precision.
- Injection is a bounded block (10 facts / 420 chars) appended to the system
  prompt for both local and cloud paths, so memory survives context refocus. A
  *newly captured* fact is also prepended to that turn's prompt as a one-line
  `[New fact about the user, learned just now: …]`, because the system prompt
  only changes when the chat session is rebuilt — without it, "my name is Sam"
  would not be usable until the next new chat.
- Every capture shows a 4-second "Saved to memory — … / Undo" snackbar.
- `Settings → Memory` lists every fact, supports manual add, delete, clear-all.
- Newest name supersedes the old one; duplicates are ignored; the store is
  capped at 60 facts, evicting the oldest and least-used.

### Chat management

- Drawer search filters sessions live.
- Per-session rename and delete (with confirmation) from the overflow menu.
- Session cap raised from **5 to 100** — the old limit silently deleted
  conversations after a day of use.

### Deliberately not done

- **Wake-word / always-listening.** It needs a background microphone foreground
  service, is a battery and privacy problem, and Play scrutinises it. The
  assistant role gives the same "one gesture away" access honestly.
- **Memory as LLM tools** (`remember_fact`, `forget_fact`). It would mean
  touching four hand-synced catalogues (see §3.16); the heuristic + UI cover the
  same intent for now.
- **Screen reading** (Accessibility/MediaProjection). Out of scope for v1 and
  policy-sensitive.

---

## 7. API-first architecture (latest pass)

The product focus moved from "local LLM runner" to "an assistant that does
things". The local model is now one provider among several, not the default.

### Provider layer

- `services/llm/provider_config.dart` — `LlmProvider {local, gemini, groq,
  deepseek, custom}`, per-provider key/model/base-URL storage, and
  `ProviderStore.resolve()`.
- `services/llm/openai_compatible_service.dart` — streaming client for
  `POST /chat/completions` with `tools`. Reliability details that matter:
  - **tool-call delta assembly** by `index` (arguments arrive in fragments),
  - multi-hop loop (4) with `role: tool` + `tool_call_id`,
  - **JSON-in-text recovery** once per turn when a model prints a tool call
    instead of emitting one,
  - 429/5xx retry only when nothing has been emitted yet,
  - **model chain**: 403/404/"model does not support tools" moves to the next
    model; a 429 after retries tries another model (quotas are per-model),
  - `reasoning_effort: low` for Groq gpt-oss models (measured below),
  - demo-quota guard before the request.
- **Provider fallback** (`AgentService._tryFallbackProvider`): if the selected
  key is rejected outright, another already-configured provider is tried for
  the session only — the saved choice is untouched.
- `RemoteAgent` interface; `AgentService` now routes local vs remote and the
  chat screen is unchanged.

### Live verification (real Groq free-tier key, this pass)

| Check | Result |
| --- | --- |
| `GET /models` | 200 — 11 models on the account |
| Chat models actually usable | `openai/gpt-oss-20b` ✅, `openai/gpt-oss-120b` ❌ 403, `qwen/qwen3.8-27b` ❌ 403 |
| Llama models from every tutorial | not present on this account |
| Tool call, non-streaming | ✅ `finish_reason=tool_calls`, `get_device_info({})` |
| Tool call, streaming | ✅ 14 SSE chunks, arguments reassembled correctly |
| Full round trip (tool result → answer) | ✅ “Your battery is at 73%.” |
| Latency, default reasoning | 814 ms to the tool call |
| Latency, `reasoning_effort: low` | **217 ms** to the tool call, same choice |

Consequences reflected in the code: Groq's default is `openai/gpt-oss-20b`
(not `llama-3.3-70b-versatile`, which 403s), 403 is classified as a
**model-level** error (not a bad key), and the provider screen can list the
account's real models via **"Test key & list models"**.

### Demo key — read this before shipping

`GROQ_DEMO_KEY` is a **build-time dart-define**, not a repo secret, with a
25-message/day/install quota and a "DEMO KEY" label. It is still extractable
from the APK. That is acceptable for a trial funnel and unacceptable as a
production credential. For production: a thin proxy (Cloudflare Worker) that
holds the key, issues per-install tokens, rate-limits by IP/install and
forwards only `/chat/completions`. That also lets you add abuse controls and
swap providers server-side without an app update.

### Model naming

"DeepSeek 4.1 Flash" does not exist as a public model id. DeepSeek exposes
`deepseek-chat` (V3.x) and `deepseek-reasoner` (R1). The provider screen has an
editable model field, so any future id works without an app update.

### Assistant gesture + voice overlay

- `ACTION_ASSIST` + `ROLE_ASSISTANT` (already wired) is how a power-button
  long-press reaches us — Android does not allow apps to intercept the power
  button directly; OEMs map long-press-power to the default assistant.
- `VoiceModeScreen(overlay: true)` is a transparent route: blurred backdrop,
  orb, and a bottom caption panel that shows the live transcript while
  listening and the streaming answer while speaking. It auto-resumes listening
  after each reply for hands-free follow-ups.
- Cold start matters less in API mode (no model to load), which is why the
  gesture now feels instant compared with the local path.

**Not done yet:** true system-level translucency over *other* apps requires a
separate `Activity` with a translucent window theme (a second Flutter entry
point), so the current overlay blurs our own surface.

**Soft cues are done:** two quiet chimes (`res/raw/cue_listen.wav`,
`cue_done.wav`, synthesised at 528 Hz / 396 Hz, ~110–150 ms) are played by a
native `MediaPlayer` in `MainActivity`, so there is no audio dependency and no
Google system sound. They fire only on real phase transitions (listening
start, answer start), alongside a light haptic — not on internal re-arms.

### Tool catalogue

`kToolCatalog` is now the single source: `AgentService._tools` is generated from
it, and `ToolIndex` falls back to the catalogue description when a rich
`kToolDocs` entry is missing. **33 tools** — added `get_weather`, `create_note`,
`list_notes`, `delete_note`, `open_settings`, `send_sms`, `compose_email`.

### Onboarding

Step 1 now offers **"Start with cloud AI"** (provider setup, no download) as the
primary path and "Run on this phone instead" as the secondary. Provider setup
handles the demo key, user keys, model ids and a custom base URL, then goes
straight to chat.



## 8. Verification done in this pass

- `dart analyze lib test` → **No issues found** (0 errors, 0 warnings, 0 lints).
- **Unit tests: 12/12 pass** (`test/model_fit_test.dart`, run with
  `flutter test`). They cover the fit engine's storage/RAM/measured-speed
  boundaries, the single-`best` ranking invariant, graceful handling of unknown
  hardware, and `selectForBudget` keeping core tools when the budget is smaller
  than the core set. The stock counter widget test (which could never pass) was
  removed.
- Android XML validated as well-formed: manifest, all four style files, both
  launch-background drawables.
- Manifest permission set audited from the parsed XML — exactly: INTERNET,
  ACCESS_NETWORK_STATE, RECORD_AUDIO, WAKE_LOCK, FOREGROUND_SERVICE,
  FOREGROUND_SERVICE_DATA_SYNC, POST_NOTIFICATIONS, VIBRATE, SET_ALARM,
  READ_CONTACTS, READ/WRITE_CALENDAR, REQUEST_DELETE_PACKAGES,
  READ_EXTERNAL_STORAGE (≤32), READ_MEDIA_IMAGES/VIDEO/AUDIO/VISUAL_USER_SELECTED.
  No `MANAGE_EXTERNAL_STORAGE`, no `QUERY_ALL_PACKAGES`, no `CALL_PHONE`, no
  `CAMERA`.
- Traced every edited call site for signature changes
  (`ModelDownloaderService.downloadModel` now requires `expectedSizeMB`,
  `ToolRuntime` gained a static confirm hook, `FileService` dropped
  `downloadFile`, `DeviceCapability.fitFor/rank` gained an optional
  `measuredTps`/`measured` argument, `ModelFit` gained `isMeasured`).
- Confirmation hook teardown is identity-checked: with `pushReplacement`, the
  outgoing screen's `dispose` could otherwise null the hook installed by the
  incoming screen.
- Deleted screens were checked for inbound references before removal.
- `git status` reviewed: the working tree contains only the intended edits, no
  subagent or tool side-effects.

### What could not be verified here

**No Android build was produced.** `flutter build apk --release` was attempted
and could not complete: the wrapper pins Gradle 8.9, that distribution is not in
the local cache, and `services.gradle.org` stalled at 0 bytes (only Gradle
9.1/9.4 are cached, which AGP 8.7 does not support). This is an environment
network limitation, not a project error — your machine's Gradle daemon cache
shows 8.14 builds, so the build should run there.

Before uploading:

```
flutter build appbundle --release
flutter run --profile        # then read the [startup] lines
```

If R8 rejects anything, the keeps in `android/app/proguard-rules.pro` now cover
MediaPipe/LiteRT, protobuf, ONNX Runtime, `flutter_background`,
`notification_listener_service`, and the app package itself.
