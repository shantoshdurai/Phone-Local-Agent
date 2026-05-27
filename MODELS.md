# Models — what we've shipped, what we dropped, why

Running log of every model this app has been wired against. Add the next row when you swap. Source of truth for "what's been tried so far" so we don't loop.

## Currently shipping

**Phi-4 mini Instruct** (q8, ekv1280 .task) — on-device, `flutter_gemma`
- File: `Phi-4-mini-instruct_q8.task` (~3.8 GB)
- URL: `huggingface.co/litert-community/Phi-4-mini-instruct`
- Backend: **CPU** (fastest time to first token)
- Sampling: **temp 0.7, topK 40, topP 0.95**
- Max tokens: 1024
- Min RAM: 6 GB
- Tools: yes (Stronger reasoning for 16-tool context window, open weights)
- Vision: no
- Status: ✅ active

## Cloud option (Settings → switch to Gemini)

**Gemini 2.5 Flash** — `gemini-2.5-flash` via `google_generative_ai`
- File: `lib/services/gemini_service.dart`
- Switched in by passing the `kCloudModelSentinel` ("gemini-cloud") to `AgentService.initialize`.
- User supplies their own API key in Settings.
- Status: ✅ active fallback

## Dropped — chronological

### 2026-05-07 — v1.0: Gemini API only
- Initial commit (`524717d`). Single backend: Gemini Flash via API key.
- Dropped: user wanted offline. Migrated to local inference 2026-05-11.

### 2026-05-11 (early) — Multi-cloud
- Gemini 2.5 Flash + Gemini 1.5 Flash fallback + Groq models for speed.
- Dropped: confusing model-switching loops; rate limits on free tier; user wanted offline (`e6e0c46`).

### 2026-05-11 — Qwen 2.5 GGUF via `fllama`
- Q4_K_M GGUF, CPU inference via llama.cpp bindings.
- Dropped: `fllama` dart-sdk constraint problems, slow CPU-only, no GPU offload (`448ae22`).

### 2026-05-11+ — flutter_gemma migration
Moved to Google's `flutter_gemma` SDK, which wraps **LiteRT-LM** (MediaPipe GenAI). All subsequent local models below are `.task` or `.litertlm` files from `huggingface.co/litert-community/*`.

### Gemma 3 1B Lite (q4, ekv2048)
- File: `Gemma3-1B-IT_multi-prefill-seq_q4_ekv2048.task` (~555 MB)
- Sampling tried: temp 0.55, topK 40
- Dropped: too small for tool calls; latched onto `\n` tokens on harder prompts (the loop detector in `agent_service.dart` was written for this). Hot-swapped out of registry.

### Gemma 4 E2B (multimodal, .litertlm)
- File: `gemma-4-E2B-it.litertlm` (~2.6 GB)
- Vision + tools + reasoning. Sampling: temp 0.7, topK 40.
- Dropped: too heavy for the target devices (8 GB RAM minimum to load comfortably); cold-start was 30+ s. Kept the vision plumbing for if/when we re-add a vision spec.

### FunctionGemma 270M (commit `4e3b64f`)
- File: `functiongemma-270M-it.task` (~284 MB)
- Sampling: temp 1.0, topK 64.
- Dropped same commit it was tried: per Google's model card, this is **not** a dialogue model — fine-tuned for function-call queries only. Emitted literal tokens like `<start_function_call> coalescence …` on chit-chat. Reverted to Qwen 2.5 1.5B.

### Llama 3.2 3B Instruct
- File: `Llama-3.2-3B-Instruct_q8.task` (~3.3 GB)
- Dropped: 401 Unauthorized during app download. Llama is a gated model on HuggingFace and requires a user token/license acceptance, which our `ModelDownloaderService` doesn't handle. Swapped to Phi-4 mini Instruct.

### Qwen 2.5 1.5B-Instruct
- File: `qwen2.5-1.5b-instruct-q8.task` (~1.7 GB)
- Sampling: temp 1.0, topK 40.
- Dropped: 1.5B parameters proved too small to reliably process the 16-tool system prompt array. Frequently ignored tools or hallucinated syntax. Replaced by Llama 3.2 3B Instruct (and then Phi-4 mini).

## Sampling / backend history for Qwen 2.5 1.5B

| Date | backend | maxTokens | temp | topK | topP | Notes |
|------|---------|-----------|------|------|------|-------|
| 2026-05-19 | GPU | 1280 | 0.1 | 1 | 0.95 | Set tight to "keep tool-call args factual." Broke chit-chat — argmax made the model emit pure newlines on "Hi", which the loop-detector flagged as garbage. |
| 2026-05-21 (am) | GPU | 1280 | 0.7 | 40 | 0.95 | Restored chat-friendly sampling. Still slow on first send because GPU shader JIT takes 60–120 s on mid-range Adreno/Mali. |
| 2026-05-21 (pm) | **CPU** | 1024 | 1.0 | 40 | 0.95 | Matched Google's official AI Edge Gallery `model_allowlist.json` exactly. CPU has no JIT cliff — first token streams in seconds. maxTokens dropped from 1280 to 1024 to leave 256-token headroom under the KV-cache cap. |

## Future candidates (not yet tried)

- **Phi-4 mini Instruct (3.8B)** — strong tool calling, ~4 GB.
- **Hammer 2.1 1.5B** — function-calling specialist, same size as current Qwen. Would pair with Qwen as a "tools" router.
- **Custom fine-tune of Gemma 3 1B** — user's stated long-term plan: fine-tune on this app's tool-calling traces.

## Where to make the change

A model swap is **one file**: `lib/services/model_registry.dart`. Add a new `ModelSpec`, append to `ModelRegistry.all`, and (if it should be the default) return it from `defaultForDevice`. Everything else — downloader, splash, settings, chat header — reads off the spec.

If you change sampling, change it in the `ModelSpec`, not in `_rebuildChat`.
