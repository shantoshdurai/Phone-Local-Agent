import 'dart:io';
import 'dart:isolate';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'permission_flow.dart';

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

/// Runs off the UI isolate: walking DCIM/Pictures can touch thousands of
/// entries, and doing that synchronously on the main isolate is a guaranteed
/// jank spike (or an ANR when the folder is large).
List<Map<String, dynamic>> _scanFolders(List<String> roots) {
  final out = <Map<String, dynamic>>[];
  const maxFiles = 4000;
  for (final root in roots) {
    if (out.length >= maxFiles) break;
    final dir = Directory(root);
    try {
      if (!dir.existsSync()) continue;
      for (final entity in dir.listSync(recursive: true, followLinks: false)) {
        if (out.length >= maxFiles) break;
        if (entity is! File) continue;
        try {
          final stat = entity.statSync();
          final name = p.basename(entity.path);
          final ext = p.extension(name);
          out.add({
            'path': entity.path,
            'name': name,
            'type': ext.isEmpty ? '' : ext.substring(1).toLowerCase(),
            'size': stat.size,
            'modified': stat.modified.millisecondsSinceEpoch,
            'accessed': stat.accessed.millisecondsSinceEpoch,
          });
        } catch (_) {
          // Unreadable entry (permission, race) — skip it, keep scanning.
        }
      }
    } catch (_) {
      // Folder not readable with the granted permission level. This is
      // expected for Download/Documents on Android 13+ without a SAF grant.
    }
  }
  return out;
}

class FileService {
  /// Media access only. The app deliberately does **not** ask for "all files
  /// access" (MANAGE_EXTERNAL_STORAGE): Play restricts it to file managers,
  /// and a general assistant is not a qualifying use case.
  Future<bool> requestPermissions() async {
    if (!Platform.isAndroid) return true;
    if (await PermissionFlow.isGranted(PermTopic.media)) return true;
    return PermissionFlow.request(PermTopic.media);
  }

  Future<List<FileMetadata>> indexDocuments() async {
    if (Platform.isAndroid && !await requestPermissions()) {
      throw const FileAccessException(
        'Photo and media access is off. Enable it in Settings to let the '
        'agent look at files.',
      );
    }

    final roots = <String>[];
    if (Platform.isAndroid) {
      // Media collections readable with READ_MEDIA_* on 13+. Download and
      // Documents are intentionally absent: they require a SAF tree grant,
      // which the app does not have.
      roots.addAll([
        '/storage/emulated/0/DCIM',
        '/storage/emulated/0/Pictures',
        '/storage/emulated/0/Movies',
        '/storage/emulated/0/Music',
      ]);
    } else {
      final docDir = await getApplicationDocumentsDirectory();
      roots.add(docDir.path);
    }

    final raw = await Isolate.run(() => _scanFolders(roots));
    return raw
        .map((m) => FileMetadata(
              path: m['path'] as String,
              name: m['name'] as String,
              type: m['type'] as String,
              size: m['size'] as int,
              modifiedDate: DateTime.fromMillisecondsSinceEpoch(
                  m['modified'] as int),
              lastAccessedDate: DateTime.fromMillisecondsSinceEpoch(
                  m['accessed'] as int),
            ))
        .toList();
  }

  Future<String> readFileContent(String filePath) async {
    try {
      final file = File(filePath);
      if (!await file.exists()) return 'File not found.';
      // Read at most 8 KB, then trim: never buffer a whole video into memory
      // just to return 2000 characters.
      final raf = await file.open();
      try {
        final bytes = await raf.read(8192);
        final text = String.fromCharCodes(bytes);
        return text.length > 2000 ? '${text.substring(0, 2000)}… [truncated]' : text;
      } finally {
        await raf.close();
      }
    } catch (e) {
      return 'Error reading file: $e';
    }
  }

  Future<bool> deleteFile(String filePath) async {
    try {
      final file = File(filePath);
      if (!await file.exists()) return false;
      await file.delete();
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<List<Map<String, dynamic>>> getRecentScreenshots({int limit = 5}) async {
    if (Platform.isAndroid && !await requestPermissions()) {
      return const [];
    }
    final roots = Platform.isAndroid
        ? const [
            '/storage/emulated/0/DCIM/Screenshots',
            '/storage/emulated/0/Pictures/Screenshots',
          ]
        : <String>[];

    final all = <Map<String, dynamic>>[];
    for (final root in roots) {
      final dir = Directory(root);
      try {
        if (!await dir.exists()) continue;
        for (final f in dir.listSync().whereType<File>()) {
          final n = f.path.toLowerCase();
          if (!(n.endsWith('.png') ||
              n.endsWith('.jpg') ||
              n.endsWith('.jpeg') ||
              n.endsWith('.webp'))) {
            continue;
          }
          try {
            final stat = f.statSync();
            all.add({
              'name': p.basename(f.path),
              'path': f.path,
              'sizeKB': (stat.size / 1024).round(),
              'modified': stat.modified.toIso8601String(),
              '_ts': stat.modified.millisecondsSinceEpoch,
            });
          } catch (_) {}
        }
      } catch (_) {}
    }
    all.sort((a, b) => (b['_ts'] as int).compareTo(a['_ts'] as int));
    return all
        .take(limit)
        .map((m) => Map<String, dynamic>.from(m)..remove('_ts'))
        .toList();
  }
}

class FileAccessException implements Exception {
  final String message;
  const FileAccessException(this.message);
  @override
  String toString() => message;
}
