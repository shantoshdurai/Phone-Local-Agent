import 'dart:io';
import 'package:dio/dio.dart';
import 'package:path_provider/path_provider.dart';

class ModelDownloaderService {
  static final ModelDownloaderService _instance = ModelDownloaderService._internal();
  factory ModelDownloaderService() => _instance;
  ModelDownloaderService._internal();

  final Dio _dio = Dio();
  CancelToken? _cancelToken;

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
    return await file.exists();
  }

  void cancelDownload() {
    _cancelToken?.cancel('Download cancelled by user.');
    _cancelToken = null;
  }

  Future<void> downloadModel({
    required String url,
    required String fileName,
    required Function(double progress, String speed, String downloadedStr, String totalStr) onProgress,
    required Function() onComplete,
    required Function(String error) onError,
  }) async {
    try {
      final dir = await getModelsDirectory();
      final filePath = '$dir/$fileName';
      final tempFilePath = '$filePath.part';

      _cancelToken = CancelToken();

      DateTime lastTime = DateTime.now();
      int lastBytes = 0;

      await _dio.download(
        url,
        tempFilePath,
        cancelToken: _cancelToken,
        onReceiveProgress: (received, total) {
          if (total != -1) {
            final now = DateTime.now();
            final difference = now.difference(lastTime).inMilliseconds;

            if (difference > 500 || received == total) {
              final bytesSinceLast = received - lastBytes;
              final speedBps = (bytesSinceLast / difference) * 1000;
              
              String speedStr;
              if (speedBps > 1024 * 1024) {
                speedStr = '${(speedBps / (1024 * 1024)).toStringAsFixed(1)} MB/s';
              } else if (speedBps > 1024) {
                speedStr = '${(speedBps / 1024).toStringAsFixed(1)} KB/s';
              } else {
                speedStr = '${speedBps.toStringAsFixed(1)} B/s';
              }

              final downloadedMB = (received / (1024 * 1024)).toStringAsFixed(1);
              final totalMB = (total / (1024 * 1024)).toStringAsFixed(1);
              final progress = received / total;

              onProgress(progress, speedStr, '${downloadedMB}MB', '${totalMB}MB');

              lastTime = now;
              lastBytes = received;
            }
          }
        },
      );

      // Rename temp file to final file
      final tempFile = File(tempFilePath);
      if (await tempFile.exists()) {
        await tempFile.rename(filePath);
      }
      onComplete();
    } catch (e) {
      if (CancelToken.isCancel(e as DioException)) {
        onError('Download cancelled.');
      } else {
        onError('Download failed: $e');
      }
    }
  }

  Future<void> deleteModel(String fileName) async {
    final dir = await getModelsDirectory();
    final file = File('$dir/$fileName');
    if (await file.exists()) {
      await file.delete();
    }
  }
}
