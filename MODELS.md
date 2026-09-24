# Models: what ships, how it was chosen, what was dropped

Running log of every model this app has been wired against. Add to it when
you change the lineup, so we don't loop.

## Runtime (since 2026-09-24)

**llama.cpp through [llamadart](https://pub.dev/packages/llamadart)**, GGUF
files from Hugging Face. Replaced flutter_gemma (MediaPipe / LiteRT-LM) because:

- any GGUF model on Hugging Face runs (the Models hub depends on this), on
  arm64 **and** x86_64 (the LiteRT-LM build only ran on arm64);
- chat templates, tool-call parsing and vision projectors come from the model
  file, so a new model needs no code;
- it can be tested on a desktop: `test/local_agent_e2e_test.dart` runs the real
  agent with a real model and live web search.

Two llama.cpp behaviours shape the code in `lib/services/local/local_engine.dart`
and `lib/services/agent/local_agent.dart`:

1. **No tool-call grammar.** llama.cpp's lazy grammar sampler throws a C++
   exception ("Unexpected empty grammar stack") when a model keeps writing
   after a finished call. Through FFI that aborts the whole app (reproduced
   with Qwen3 0.6B). The engine renders the template and generates without
   the grammar, then parses calls with the model family's handler.
2. **Prompt cache.** llama.cpp reuses the previous prompt's KV cache. With
   standard attention only new tokens are processed (Gemma 4, MiniCPM5,
   Qwen3: about 25 tokens per turn). Hybrid/recurrent models (Qwen3.5, LFM2,
   Mamba) re-read the whole prompt every turn (500 to 750 tokens here), which
   on a phone means a long wait before every reply. The system prompt holds
   only the date, not the time, so the cache stays valid.

## Curated lineup

| Tier | Model | File | Size | Photos | Tools | For |
| --- | --- | --- | --- | --- | --- | --- |
| Fastest | Qwen3.5 0.8B | `unsloth/Qwen3.5-0.8B-GGUF` Q4_K_M + mmproj-F16 | 508 MB + 195 MB | yes | lookups only | ≤ 4 GB phones |
| Balanced | MiniCPM5 2B | `openbmb/MiniCPM5-2B-GGUF` Q4_K_M | 1.5 GB | no | all | 6 GB phones |
| Smartest | Gemma 4 E2B | `google/gemma-4-E2B-it-qat-q4_0-gguf` | 3.1 GB + 0.9 GB | yes | all | 8 GB+ phones |
| Best | Gemma 4 E4B | `google/gemma-4-E4B-it-qat-q4_0-gguf` | 4.8 GB + 0.9 GB | yes | all | 12 GB+ flagships |

All pinned to commit SHAs in `lib/services/local/model_catalog.dart`, with
sampling from each model card (Qwen3.5: presence penalty 1.5; MiniCPM5: min-p 0,
llama.cpp's default 0.05 causes loops).

Recommendation (`ModelCatalog.recommendedFor`): the biggest model that fits in
75% of the RAM usable for AI (total minus 30%, 1.5–3 GB), with Gemma 4 only on
CPUs with dotprod (ARMv8.2+). An 8 GB Dimensity 700 phone gets Gemma 4 E2B.

## Evaluation (2026-09-24)

Twelve prompts with the app's system prompt and ten tools, CPU, greedy-ish
sampling. ✅ right tool or right answer, ⚠️ acceptable, ❌ wrong.

| Prompt | Qwen3.5 0.8B | Qwen3.5 2B | LFM2.5 1.2B | Qwen3 1.7B | MiniCPM5 2B | Gemma 4 E2B |
| --- | --- | --- | --- | --- | --- | --- |
| timer 10 min | ❌ 10 s | ✅ | ✅ | ✅ | ✅ | ✅ |
| weather in Pune | ✅ | ✅ | ❌ refused | ✅ | ✅ | ✅ |
| who won the last F1 race | ❌ invented | ✅ search | ❌ refused | ❌ refused | ✅ search | ✅ search |
| bitcoin price | ❌ weather tool | ✅ search | ❌ refused | ❌ refused | ⚠️ offered to search | ✅ search |
| flashlight on | ❌ opened YouTube | ⚠️ XML as text* | ✅ | ✅ | ✅ | ✅ |
| WhatsApp mom | ❌ | ❌ web search | ❌ invented number | ❌ claimed sent | ⚠️ asked number | ⚠️ asked number |
| 17 × 23 | ✅ | ✅ | ❌ empty | ✅ | ✅ | ✅ |
| open YouTube | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |
| hi | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |
| alarm 6:30 | ❌ timer | ✅ | ✅ | ✅ | ✅ | ✅ |
| CEO of Nvidia | ❌ invented | ⚠️ right name, wrong year | ❌ refused | ❌ invented | ⚠️ offered to search | ✅ search |
| haiku | ❌ weather tool | ❌ search | ✅ | ✅ | ✅ | ✅ |
| Reuses prompt cache | no | no | no | yes | yes | yes |

\* now recovered by the XML fallback parser in `text_utils.dart`.

Messaging by name and most phone actions no longer depend on the model: the
instant router resolves the contact and opens WhatsApp/SMS itself.

End-to-end (real agent, Gemma 4 E2B, live search, 4-core x86 CPU): "Who won the
most recent Formula 1 race?" → searched, answered from Google News headlines
with the date; "set a timer for 10 minutes" → direct reply in ~3 s;
"17 × 23" → 391 without tools; Stop ends generation in ~25 ms.

## Models hub

Anything else comes from the Explore tab (Hugging Face search filtered to GGUF
chat models that fit the phone; uncensored/NSFW repos are hidden). Hub models
with no tool support in their chat template run as plain chat; models under 2B
parameters get lookup tools only.

## History (flutter_gemma era and before)

### Dropped, chronological

#### 2026-05-07 — v1.0: Gemini API only
- Initial commit (`524717d`). Single backend: Gemini Flash via API key.
- Dropped: user wanted offline. Migrated to local inference 2026-05-11.

#### 2026-05-11 (early) — Multi-cloud
- Gemini 2.5 Flash + Gemini 1.5 Flash fallback + Groq models for speed.
- Dropped: confusing model-switching loops; rate limits on free tier; user wanted offline (`e6e0c46`).

#### 2026-05-11 — Qwen 2.5 GGUF via `fllama`
- Q4_K_M GGUF, CPU inference via llama.cpp bindings.
- Dropped: `fllama` dart-sdk constraint problems, slow CPU-only, no GPU offload (`448ae22`).

#### 2026-05-11+ — flutter_gemma migration
Moved to Google's `flutter_gemma` SDK, which wraps **LiteRT-LM** (MediaPipe GenAI). All subsequent local models below are `.task` or `.litertlm` files from `huggingface.co/litert-community/*`.

#### Gemma 3 1B Lite (q4, ekv2048)
- File: `Gemma3-1B-IT_multi-prefill-seq_q4_ekv2048.task` (~555 MB)
- Sampling tried: temp 0.55, topK 40
- Dropped: too small for tool calls; latched onto `\n` tokens on harder prompts (the loop detector in `agent_service.dart` was written for this). Hot-swapped out of registry.

#### Gemma 4 E2B (multimodal, .litertlm)
- File: `gemma-4-E2B-it.litertlm` (~2.6 GB)
- Vision + tools + reasoning. Sampling: temp 0.7, topK 40.
- Dropped: too heavy for the target devices (8 GB RAM minimum to load comfortably); cold-start was 30+ s. Kept the vision plumbing for if/when we re-add a vision spec.

#### FunctionGemma 270M (commit `4e3b64f`)
- File: `functiongemma-270M-it.task` (~284 MB)
- Sampling: temp 1.0, topK 64.
- Dropped same commit it was tried: per Google's model card, this is **not** a dialogue model — fine-tuned for function-call queries only. Emitted literal tokens like `<start_function_call> coalescence …` on chit-chat. Reverted to Qwen 2.5 1.5B.

#### Llama 3.2 3B Instruct
- File: `Llama-3.2-3B-Instruct_q8.task` (~3.3 GB)
- Dropped: 401 Unauthorized during app download. Llama is a gated model on HuggingFace and requires a user token/license acceptance, which our `ModelDownloaderService` doesn't handle. Swapped to Phi-4 mini Instruct.

#### Qwen 2.5 1.5B-Instruct
- File: `qwen2.5-1.5b-instruct-q8.task` (~1.7 GB)
- Sampling: temp 1.0, topK 40.
- Dropped: 1.5B parameters proved too small to reliably process the 16-tool system prompt array. Frequently ignored tools or hallucinated syntax. Replaced by Llama 3.2 3B Instruct (and then Phi-4 mini).

### Sampling / backend history for Qwen 2.5 1.5B

| Date | backend | maxTokens | temp | topK | topP | Notes |
|------|---------|-----------|------|------|------|-------|
| 2026-05-19 | GPU | 1280 | 0.1 | 1 | 0.95 | Set tight to "keep tool-call args factual." Broke chit-chat — argmax made the model emit pure newlines on "Hi", which the loop-detector flagged as garbage. |
| 2026-05-21 (am) | GPU | 1280 | 0.7 | 40 | 0.95 | Restored chat-friendly sampling. Still slow on first send because GPU shader JIT takes 60–120 s on mid-range Adreno/Mali. |
| 2026-05-21 (pm) | **CPU** | 1024 | 1.0 | 40 | 0.95 | Matched Google's official AI Edge Gallery `model_allowlist.json` exactly. CPU has no JIT cliff — first token streams in seconds. maxTokens dropped from 1280 to 1024 to leave 256-token headroom under the KV-cache cap. |

## Future candidates

- **Qwen3.5 2B/4B** once llama.cpp can checkpoint hybrid-model state for
  prompt reuse: good tool use and vision, but re-reading the prompt every turn
  is too slow on phones today.
- **LiteRT-LM for Gemma on GPU**: llamadart can also run `.litertlm` files; it
  is left out of the build (about 50 MB of native libraries) until GPU
  inference is worth it on the phones we target.
- **1-bit / ternary models** (Bonsai) as llama.cpp CPU support matures.

## Where to make a change

- Curated models: `lib/services/local/model_catalog.dart` (pin the revision
  and exact byte sizes from `https://huggingface.co/api/models/<repo>?blobs=true`).
- Default sampling per model: the `SamplingDefaults` in the same file; users
  can override per model in Settings → Model settings.
- Run `flutter test test/local_agent_e2e_test.dart --dart-define=LOCAL_MODEL_DIR=<dir> --dart-define=LOCAL_MODEL_FILE=<file.gguf>` before shipping a change.
