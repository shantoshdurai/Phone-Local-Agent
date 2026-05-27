import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:onnxruntime/onnxruntime.dart';
import 'package:path_provider/path_provider.dart';

import 'bert_tokenizer.dart';

/// On-device sentence embeddings using `all-MiniLM-L6-v2` (384-dim).
///
/// Flow:
///   1. `ensureReady()` downloads model + vocab on first run into
///      ApplicationDocumentsDirectory/models/embeddings/, loads them, and
///      caches the OrtSession + tokenizer for the lifetime of the app.
///   2. `embed(text)` tokenizes, runs the ONNX session, mean-pools
///      last_hidden_state with attention-mask weighting (the canonical
///      sentence-transformers recipe), L2-normalizes, returns Float32List(384).
///
/// Failure mode: every step is wrapped in try/catch. On any failure
/// (download, ORT init, missing input/output names, dtype mismatch) the
/// service flips `disabled = true` and `embed` returns null. ToolIndex then
/// falls back to a no-RAG path so the agent still works.
class EmbeddingService {
  static final EmbeddingService instance = EmbeddingService._();
  EmbeddingService._();

  // sentence-transformers/all-MiniLM-L6-v2 — the standard, well-tested
  // ONNX export. Output is `last_hidden_state` with shape [batch, seq, 384].
  // We mean-pool externally.
  //
  // The model + vocab are shipped as bundled Flutter assets (see
  // pubspec.yaml `flutter.assets`) and extracted to ApplicationDocuments
  // on first launch so ONNX Runtime can mmap the model via File. No
  // network is ever touched — fully offline from install.
  //
  // To regenerate the assets see assets/embeddings/README.md.
  static const String _modelAsset = 'assets/embeddings/minilm-l6-v2.onnx';
  static const String _vocabAsset = 'assets/embeddings/vocab.txt';
  static const String _modelFileName = 'minilm-l6-v2.onnx';
  static const String _vocabFileName = 'minilm-l6-v2.vocab.txt';
  static const int _embeddingDim = 384;
  static const int _maxSeqLen = 128;

  OrtSession? _session;
  BertTokenizer? _tokenizer;
  bool _ortEnvReady = false;
  bool _initInFlight = false;
  Future<void>? _initFuture;

  /// True once initialization permanently failed. Read by callers that
  /// want to short-circuit RAG rather than retry every turn.
  bool disabled = false;

  /// True once both session + tokenizer are loaded and ready to embed.
  bool get isReady => _session != null && _tokenizer != null && !disabled;

  /// Dimensionality of returned embedding vectors. 384 for MiniLM-L6.
  int get embeddingDim => _embeddingDim;

  /// Kick off (or join an in-flight) init: download files if missing, init
  /// the ORT environment, load the session + tokenizer. Safe to call
  /// repeatedly from anywhere — idempotent.
  Future<void> ensureReady() {
    if (isReady) return Future.value();
    if (disabled) return Future.value();
    if (_initInFlight) return _initFuture!;
    _initInFlight = true;
    _initFuture = _init().whenComplete(() {
      _initInFlight = false;
    });
    return _initFuture!;
  }

  Future<void> _init() async {
    try {
      final dir = await _embeddingsDir();
      final modelFile = File('${dir.path}/$_modelFileName');
      final vocabFile = File('${dir.path}/$_vocabFileName');

      // Extract from bundled assets to app-internal storage on first launch.
      // ONNX Runtime needs a real File path (it mmaps the model), and so does
      // BertTokenizer.loadFromFile, so we can't load straight from rootBundle.
      // Subsequent launches see the file already present and skip the copy.
      if (!await modelFile.exists()) {
        debugPrint('[EmbeddingService] extracting $_modelAsset');
        await _extractAsset(_modelAsset, modelFile);
      }
      if (!await vocabFile.exists()) {
        debugPrint('[EmbeddingService] extracting $_vocabAsset');
        await _extractAsset(_vocabAsset, vocabFile);
      }

      if (!_ortEnvReady) {
        OrtEnv.instance.init();
        _ortEnvReady = true;
      }

      final opts = OrtSessionOptions()
        ..setInterOpNumThreads(1)
        ..setIntraOpNumThreads(2)
        ..setSessionGraphOptimizationLevel(GraphOptimizationLevel.ortEnableAll);

      _session = OrtSession.fromFile(modelFile, opts);
      _tokenizer = await BertTokenizer.loadFromFile(
        vocabFile.path,
        maxSeqLen: _maxSeqLen,
      );

      debugPrint('[EmbeddingService] ready — embeddingDim=$_embeddingDim');
    } catch (e, st) {
      disabled = true;
      _session = null;
      _tokenizer = null;
      debugPrint('[EmbeddingService] init failed, RAG disabled: $e\n$st');
    }
  }

