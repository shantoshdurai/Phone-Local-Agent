import 'dart:typed_data';

import 'package:flutter/foundation.dart';

import 'embedding_service.dart';
import 'tool_docs.dart';

/// A single entry in the in-memory vector index: tool name + its embedding.
class _IndexedTool {
  final String name;
  final Float32List vec;
  _IndexedTool(this.name, this.vec);
}

/// In-memory vector index over [kToolDocs]. After [build] resolves, each
/// turn calls [retrieveTopK] to get the most relevant tool names for the
/// user's query, which AgentService injects as a hint into the prompt.
///
/// Index size is trivially small (~26 tools × 384 floats × 4 bytes ≈ 40 KB
/// RAM), so we keep everything as flat Float32Lists and scan linearly. No
/// ANN index needed at this scale; cosine over 26 entries is a few hundred
/// FLOPs and is nowhere near the bottleneck (embedding the query is).
///
/// Falls back gracefully: if EmbeddingService is disabled or [build]
/// hasn't completed yet, [retrieveTopK] returns an empty list and the
/// agent prompts the model with no hint — same behavior as pre-RAG.
class ToolIndex {
  static final ToolIndex instance = ToolIndex._();
  ToolIndex._();

  final List<_IndexedTool> _entries = [];
  bool _buildInFlight = false;
  Future<void>? _buildFuture;
  bool _ready = false;

  /// True once every tool doc has been embedded and we can serve queries.
  bool get isReady => _ready;

  /// Async-build the index. Idempotent — concurrent callers share the same
  /// future. Cheap to call from app init in parallel with the LLM warmup.
  ///
  /// Step 1: ensure EmbeddingService is ready (which downloads MiniLM +
  /// vocab on first run — can take 10–60s depending on network).
  /// Step 2: embed each doc sequentially. Sequential because each ONNX
  /// run holds the same session; parallelism would just queue inside ORT.
  Future<void> build() {
    if (_ready) return Future.value();
    if (_buildInFlight) return _buildFuture!;
    _buildInFlight = true;
    _buildFuture = _build().whenComplete(() {
      _buildInFlight = false;
    });
    return _buildFuture!;
  }

  Future<void> _build() async {
    try {
      final svc = EmbeddingService.instance;
      await svc.ensureReady();
      if (!svc.isReady) {
        debugPrint(
            '[ToolIndex] EmbeddingService unavailable, RAG retrieval disabled');
        return;
      }

      _entries.clear();
      for (final doc in kToolDocs) {
        final vec = await svc.embed(doc.embedText);
        if (vec == null) {
          debugPrint('[ToolIndex] failed to embed ${doc.name} — skipping');
          continue;
        }
        _entries.add(_IndexedTool(doc.name, vec));
      }
      _ready = _entries.isNotEmpty;
      debugPrint('[ToolIndex] built — ${_entries.length} tool embeddings');
    } catch (e, st) {
      debugPrint('[ToolIndex] build failed: $e\n$st');
    }
  }

  /// Return the top-K most relevant tool names for [query] by cosine
  /// similarity, filtered by a minimum score so we don't push obviously-
  /// unrelated tools at the model. Empty list when the index isn't ready
  /// or no tool clears the floor.
  Future<List<String>> retrieveTopK(
    String query, {
    int k = 3,
    double minScore = 0.25,
  }) async {
    if (!_ready) return const [];
    final qVec = await EmbeddingService.instance.embed(query);
    if (qVec == null) return const [];

    // Both vectors are pre-L2-normalized → cosine == dot product.
    final scored = <(double, String)>[];
    for (final e in _entries) {
      final s = _dot(qVec, e.vec);
      scored.add((s, e.name));
    }
    scored.sort((a, b) => b.$1.compareTo(a.$1));
    return scored
        .where((s) => s.$1 >= minScore)
        .take(k)
        .map((s) => s.$2)
        .toList();
  }

  double _dot(Float32List a, Float32List b) {
    final n = a.length < b.length ? a.length : b.length;
    var s = 0.0;
    for (var i = 0; i < n; i++) {
      s += a[i] * b[i];
    }
    return s;
  }
}
