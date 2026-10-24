import 'dart:io';

import 'package:disk_space_2/disk_space_2.dart';
import 'package:dio/dio.dart';
import 'package:path_provider/path_provider.dart';

/// Raised when a download cannot start or finish safely. The message is
/// user-facing; the UI shows it verbatim.
class ModelDownloadException implements Exception {
  final String message;
  const ModelDownloadException(this.message);
  @override
  String toString() => message;
}

class ModelDownloaderService {
  static final ModelDownloaderService _instance =
      ModelDownloaderService._internal();
  factory ModelDownloaderService() => _instance;
  ModelDownloaderService._internal();

  final Dio _dio = Dio(BaseOptions(
    connectTimeout: const Duration(seconds: 20),
    // Large model files legitimately take minutes; the socket read timeout
    // still catches a dead connection because it resets on every chunk.
    receiveTimeout: const Duration(seconds: 60),
    followRedirects: true,
    maxRedirects: 8,
  ));

  CancelToken? _cancelToken;
  bool get isDownloading => _cancelToken != null && !_cancelToken!.isCancelled;

  Future<String> getModelsDirectory() async {
    final directory = await getApplicationDocumentsDirectory();
    final modelsDir = Directory('${directory.path}/models');
    if (!await modelsDir.exists()) {
      await modelsDir.create(recursive: true);
    }
    return modelsDir.path;
  }

  Future<bool> isModelDownloaded(String fileName) async {
    final dir = await getModelsDirectory();
    final file = File('$dir/$fileName');
    if (!await file.exists()) return false;
    // A zero-byte file is a failed install, not a model.
    return await file.length() > 0;
  }

  /// Bytes already fetched into the `.part` file, for a resume affordance.
  Future<int> partialBytes(String fileName) async {
    final dir = await getModelsDirectory();
    final f = File('$dir/$fileName.part');
    return await f.exists() ? f.length() : 0;
  }

  void cancelDownload() {
    _cancelToken?.cancel('Download cancelled by user.');
    _cancelToken = null;
  }