  Future<Directory> _embeddingsDir() async {
    final docs = await getApplicationDocumentsDirectory();
    final d = Directory('${docs.path}/models/embeddings');
    if (!await d.exists()) await d.create(recursive: true);
    return d;
  }

  /// Copy a bundled asset out of the APK and into a real on-disk file the
  /// native ORT runtime can mmap. Written via a `.part` rename so a kill
  /// mid-extract can't leave a half-written model file that we'd later try
  /// to load and fail on.
  Future<void> _extractAsset(String assetKey, File dest) async {
    final bytes = await rootBundle.load(assetKey);
    final tmp = File('${dest.path}.part');
    if (await tmp.exists()) await tmp.delete();
    await tmp.writeAsBytes(
      bytes.buffer.asUint8List(bytes.offsetInBytes, bytes.lengthInBytes),
      flush: true,
    );
    await tmp.rename(dest.path);
  }

  /// Embed a single text. Returns null if the service isn't ready or any
  /// step throws — callers should treat null as "skip RAG this turn".
  Future<Float32List?> embed(String text) async {
    if (!isReady) return null;
    final tok = _tokenizer!.encode(text);

    // ONNX expects int64 for BERT-family models. The onnxruntime Flutter
    // package accepts Int64List directly and marshals it across the FFI
    // boundary. Shape: [batch=1, seq_len].
    final seq = tok.inputIds.length;
    final ids = Int64List.fromList(tok.inputIds);
    final mask = Int64List.fromList(tok.attentionMask);
    final types = Int64List.fromList(tok.tokenTypeIds);

    OrtValueTensor? idsT;
    OrtValueTensor? maskT;
    OrtValueTensor? typesT;
    List<OrtValue?>? outputs;
    try {
      idsT = OrtValueTensor.createTensorWithDataList(ids, [1, seq]);
      maskT = OrtValueTensor.createTensorWithDataList(mask, [1, seq]);
      typesT = OrtValueTensor.createTensorWithDataList(types, [1, seq]);

      final inputs = <String, OrtValue>{
        'input_ids': idsT,
        'attention_mask': maskT,
        'token_type_ids': typesT,
      };

      outputs = await _session!.runAsync(OrtRunOptions(), inputs);
      if (outputs == null || outputs.isEmpty || outputs.first == null) {
        return null;
      }

      // sentence-transformers/all-MiniLM-L6-v2 has one output:
      // `last_hidden_state` of shape [1, seq_len, 384]. The package returns
      // it as nested List<List<List<double>>>.
      final raw = outputs.first!.value;
      final hidden = _toFloat3D(raw);
      if (hidden == null) return null;

      return _meanPoolAndNormalize(hidden, tok.attentionMask);
    } catch (e, st) {
      debugPrint('[EmbeddingService] embed failed: $e\n$st');
      return null;
    } finally {
      idsT?.release();
      maskT?.release();
      typesT?.release();
      if (outputs != null) {
        for (final o in outputs) {
          o?.release();
        }
      }
    }
  }

  /// Mean-pool over seq dim using the attention mask as weights, then L2-norm.
  /// This is the standard sentence-transformers MiniLM recipe — using [CLS]
  /// alone gives noticeably worse retrieval on short text.
  Float32List _meanPoolAndNormalize(
      List<List<List<double>>> hidden, List<int> mask) {
    final seq = hidden[0].length;
    final dim = hidden[0][0].length;
    final pooled = Float32List(dim);

    var maskSum = 0;
    for (var t = 0; t < seq; t++) {
      if (mask[t] == 0) continue;
      maskSum += 1;
      final row = hidden[0][t];
      for (var d = 0; d < dim; d++) {
        pooled[d] += row[d];
      }
    }
    if (maskSum == 0) return pooled;
    final inv = 1.0 / maskSum;
    for (var d = 0; d < dim; d++) {
      pooled[d] *= inv;
    }

    var norm = 0.0;
    for (var d = 0; d < dim; d++) {
      norm += pooled[d] * pooled[d];
    }
    norm = math.sqrt(norm);
    if (norm > 0) {
      final invN = 1.0 / norm;
      for (var d = 0; d < dim; d++) {
        pooled[d] *= invN;
      }
    }
    return pooled;
  }

  /// Coerce the package's loosely-typed `dynamic` output into a strict
  /// 3D float list. Returns null on any shape/type mismatch.
  List<List<List<double>>>? _toFloat3D(dynamic raw) {
    if (raw is! List) return null;
    final batch = <List<List<double>>>[];
    for (final b in raw) {
      if (b is! List) return null;
      final seq = <List<double>>[];
      for (final t in b) {
        if (t is! List) return null;
        final row = <double>[];
        for (final v in t) {
          if (v is num) {
            row.add(v.toDouble());
          } else {
            return null;
          }
        }
        seq.add(row);
      }
      batch.add(seq);
    }
    return batch;
  }
}
