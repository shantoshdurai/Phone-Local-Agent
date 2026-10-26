import 'dart:ffi';
import 'dart:io';
import 'package:ffi/ffi.dart';

// Native C Signatures
typedef NeedleLoadC = Int32 Function(Pointer<Uint8> cact, Uint64 n);
typedef NeedleLoadDart = int Function(Pointer<Uint8> cact, int n);

typedef NeedleInitC = Int32 Function(
    Pointer<Utf8> systemPrompt, Pointer<Utf8> toolsJson, Pointer<Utf8> toolIndexPath);
typedef NeedleInitDart = int Function(
    Pointer<Utf8> systemPrompt, Pointer<Utf8> toolsJson, Pointer<Utf8> toolIndexPath);

typedef NeedleCompleteC = Int32 Function(
    Pointer<Utf8> input,
    Pointer<Float> pcm,
    Int32 samples,
    Int32 maxNewTokens,
    Pointer<Uint8> out,
    Int32 outCapacity);
typedef NeedleCompleteDart = int Function(
    Pointer<Utf8> input,
    Pointer<Float> pcm,
    int samples,
    int maxNewTokens,
    Pointer<Uint8> out,
    int outCapacity);

typedef NeedleEmbedC = Int32 Function(
    Pointer<Utf8> input,
    Pointer<Float> pcm,
    Int32 samples,
    Pointer<Float> out,
    Int32 outCapacity);
typedef NeedleEmbedDart = int Function(
    Pointer<Utf8> input,
    Pointer<Float> pcm,
    int samples,
    Pointer<Float> out,
    int outCapacity);

typedef NeedleTranscribeC = Int32 Function(
    Pointer<Float> pcm,
    Int32 samples,
    Pointer<Utf8> language,
    Pointer<Utf8> keywords,
    Int32 wordTimestamps,
    Pointer<Uint8> out,
    Int32 outCapacity);
typedef NeedleTranscribeDart = int Function(
    Pointer<Float> pcm,
    int samples,
    Pointer<Utf8> language,
    Pointer<Utf8> keywords,
    int wordTimestamps,
    Pointer<Uint8> out,
    int outCapacity);

typedef NeedleLastErrorC = Pointer<Utf8> Function();
typedef NeedleLastErrorDart = Pointer<Utf8> Function();

typedef NeedleResetC = Void Function();
typedef NeedleResetDart = void Function();

typedef NeedleModelsC = Int32 Function();
typedef NeedleModelsDart = int Function();

class NeedleBindings {
  final DynamicLibrary _dylib;

  late final NeedleLoadDart needleLoad;
  late final NeedleInitDart needleInit;
  late final NeedleCompleteDart needleComplete;
  late final NeedleEmbedDart needleEmbed;
  late final NeedleTranscribeDart needleTranscribe;
  late final NeedleLastErrorDart needleLastError;
  late final NeedleResetDart needleReset;
  late final NeedleModelsDart needleModels;

  NeedleBindings(this._dylib) {
    needleLoad = _dylib.lookupFunction<NeedleLoadC, NeedleLoadDart>('needle_load');
    needleInit = _dylib.lookupFunction<NeedleInitC, NeedleInitDart>('needle_init');
    needleComplete =
        _dylib.lookupFunction<NeedleCompleteC, NeedleCompleteDart>('needle_complete');
    needleEmbed = _dylib.lookupFunction<NeedleEmbedC, NeedleEmbedDart>('needle_embed');
    needleTranscribe =
        _dylib.lookupFunction<NeedleTranscribeC, NeedleTranscribeDart>('needle_transcribe');
    needleLastError =
        _dylib.lookupFunction<NeedleLastErrorC, NeedleLastErrorDart>('needle_last_error');
    needleReset = _dylib.lookupFunction<NeedleResetC, NeedleResetDart>('needle_reset');
    needleModels = _dylib.lookupFunction<NeedleModelsC, NeedleModelsDart>('needle_models');
  }

  static DynamicLibrary openLibrary() {
    if (Platform.isAndroid) {
      return DynamicLibrary.open('libneedle.so');
    } else if (Platform.isWindows) {
      // Look for local DLL in common paths
      final candidates = [
        r'C:\Users\Dog\AppData\Local\Programs\Python\Python311\Lib\site-packages\needle\libneedle3.dll',
        'libneedle3.dll',
      ];
      for (final p in candidates) {
        if (File(p).existsSync()) {
          return DynamicLibrary.open(p);
        }
      }
      return DynamicLibrary.open('libneedle3.dll');
    } else if (Platform.isLinux) {
      return DynamicLibrary.open('libneedle.so');
    } else if (Platform.isMacOS) {
      return DynamicLibrary.open('libneedle.dylib');
    }
    throw UnsupportedError('Unsupported platform for Needle');
  }
}