  /// Download to `<name>.part` and only publish the final file once the byte
  /// count is verified.
  ///
  /// Why the strictness: the previous implementation renamed the temp file on
  /// any non-cancelled exit, so a connection that dropped at 60% produced a
  /// "successfully downloaded" model that crashed the engine on load, with no
  /// way for the user to tell what happened.
  Future<void> downloadModel({
    required String url,
    required String fileName,
    required int expectedSizeMB,
    required void Function(
            double progress, String speed, String downloaded, String total)
        onProgress,
    required void Function() onComplete,
    required void Function(String error) onError,
  }) async {
    RandomAccessFile? raf;
    try {
      final dir = await getModelsDirectory();
      final filePath = '$dir/$fileName';
      final tempFile = File('$filePath.part');

      // 12% headroom over the model size: enough for the .part file plus the
      // rename, so we never fail at 99% with a full disk.
      final requiredMB = (expectedSizeMB * 1.12).round();
      final freeMB = await _freeDiskMB();
      if (freeMB != null && freeMB < requiredMB) {
        onError(
            'Not enough free storage. This model needs about '
            '${_fmtMB(requiredMB)}, and you have ${_fmtMB(freeMB.round())}.');
        return;
      }

      var downloadedBytes = await tempFile.exists() ? await tempFile.length() : 0;

      _cancelToken = CancelToken();
      final token = _cancelToken!;

      final response = await _dio.get<ResponseBody>(
        url,
        options: Options(
          responseType: ResponseType.stream,
          headers: downloadedBytes > 0
              ? {'Range': 'bytes=$downloadedBytes-'}
              : null,
        ),
        cancelToken: token,
      );

      final status = response.statusCode ?? 0;
      if (status != 200 && status != 206) {
        onError('Download failed (HTTP $status). Try again in a moment.');
        return;
      }

      // If we asked for a range but the server ignored it, restart cleanly
      // instead of appending a second copy of the model.
      if (downloadedBytes > 0 && status == 200) {
        downloadedBytes = 0;
        if (await tempFile.exists()) await tempFile.delete();
      }

      final contentLength = int.tryParse(
          response.headers.value(Headers.contentLengthHeader) ?? '');
      final totalBytes =
          contentLength == null ? -1 : contentLength + downloadedBytes;

      raf = await tempFile.open(
          mode: downloadedBytes > 0 ? FileMode.append : FileMode.write);

      final stream = response.data!.stream;
      var lastReport = DateTime.fromMillisecondsSinceEpoch(0);
      var lastBytes = downloadedBytes;

      await for (final chunk in stream) {
        if (token.isCancelled) break;
        await raf.writeFrom(chunk);
        downloadedBytes += chunk.length;

        final now = DateTime.now();
        if (now.difference(lastReport).inMilliseconds > 160) {
          final elapsedMs =
              now.difference(lastReport).inMilliseconds.clamp(1, 100000);
          final bps = ((downloadedBytes - lastBytes) / elapsedMs) * 1000;
          final progress = totalBytes > 0
              ? (downloadedBytes / totalBytes).clamp(0.0, 1.0)
              : 0.0;
          onProgress(
            progress,
            _fmtSpeed(bps),
            _fmtMB(downloadedBytes / (1024 * 1024)),
            totalBytes > 0 ? _fmtMB(totalBytes / (1024 * 1024)) : '?',
          );
          lastReport = now;
          lastBytes = downloadedBytes;
        }
      }

      await raf.close();
      raf = null;

      if (token.isCancelled) {
        onError('Download paused. You can resume it later.');
        return;
      }

      // Integrity gate. This is the difference between "the download finished"
      // and "a model we can actually load".
      final finalLength = await tempFile.length();
      if (totalBytes > 0 && finalLength < totalBytes) {
        onError(
            'Download ended early (${_fmtMB(finalLength / 1048576.0)} of '
            '${_fmtMB(totalBytes / 1048576.0)}). The partial file was kept — '
            'tap Resume to continue.');
        return;
      }
      if (finalLength < 1024 * 1024) {
        onError('The downloaded file looks invalid. Please try again.');
        return;
      }

      // Replace any previous copy atomically (rename over an existing file is
      // allowed on Android's ext4/f2fs).
      final target = File(filePath);
      if (await target.exists()) await target.delete();
      await tempFile.rename(filePath);

      onProgress(1.0, 'Done', _fmtMB(finalLength / 1048576.0),
          _fmtMB(finalLength / 1048576.0));
      onComplete();
    } on DioException catch (e) {
      if (CancelToken.isCancel(e)) {
        onError('Download paused. You can resume it later.');
      } else if (e.type == DioExceptionType.connectionTimeout ||
          e.type == DioExceptionType.receiveTimeout) {
        onError('Connection timed out. Tap Resume to continue.');
      } else if (e.type == DioExceptionType.badResponse) {
        onError('Server error ${e.response?.statusCode}. Try again later.');
      } else if (e.error is SocketException) {
        onError('Network connection lost. Tap Resume to continue.');
      } else {
        onError('Download failed. Check your connection and try again.');
      }
    } catch (e) {
      onError('Download failed: $e');
    } finally {
      try {
        await raf?.close();
      } catch (_) {}
    }
  }

  Future<double?> _freeDiskMB() async {
    try {
      return await DiskSpace.getFreeDiskSpace;
    } catch (_) {
      return null;
    }
  }

  String _fmtMB(num mb) {
    if (mb >= 1024) return '${(mb / 1024).toStringAsFixed(1)} GB';
    return '${mb.round()} MB';
  }

  String _fmtSpeed(double bps) {
    if (bps >= 1024 * 1024) {
      return '${(bps / (1024 * 1024)).toStringAsFixed(1)} MB/s';
    }
    if (bps >= 1024) return '${(bps / 1024).toStringAsFixed(0)} KB/s';
    if (bps <= 0) return '—';
    return '${bps.toStringAsFixed(0)} B/s';
  }

  Future<void> deleteModel(String fileName) async {
    final dir = await getModelsDirectory();
    for (final path in ['$dir/$fileName', '$dir/$fileName.part']) {
      final f = File(path);
      if (await f.exists()) await f.delete();
    }
  }
}
