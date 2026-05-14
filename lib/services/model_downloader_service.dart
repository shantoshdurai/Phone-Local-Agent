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

      int downloadedBytes = 0;
      final tempFile = File(tempFilePath);
      
      if (await tempFile.exists()) {
        downloadedBytes = await tempFile.length();
      }

      Options options = Options(
        responseType: ResponseType.stream,
        headers: downloadedBytes > 0 ? {'Range': 'bytes=$downloadedBytes-'} : null,
      );

      DateTime lastTime = DateTime.now();
      int lastBytes = downloadedBytes;

      final response = await _dio.get<ResponseBody>(
        url,
        options: options,
        cancelToken: _cancelToken,
      );

      final isPartial = response.statusCode == 206;
      if (!isPartial && downloadedBytes > 0) {
        // Server didn't respect range, start over
        downloadedBytes = 0;
        await tempFile.delete();
      }

      // HuggingFace spaces might return -1 for total size if range is used sometimes, but let's try to get it
      int totalBytes = -1;
      final contentLengthHeader = response.headers.value('content-length');
      if (contentLengthHeader != null) {
        totalBytes = int.parse(contentLengthHeader) + downloadedBytes;
      }
      
      final file = tempFile.openSync(mode: isPartial ? FileMode.append : FileMode.write);
      
      final stream = response.data!.stream;
      await for (final chunk in stream) {
        if (_cancelToken?.isCancelled ?? false) {
           break;
        }
        
        file.writeFromSync(chunk);
        downloadedBytes += chunk.length;

        if (totalBytes != -1) {
          final now = DateTime.now();
          final difference = now.difference(lastTime).inMilliseconds;

          if (difference > 500 || downloadedBytes == totalBytes) {
            final bytesSinceLast = downloadedBytes - lastBytes;
            final speedBps = (bytesSinceLast / difference) * 1000;
            
            String speedStr;
            if (speedBps > 1024 * 1024) {
              speedStr = '${(speedBps / (1024 * 1024)).toStringAsFixed(1)} MB/s';
            } else if (speedBps > 1024) {
              speedStr = '${(speedBps / 1024).toStringAsFixed(1)} KB/s';
            } else {
              speedStr = '${speedBps.toStringAsFixed(1)} B/s';
            }

            final downloadedMB = (downloadedBytes / (1024 * 1024)).toStringAsFixed(1);
            final totalMB = (totalBytes / (1024 * 1024)).toStringAsFixed(1);
            final progress = downloadedBytes / totalBytes;

            onProgress(progress, speedStr, '${downloadedMB}MB', '${totalMB}MB');

            lastTime = now;
            lastBytes = downloadedBytes;
          }
        }
      }
      
      file.closeSync();

      if (!(_cancelToken?.isCancelled ?? false)) {
          if (await tempFile.exists()) {
            await tempFile.rename(filePath);
          }
          onComplete();
      }
    } catch (e) {
      if (e is DioException) {
         if (CancelToken.isCancel(e)) {
            onError('Download paused/cancelled.');
         } else {
            // Clean up the error message for the UI
            String errMsg = 'Connection error. Resume to try again.';
            if (e.type == DioExceptionType.connectionTimeout || e.type == DioExceptionType.receiveTimeout) {
               errMsg = 'Connection timed out.';
            } else if (e.type == DioExceptionType.badResponse) {
               errMsg = 'Server error: ${e.response?.statusCode}';
            } else if (e.error is SocketException) {
               errMsg = 'Network connection lost. Resume to try again.';
            }
            onError(errMsg);
         }
      } else {
        onError('An unexpected error occurred.');
      }
    }
  }

  Future<void> deleteModel(String fileName) async {
    final dir = await getModelsDirectory();
    final file = File('$dir/$fileName');
    if (await file.exists()) {
      await file.delete();
    }
    final tempFile = File('$dir/$fileName.part');
    if (await tempFile.exists()) {
      await tempFile.delete();
    }
  }
}