import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:disk_space_2/disk_space_2.dart';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import 'app_settings.dart';
import 'local/local_model.dart';
import 'screen_awake.dart';

@immutable
class DownloadProgress {
  final String modelId;
  final String label;
  final int receivedBytes;
  final int totalBytes;
  final double bytesPerSecond;

  const DownloadProgress({
    required this.modelId,
    required this.label,
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

  String get amountLabel => '${formatBytes(receivedBytes)} / ${formatBytes(totalBytes)}';

  /// Time left at the current speed, e.g. "about 3 min left".
  String? get etaLabel {
    if (bytesPerSecond <= 0) return null;
    final seconds = (totalBytes - receivedBytes) / bytesPerSecond;
    if (seconds < 60) return 'less than a minute left';
    final minutes = (seconds / 60).round();
    return minutes < 90 ? 'about $minutes min left' : 'about ${(minutes / 60).toStringAsFixed(1)} h left';
  }
}

/// Downloads model files with resume support.
///
/// A singleton with a [progress] notifier, so a download keeps going (and
/// the UI can re-attach to it) when the user leaves the screen.
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

  String? _dirCache;

  /// Tests point this at a folder of model files.
  @visibleForTesting
  static String? debugModelsDirectory;

  Future<String> getModelsDirectory() async {
    if (debugModelsDirectory != null) return debugModelsDirectory!;
    if (_dirCache != null) return _dirCache!;
    final directory = await getApplicationDocumentsDirectory();
    final modelsDir = Directory('${directory.path}/models');
    if (!await modelsDir.exists()) {
      await modelsDir.create(recursive: true);
    }
    return _dirCache = modelsDir.path;
  }

  Future<String> pathFor(String fileName) async =>
      '${await getModelsDirectory()}/$fileName';

  Future<bool> isModelDownloaded(String fileName) async =>
      File(await pathFor(fileName)).exists();

  Future<bool> hasPartialDownload(String fileName) async =>
      File('${await pathFor(fileName)}.part').exists();

  Future<bool> isVisionDownloaded(LocalModel model) async {
    final name = model.localMmprojName;
    return name != null && await isModelDownloaded(name);
  }

  void cancelDownload() {
    _cancelToken?.cancel('Download paused.');
  }

  /// Downloads [model] (and its vision projector if [withVision]). Resolves
  /// when every file is complete and verified; throws a user-readable
  /// [String] on failure. Safe to call again to resume.
  Future<void> download(LocalModel model, {bool withVision = true}) async {
    if (isDownloading) throw 'Another download is already running.';

    final files = <({String url, String name, int size})>[
      (url: model.downloadUrl, name: model.localFileName, size: model.sizeBytes),
      if (withVision && model.mmprojUrl != null && model.mmprojSizeBytes != null)
        (url: model.mmprojUrl!, name: model.localMmprojName!, size: model.mmprojSizeBytes!),
    ];

    // Work out what's left, then refuse up front instead of failing at 90%
    // with a full disk.
    final pending = <({String url, String name, int size})>[];
    var done = 0;
    var total = 0;
    for (final f in files) {
      total += f.size;
      if (await isModelDownloaded(f.name)) {
        done += f.size;
        continue;
      }
      final part = File('${await pathFor(f.name)}.part');
      if (await part.exists()) done += (await part.length()).clamp(0, f.size);
      pending.add(f);
    }
    if (pending.isEmpty) return;
    try {
      final freeMB = await DiskSpace.getFreeDiskSpace;
      final neededMB = (total - done) / (1024 * 1024) + 300;
      if (freeMB != null && freeMB < neededMB) {
        throw 'Not enough storage: ${model.name} needs '
            '${(neededMB / 1024).toStringAsFixed(1)} GB free, you have '
            '${(freeMB / 1024).toStringAsFixed(1)} GB.';
      }
    } on String {
      rethrow;
    } catch (_) {
      // Couldn't read free space; try anyway.
    }

    final token = await KeyStore.read('huggingface');
    final cancelToken = _cancelToken = CancelToken();
    await ScreenAwake.acquire();
    progress.value = DownloadProgress(
      modelId: model.id,
      label: model.name,
      receivedBytes: done,
      totalBytes: total,
      bytesPerSecond: 0,
    );
    try {
      var completedBefore = total - pending.fold<int>(0, (a, f) => a + f.size);
      for (final f in pending) {
        await _downloadFile(
          url: f.url,
          fileName: f.name,
          expectedSize: f.size,
          authToken: token,
          cancelToken: cancelToken,
          onProgress: (received, bps) => progress.value = DownloadProgress(
            modelId: model.id,
            label: model.name,
            receivedBytes: completedBefore + received,
            totalBytes: total,
            bytesPerSecond: bps,
          ),
        );
        completedBefore += f.size;
      }
    } finally {
      progress.value = null;
      if (identical(_cancelToken, cancelToken)) _cancelToken = null;
      await ScreenAwake.release();
    }
  }

  Future<void> _downloadFile({
    required String url,
    required String fileName,
    required int expectedSize,
    required String? authToken,
    required CancelToken cancelToken,
    required void Function(int received, double bytesPerSecond) onProgress,
  }) async {
    final filePath = await pathFor(fileName);
    final partFile = File('$filePath.part');
    var received = await partFile.exists() ? await partFile.length() : 0;
    if (received > expectedSize) {
      await partFile.delete();
      received = 0;
    }

    RandomAccessFile? raf;
    try {
      final response = await _dio.get<ResponseBody>(
        url,
        options: Options(
          responseType: ResponseType.stream,
          headers: {
            if (received > 0) 'range': 'bytes=$received-',
            if (authToken != null) 'authorization': 'Bearer $authToken',
          },
        ),
        cancelToken: cancelToken,
      );
      final resumed = response.statusCode == 206;
      if (!resumed) received = 0; // server ignored the range: start over
      raf = await partFile.open(mode: resumed ? FileMode.append : FileMode.write);

      var lastTick = DateTime.now();
      var bytesSinceTick = 0;
      var speed = 0.0;
      onProgress(received, 0);
      await for (final chunk in response.data!.stream) {
        await raf.writeFrom(chunk);
        received += chunk.length;
        bytesSinceTick += chunk.length;
        final now = DateTime.now();
        final elapsed = now.difference(lastTick).inMilliseconds;
        if (elapsed >= 500) {
          final instant = bytesSinceTick * 1000 / elapsed;
          speed = speed == 0 ? instant : speed * 0.7 + instant * 0.3;
          onProgress(received, speed);
          lastTick = now;
          bytesSinceTick = 0;
        }
      }
      await raf.close();
      raf = null;

      final actual = await partFile.length();
      if (actual != expectedSize) {
        if (actual > expectedSize) await partFile.delete();
        throw 'Download incomplete (${formatBytes(actual)} of ${formatBytes(expectedSize)}). '
            'Tap Resume to continue.';
      }
      await partFile.rename(filePath);
    } on DioException catch (e) {
      if (CancelToken.isCancel(e)) throw 'Download paused.';
      final status = e.response?.statusCode;
      if (status == 401 || status == 403) {
        throw authToken == null
            ? 'This model needs a Hugging Face account. Accept its license on '
                'huggingface.co, then add an access token in Settings.'
            : 'Hugging Face refused the download (HTTP $status). Check that you '
                'accepted the model\'s license and that your token is valid.';
      }
      if (status == 404) throw 'The file is no longer on Hugging Face.';
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
    }
  }

  /// Deletes a model's files (and partial downloads). With [visionOnly],
  /// keeps the model and removes just the vision projector.
  Future<void> deleteModel(LocalModel model, {bool visionOnly = false}) async {
    final names = [
      if (!visionOnly) model.localFileName,
      if (model.localMmprojName != null) model.localMmprojName!,
    ];
    for (final name in names) {
      final path = await pathFor(name);
      for (final f in [File(path), File('$path.part')]) {
        if (await f.exists()) await f.delete();
      }
    }
  }

  /// Bytes on disk for [model], counting partial downloads.
  Future<int> bytesOnDisk(LocalModel model) async {
    var total = 0;
    for (final name in [model.localFileName, if (model.localMmprojName != null) model.localMmprojName!]) {
      final path = await pathFor(name);
      for (final f in [File(path), File('$path.part')]) {
        if (await f.exists()) total += await f.length();
      }
    }
    return total;
  }
}
