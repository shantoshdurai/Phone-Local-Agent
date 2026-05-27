# Embedding assets for on-device RAG

The on-device RAG tool retriever (see `lib/services/embedding/`) uses
`sentence-transformers/all-MiniLM-L6-v2` for sentence embeddings. Both
files below must be present in this directory before `flutter build` —
they are bundled into the APK and extracted to app storage on first launch
so the app works fully offline from install (zero network calls for RAG).

## Files required in this directory

| File | Size | Source |
|------|------|--------|
| `minilm-l6-v2.onnx` | ~90 MB (unquantized) **or** ~23 MB (quantized) | HuggingFace |
| `vocab.txt`         | ~230 KB | HuggingFace |

## How to fetch

Run these once from the repo root (requires `curl`):

```bash
mkdir -p assets/embeddings

# Quantized model (recommended — 4x smaller APK, ~1% retrieval quality loss).
# We use Xenova's mirror because sentence-transformers' own repo doesn't ship
# the standard quantized ONNX export; their `onnx/` dir only has the full
# `model.onnx` (~90MB) and an AVX512-specific quant variant.
curl -L -o assets/embeddings/minilm-l6-v2.onnx \
  https://huggingface.co/Xenova/all-MiniLM-L6-v2/resolve/main/onnx/model_quantized.onnx

# Or, full-precision model (better quality, much bigger APK):
# curl -L -o assets/embeddings/minilm-l6-v2.onnx \
#   https://huggingface.co/sentence-transformers/all-MiniLM-L6-v2/resolve/main/onnx/model.onnx

curl -L -o assets/embeddings/vocab.txt \
  https://huggingface.co/Xenova/all-MiniLM-L6-v2/resolve/main/vocab.txt
```

Verify after download:

```bash
ls -lh assets/embeddings/
# minilm-l6-v2.onnx   ~23M (quantized) or ~90M (full)
# vocab.txt           ~230K
```

## Why these specific files

- **MiniLM-L6-v2** has 384-dim embeddings, runs in <100 ms on a mid-range
  phone CPU, and is the canonical small sentence-transformer used across
  the open-source RAG ecosystem. Quality is plenty for 26-tool retrieval.
- **vocab.txt** is the bert-base-uncased WordPiece vocabulary that MiniLM
  was trained against. `BertTokenizer` (in `lib/services/embedding/`) is
  a pure-Dart port of HF's reference tokenizer for that exact vocab —
  swapping in a different vocab will silently break tokenization.

## Do not commit these to git

They're large binaries that belong in CI/release tooling, not version
control. The recommended pattern:

1. Add `assets/embeddings/*.onnx` and `assets/embeddings/*.txt` to
   `.gitignore` (keep this README tracked).
2. Make the `curl` block above part of your build script / CI bootstrap.

## What happens if these files are missing

The Flutter build will fail with an asset-not-found error. If somehow
the app launches without them, `EmbeddingService.ensureReady()` will
catch the asset-load exception, flip `disabled = true`, and the agent
will run without RAG hints — the base function-call fix still works.
