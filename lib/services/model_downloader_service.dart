import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:disk_space_2/disk_space_2.dart';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import 'model_registry.dart';

@immutable
class DownloadProgress {
  final String fileName;
  final int receivedBytes;
  final int totalBytes;
  final double bytesPerSecond;

  const DownloadProgress({
    required this.fileName,
    required this.receivedBytes,
    required this.totalBytes,
    required this.bytesPerSecond,
  });

  double get fraction =>
      totalBytes > 0 ? (receivedBytes / totalBytes).clamp(0.0, 1.0) : 0;

  String get speedLabel {
    if (bytesPerSecond <= 0) return 'Starting…';
    final mb = bytesPerSecond / (1024 * 1024);
    return mb >= 1
        ? '${mb.toStringAsFixed(1)} MB/s'
        : '${(bytesPerSecond / 1024).toStringAsFixed(0)} KB/s';
  }

  String get amountLabel {
    String mb(int b) => (b / (1024 * 1024)).toStringAsFixed(0);
    return '${mb(receivedBytes)} / ${mb(totalBytes)} MB';
  }
}

/// Downloads model files with resume support.
///
/// Lives as a singleton with a [progress] notifier so a download keeps going
/// — and the UI can re-attach to it — when the user leaves the screen.
class ModelDownloaderService {
  static final ModelDownloaderService _instance = ModelDownloaderService._internal();
  factory ModelDownloaderService() => _instance;
  ModelDownloaderService._internal();

  final Dio _dio = Dio(BaseOptions(
    connectTimeout: const Duration(seconds: 30),
    // A stalled connection errors out instead of hanging forever; the
    // download resumes from the partial file.
    receiveTimeout: const Duration(seconds: 60),
  ));
  CancelToken? _cancelToken;

  /// Current download, or null when idle.
  final ValueNotifier<DownloadProgress?> progress = ValueNotifier(null);

  bool get isDownloading => progress.value != null;

  Future<String> getModelsDirectory() async {
    final directory = await getApplicationDocumentsDirectory();
    final modelsDir = Directory('${directory.path}/models');
    if (!await modelsDir.exists()) {
      await modelsDir.create(recursive: true);
    }
    return modelsDir.path;
  }

  Future<String> pathFor(String fileName) async =>
      '${await getModelsDirectory()}/$fileName';

  Future<bool> isModelDownloaded(String fileName) async =>
      File(await pathFor(fileName)).exists();

  Future<bool> hasPartialDownload(String fileName) async =>
      File('${await pathFor(fileName)}.part').exists();

  Future<List<ModelSpec>> downloadedModels() async {
    final out = <ModelSpec>[];
    for (final spec in ModelRegistry.all) {
      if (await isModelDownloaded(spec.fileName)) out.add(spec);
    }
    return out;
  }

  void cancelDownload() {
    _cancelToken?.cancel('Download paused.');
  }

  /// Downloads [spec]. Resolves when the file is complete and verified;
  /// throws a user-readable [String] on failure. Safe to call again to resume.
  Future<void> download(ModelSpec spec) async {
    if (isDownloading) throw 'Another download is already running.';
    final filePath = await pathFor(spec.fileName);
    final partFile = File('$filePath.part');
    var received = await partFile.exists() ? await partFile.length() : 0;
    if (received > spec.sizeBytes) {
      await partFile.delete();
      received = 0;
    }

    // Refuse up front instead of failing at 90% with a full disk.
    try {
      final freeMB = await DiskSpace.getFreeDiskSpace;
      final neededMB = (spec.sizeBytes - received) / (1024 * 1024) + 300;
      if (freeMB != null && freeMB < neededMB) {
        throw 'Not enough storage: ${spec.displayName} needs '
            '${(neededMB / 1024).toStringAsFixed(1)} GB free, you have '
            '${(freeMB / 1024).toStringAsFixed(1)} GB.';
      }
    } on String {
      rethrow;
    } catch (_) {
      // Couldn't read free space; try anyway.
    }

    final cancelToken = _cancelToken = CancelToken();
    progress.value = DownloadProgress(
      fileName: spec.fileName,
      receivedBytes: received,
      totalBytes: spec.sizeBytes,
      bytesPerSecond: 0,
    );

    RandomAccessFile? raf;
    try {
      final response = await _dio.get<ResponseBody>(
        spec.url,
        options: Options(
          responseType: ResponseType.stream,
          headers: received > 0 ? {'range': 'bytes=$received-'} : null,
        ),
        cancelToken: cancelToken,
      );
      final resumed = response.statusCode == 206;
      if (!resumed) received = 0; // server ignored the range: start over
      raf = await partFile.open(mode: resumed ? FileMode.append : FileMode.write);

      var lastTick = DateTime.now();
      var bytesSinceTick = 0;
      await for (final chunk in response.data!.stream) {
        await raf.writeFrom(chunk);
        received += chunk.length;
        bytesSinceTick += chunk.length;
        final now = DateTime.now();
        final elapsed = now.difference(lastTick).inMilliseconds;
        if (elapsed >= 500) {
          progress.value = DownloadProgress(
            fileName: spec.fileName,
            receivedBytes: received,
            totalBytes: spec.sizeBytes,
            bytesPerSecond: bytesSinceTick * 1000 / elapsed,
          );
          lastTick = now;
          bytesSinceTick = 0;
        }
      }
      await raf.close();
      raf = null;

      final actual = await partFile.length();
      if (actual != spec.sizeBytes) {
        if (actual > spec.sizeBytes) await partFile.delete();
        throw 'Download incomplete (${(actual / (1024 * 1024)).round()} of '
            '${(spec.sizeBytes / (1024 * 1024)).round()} MB). Tap Resume to continue.';
      }
      await partFile.rename(filePath);
    } on DioException catch (e) {
      if (CancelToken.isCancel(e)) throw 'Download paused.';
      final status = e.response?.statusCode;
      if (status == 401 || status == 403) {
        throw 'The model host refused the download (HTTP $status).';
      }
      if (status == 416) {
        // Range not satisfiable: partial file is stale.
        if (await partFile.exists()) await partFile.delete();
        throw 'The partial download was out of date. Tap Download to start again.';
      }
      if (e.type == DioExceptionType.connectionTimeout ||
          e.type == DioExceptionType.receiveTimeout) {
        throw 'The connection stalled. Tap Resume to continue.';
      }
      if (e.type == DioExceptionType.badResponse) {
        throw 'Server error (HTTP $status). Try again later.';
      }
      throw 'Network error. Tap Resume to continue.';
    } on FileSystemException catch (e) {
      throw 'Couldn\'t write the model file: ${e.osError?.message ?? e.message}';
    } finally {
      await raf?.close();
      progress.value = null;
      if (identical(_cancelToken, cancelToken)) _cancelToken = null;
    }
  }

  Future<void> deleteModel(String fileName) async {
    final path = await pathFor(fileName);
    for (final f in [File(path), File('$path.part')]) {
      if (await f.exists()) await f.delete();
    }
  }
}
