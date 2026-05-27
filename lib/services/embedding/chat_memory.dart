import 'dart:typed_data';

import 'package:flutter/foundation.dart';

import 'embedding_service.dart';

/// One message in the in-memory chat memory index.
class IndexedMessage {
  /// Monotonic per-session sequence (the order remember() was called).
  /// Used to keep chronological ordering stable and to identify "the last
  /// two" without needing db row ids.
  final int seq;
  final String text;
  final bool isUser;
  final DateTime addedAt;

  /// Embedding vector. `null` while [ChatMemory] is still embedding in
  /// the background — recall() will fall back to chronological recency
  /// for unembedded messages so we never block a turn waiting for the
  /// embedding pipeline to catch up.
  Float32List? vec;

  /// Rough token count (chars/4). Used by [ChatMemory.recall] to honor
  /// the token budget. A real tokenizer would be more accurate but this
  /// estimate is within ~15% for short English chat turns and avoids
  /// running the LLM tokenizer just to count.
  final int approxTokens;

  IndexedMessage({
    required this.seq,
    required this.text,
    required this.isUser,
    required this.addedAt,
    this.vec,
  }) : approxTokens = (text.length / 4).ceil().clamp(1, 4096);
}

/// What [ChatMemory.recall] returns — chronologically-ordered messages
/// that fit the requested token budget, plus the total token estimate.
class RecallResult {
  final List<IndexedMessage> messages;
  final int totalTokens;
  const RecallResult(this.messages, this.totalTokens);
}

/// Per-session in-memory index of chat messages with their MiniLM
/// embeddings, used to retrieve only the past turns semantically
/// relevant to the current user query.
///
/// Why this exists: with all-26 tools removed via the budget filter,
/// Qwen 2.5 1.5B's KV cache (1280 tokens) has room for ~600 tokens of
/// past chat. Naive "keep last 6 messages" truncation leaves the model
/// stuck in stale tool failures ("calculator" prompt → echoes "Play
/// Store not found" from two turns ago). Recall-by-relevance instead
/// keeps the *interesting* past, drops the noise.
///
/// In-memory only — rebuilt from db on session load (see
/// AgentService.loadSession). Survives the chat lifetime; cleared per
/// session via [clear].
class ChatMemory {
  static final ChatMemory instance = ChatMemory._();
  ChatMemory._();

  final Map<int, List<IndexedMessage>> _bySession = {};
  final Map<int, int> _seqBySession = {};

  /// Number of messages currently indexed for [sessionId]. Used by
  /// AgentService heuristics (e.g. don't bother recalling if 0).
  int sizeOf(int sessionId) => _bySession[sessionId]?.length ?? 0;

  /// Add a message to the index. Embedding happens in the background;
  /// the message is queryable by recency immediately and by semantic
  /// score as soon as the embedding lands. Fire-and-forget; never throws.
  Future<void> remember(int sessionId, String text, bool isUser) async {
    if (text.trim().isEmpty) return;
    final seq = (_seqBySession[sessionId] ?? 0) + 1;
    _seqBySession[sessionId] = seq;

    final msg = IndexedMessage(
      seq: seq,
      text: text,
      isUser: isUser,
      addedAt: DateTime.now(),
    );
    _bySession.putIfAbsent(sessionId, () => []).add(msg);

    // Embedding is best-effort: failures (model not ready, ORT crash on
    // x86_64 Waydroid, etc.) leave vec=null and recall just treats this
    // message as "recent but not semantically matchable".
    try {
      final svc = EmbeddingService.instance;
      if (!svc.isReady) return;
      final vec = await svc.embed(text);
      if (vec != null) msg.vec = vec;
    } catch (e) {
      debugPrint('[ChatMemory] embed failed for seq=$seq: $e');
    }
  }

