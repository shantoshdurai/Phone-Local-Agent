import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show rootBundle;

import '../tool_runtime.dart';
import 'needle_bindings.dart';

/// Service wrapping the ultra-compact Cactus Needle 3 on-device engine.
///
/// Features:
/// - Instant 3,072-dim text embedding for RAG memory and tool index.
/// - Offline grammar-constrained tool calling (~700 tok/s prefill, 80-110 MB RAM).
/// - Whistle speech-to-text integration if whistle.cact is loaded.
class NeedleService {
  static final NeedleService instance = NeedleService._();
  NeedleService._();

  NeedleBindings? _bindings;
  bool _ready = false;
  bool _loading = false;
  String? _lastError;

  bool get isReady => _ready;
  String? get lastError => _lastError;

  Pointer<Uint8>? _pModelBytes;
  int _modelByteLength = 0;

  /// Load Needle 3 and initialize tool catalogue.
  Future<bool> ensureReady() async {
    if (_ready) return true;
    if (_loading) return false;
    _loading = true;

    try {
      final dylib = NeedleBindings.openLibrary();
      _bindings = NeedleBindings(dylib);

      // Load model weights from asset or documents cache
      final modelBytes = await _loadAssetBytes('assets/models/needle3.cact');
      if (modelBytes == null || modelBytes.isEmpty) {
        _lastError = 'needle3.cact model file not found';
        _loading = false;
        return false;
      }

      _modelByteLength = modelBytes.length;
      _pModelBytes = calloc<Uint8>(_modelByteLength);
      _pModelBytes!.asTypedList(_modelByteLength).setAll(0, modelBytes);

      final loadRet = _bindings!.needleLoad(_pModelBytes!, _modelByteLength);
      if (loadRet < 0) {
        _lastError = _bindings!.needleLastError().cast<Utf8>().toDartString();
        _loading = false;
        return false;
      }

      // Check if whistle.cact (speech) exists
      try {
        final whistleBytes = await _loadAssetBytes('assets/models/whistle.cact');
        if (whistleBytes != null && whistleBytes.isNotEmpty) {
          final pWhistle = calloc<Uint8>(whistleBytes.length);
          pWhistle.asTypedList(whistleBytes.length).setAll(0, whistleBytes);
          _bindings!.needleLoad(pWhistle, whistleBytes.length);
          calloc.free(pWhistle);
        }
      } catch (_) {
        // Speech model optional
      }

      // Initialize tool catalogue
      final toolsJson = _buildToolsJson();
      final pSystem = 'You are an intelligent phone assistant.'.toNativeUtf8();
      final pTools = toolsJson.toNativeUtf8();

      final initRet = _bindings!.needleInit(pSystem, pTools, nullptr);
      calloc.free(pSystem);
      calloc.free(pTools);

      if (initRet < 0) {
        _lastError = _bindings!.needleLastError().cast<Utf8>().toDartString();
        _loading = false;
        return false;
      }

      _ready = true;
      _loading = false;
      debugPrint('NeedleService: ready (prefix tokens: $initRet)');
      return true;
    } catch (e, st) {
      _lastError = e.toString();
      _loading = false;
      debugPrint('NeedleService init error: $e\n$st');
      return false;
    }
  }

  /// Generate 3,072-dimensional vector embedding for text.
  Float32List? embed(String text) {
    if (!_ready || _bindings == null) return null;
    try {
      final pInput = text.trim().toNativeUtf8();
      final dim = _bindings!.needleEmbed(pInput, nullptr, 0, nullptr, 0);
      if (dim <= 0) {
        calloc.free(pInput);
        return null;
      }

      final pOut = calloc<Float>(dim);
      final actualDim = _bindings!.needleEmbed(pInput, nullptr, 0, pOut, dim);
      calloc.free(pInput);

      if (actualDim <= 0) {
        calloc.free(pOut);
        return null;
      }

      final result = Float32List.fromList(pOut.asTypedList(actualDim));
      calloc.free(pOut);
      return result;
    } catch (e) {
      debugPrint('NeedleService embed error: $e');
      return null;
    }
  }

  /// Run prompt through Needle 3 for on-device tool calling.
  Future<Map<String, dynamic>?> complete(String prompt, {int maxTokens = 512}) async {
    if (!_ready || _bindings == null) {
      final ok = await ensureReady();
      if (!ok || _bindings == null) return null;
    }

    try {
      final pPrompt = prompt.trim().toNativeUtf8();
      const outCap = 8192;
      final pOut = calloc<Uint8>(outCap);

      final code = _bindings!.needleComplete(
        pPrompt,
        nullptr,
        0,
        maxTokens,
        pOut,
        outCap,
      );
      calloc.free(pPrompt);

      if (code < 0) {
        final err = _bindings!.needleLastError().cast<Utf8>().toDartString();
        calloc.free(pOut);
        return {'error': err, 'code': code};
      }

      final jsonStr = pOut.cast<Utf8>().toDartString();
      calloc.free(pOut);

      return jsonDecode(jsonStr) as Map<String, dynamic>;
    } catch (e) {
      debugPrint('NeedleService complete error: $e');
      return {'error': e.toString()};
    }
  }

  /// Reset the conversation context in the C engine.
  void reset() {
    if (_bindings != null) {
      _bindings!.needleReset();
    }
  }

  void dispose() {
    if (_pModelBytes != null) {
      calloc.free(_pModelBytes!);
      _pModelBytes = null;
    }
    _ready = false;
  }

  String _buildToolsJson() {
    // Return clean JSON array from kToolCatalog
    final list = <Map<String, dynamic>>[];
    for (final t in kToolCatalog) {
      list.add({
        'name': t['name'],
        'description': t['description'],
        'parameters': t['parameters'] ?? {'type': 'object', 'properties': {}},
      });
    }
    return jsonEncode(list);
  }

  Future<Uint8List?> _loadAssetBytes(String assetPath) async {
    try {
      final data = await rootBundle.load(assetPath);
      return data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
    } catch (_) {
      // Fallback: check file system if running in test / standalone
      final f = File(assetPath);
      if (f.existsSync()) {
        return f.readAsBytesSync();
      }
      return null;
    }
  }
}
