import 'dart:io';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';

class FileMetadata {
  final String path;
  final String name;
  final String type;
  final int size;
  final DateTime modifiedDate;
  final DateTime lastAccessedDate;

  FileMetadata({
    required this.path,
    required this.name,
    required this.type,
    required this.size,
    required this.modifiedDate,
    required this.lastAccessedDate,
  });

  Map<String, dynamic> toMap() {
    return {
      'path': path,
      'name': name,
      'type': type,
      'size': size,
      'modified_date': modifiedDate.toIso8601String(),
      'last_accessed': lastAccessedDate.toIso8601String(),
    };
  }
}

class FileService {
  Future<bool> requestPermissions() async {
    if (Platform.isAndroid) {
      if (await Permission.manageExternalStorage.request().isGranted) {
        return true;
      }
      if (await Permission.storage.request().isGranted) {
        return true;
      }
      return false;
    }
    // For iOS, standard permissions applies when accessing specific directories.
    return true; 
  }

  Future<List<FileMetadata>> indexDocuments() async {
    final hasPermission = await requestPermissions();
    if (!hasPermission) {
      throw Exception('Storage permissions denied.');
    }

    List<FileMetadata> files = [];
    List<String> scanPaths = [];

    if (Platform.isAndroid) {
      scanPaths = [
        '/storage/emulated/0/Documents',
        '/storage/emulated/0/Download',
        '/storage/emulated/0/DCIM/Screenshots',
        '/storage/emulated/0/Pictures/Screenshots',
      ];
    } else {
      final docDir = await getApplicationDocumentsDirectory();
      scanPaths = [docDir.path];
    }

    for (String path in scanPaths) {
      final targetDir = Directory(path);
      if (await targetDir.exists()) {
        try {
          final entities = targetDir.listSync(recursive: true, followLinks: false);
          for (var entity in entities) {
            if (entity is File) {
              final stat = await entity.stat();
              files.add(FileMetadata(
                path: entity.path,
                name: entity.path.split('/').last,
                type: entity.path.split('.').last,
                size: stat.size,
                modifiedDate: stat.modified,
                lastAccessedDate: stat.accessed,
              ));
            }
          }
        } catch (e) {
          print('Error indexing path $path: $e');
        }
      }
    }

    return files;
  }

  Future<String> readFileContent(String filePath) async {
    try {
      final file = File(filePath);
      if (await file.exists()) {
        // Read only first 2000 chars to prevent massive context overflow
        final content = await file.readAsString();
        if (content.length > 2000) {
          return content.substring(0, 2000) + '... [truncated]';
        }
        return content;
      }
    } catch (e) {
      return 'Error reading file: $e';
    }
    return 'File not found.';
  }

  Future<bool> deleteFile(String filePath) async {
    try {
      final file = File(filePath);
      if (await file.exists()) {
        await file.delete();
        return true;
      }
      return false;
    } catch (e) {
      print('Error deleting file: $e');
      return false;
    }
  }
}