  /// Retrieve a chronologically-ordered set of past messages for the
  /// given [query], filling up to [tokenBudget] tokens.
  ///
  /// Algorithm (adaptive):
  ///   1. Always include the last 2 messages (short-term continuity).
  ///   2. Use remaining budget for top-scoring older messages with
  ///      cosine ≥ [minScore]. Messages whose embedding hasn't computed
  ///      yet are eligible by recency only (added if budget allows after
  ///      scored picks).
  ///   3. Return the selected set sorted by original chronological
  ///      sequence — flutter_gemma's replay needs user/assistant turns
  ///      in correct order for the chat template to make sense.
  ///
  /// On any failure (embedding service unavailable, query embed fails)
  /// falls back to recency: returns the most recent messages that fit
  /// the budget. Never throws.
  Future<RecallResult> recall(
    int sessionId,
    String query, {
    int tokenBudget = 600,
    int alwaysKeepLast = 2,
    double minScore = 0.30,
  }) async {
    final all = _bySession[sessionId] ?? const <IndexedMessage>[];
    if (all.isEmpty) return const RecallResult([], 0);

    // Recency floor: the last N messages, regardless of relevance.
    final recencyKeep = all.length <= alwaysKeepLast
        ? List<IndexedMessage>.from(all)
        : all.sublist(all.length - alwaysKeepLast);
    var budget = tokenBudget;
    final selected = <IndexedMessage>{};
    var usedTokens = 0;

    for (final m in recencyKeep) {
      if (m.approxTokens > budget && selected.isNotEmpty) continue;
      selected.add(m);
      usedTokens += m.approxTokens;
      budget -= m.approxTokens;
    }

    // Older candidates = everything we haven't already taken.
    final older = all
        .where((m) => !selected.contains(m))
        .toList();

    if (older.isNotEmpty && budget > 0) {
      Float32List? qVec;
      try {
        if (EmbeddingService.instance.isReady) {
          qVec = await EmbeddingService.instance.embed(query);
        }
      } catch (_) {}

      // Score the embeddable older messages by cosine; the rest get a
      // recency-only fallback score so they can fill remaining budget
      // when relevance scoring isn't available for them.
      final scored = <({IndexedMessage msg, double score})>[];
      for (final m in older) {
        double score;
        if (qVec != null && m.vec != null) {
          score = _dot(qVec, m.vec!);
          if (score < minScore) continue;
        } else {
          // Unembedded fallback: score by recency, normalized to a
          // value below minScore so embedded matches always win.
          score = 0.10 + (m.seq / (_seqBySession[sessionId] ?? 1)) * 0.15;
        }
        scored.add((msg: m, score: score));
      }

      scored.sort((a, b) => b.score.compareTo(a.score));
      for (final s in scored) {
        if (s.msg.approxTokens > budget) continue;
        selected.add(s.msg);
        usedTokens += s.msg.approxTokens;
        budget -= s.msg.approxTokens;
        if (budget <= 0) break;
      }
    }

    final ordered = selected.toList()..sort((a, b) => a.seq.compareTo(b.seq));
    return RecallResult(ordered, usedTokens);
  }

  /// Drop the index for a session — call on session delete/reset, or
  /// before [AgentService.loadSession] rebuilds the index from db so
  /// stale entries from another session don't leak in.
  void clear(int sessionId) {
    _bySession.remove(sessionId);
    _seqBySession.remove(sessionId);
  }

  /// True if any of the last [assistantWindow] assistant messages in this
  /// session look like they captured a tool failure or refusal. Used by
  /// AgentService as a trigger to rebuild the chat with a recall-filtered
  /// history, getting the failure noise out of the live KV cache before
  /// the next turn's prefill.
  ///
  /// Counts assistant messages only (not user turns) — otherwise a quick
  /// "its okay" + "No problem!" exchange would push the failure past a
  /// raw-count window even though it's still load-bearing in the model's
  /// KV cache.
  bool recentlyFailed(int sessionId, {int assistantWindow = 3}) {
    final all = _bySession[sessionId];
    if (all == null || all.isEmpty) return false;
    final markers = [
      'sorry', "couldn't", 'could not', 'not found', 'error',
      "wasn't able", 'unable to', 'failed', "doesn't exist",
    ];
    var seen = 0;
    for (var i = all.length - 1; i >= 0; i--) {
      final m = all[i];
      if (m.isUser) continue;
      seen++;
      final lower = m.text.toLowerCase();
      if (markers.any(lower.contains)) return true;
      if (seen >= assistantWindow) break;
    }
    return false;
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
