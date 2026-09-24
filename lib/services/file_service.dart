import 'dart:io';

import 'package:device_info_plus/device_info_plus.dart';
import 'package:permission_handler/permission_handler.dart';

class FileMetadata {
  final String path;
  final String name;
  final String type;
  final int size;
  final DateTime modifiedDate;

  FileMetadata({
    required this.path,
    required this.name,
    required this.type,
    required this.size,
    required this.modifiedDate,
  });
}

/// Media file access within what Android grants a Play Store app.
///
/// "All files access" (MANAGE_EXTERNAL_STORAGE) is restricted by Play policy
/// to file managers and similar apps, so this app only asks for media
/// permissions: photos/videos/audio are visible, other apps' documents are
/// not. Tool results say so explicitly so the model doesn't invent files.
class FileService {
  static const _root = '/storage/emulated/0';
  static const _scanDirs = [
    'DCIM',
    'Pictures',
    'Movies',
    'Music',
    'Download',
    'Documents',
  ];
  static const _screenshotDirs = [
    '$_root/DCIM/Screenshots',
    '$_root/Pictures/Screenshots',
  ];

  static int? _sdkInt;

  Future<int> _androidSdk() async {
    if (_sdkInt != null) return _sdkInt!;
    try {
      _sdkInt = (await DeviceInfoPlugin().androidInfo).version.sdkInt;
    } catch (_) {
      _sdkInt = 33;
    }
    return _sdkInt!;
  }

  /// Requests photo access (READ_MEDIA_IMAGES on Android 13+, storage below).
  Future<bool> ensureMediaPermission({bool includeVideoAudio = false}) async {
    if (!Platform.isAndroid) return true;
    if (await _androidSdk() >= 33) {
      final photos = await Permission.photos.request();
      if (includeVideoAudio) {
        await Permission.videos.request();
        await Permission.audio.request();
      }
      return photos.isGranted || photos.isLimited;
    }
    return (await Permission.storage.request()).isGranted;
  }

  Future<List<FileMetadata>> _scan({required Set<String>? extensions}) async {
    final files = <FileMetadata>[];
    for (final dir in _scanDirs) {
      final d = Directory('$_root/$dir');
      if (!await d.exists()) continue;
      try {
        await for (final entity in d.list(recursive: true, followLinks: false)) {
          if (entity is! File) continue;
          final name = entity.uri.pathSegments.last;
          if (name.startsWith('.')) continue;
          final dot = name.lastIndexOf('.');
          final ext = dot < 0 ? '' : name.substring(dot + 1).toLowerCase();
          if (extensions != null && !extensions.contains(ext)) continue;
          try {
            final stat = await entity.stat();
            files.add(FileMetadata(
              path: entity.path,
              name: name,
              type: ext,
              size: stat.size,
              modifiedDate: stat.modified,
            ));
          } catch (_) {}
          if (files.length > 5000) break;
        }
      } catch (_) {
        // Directories Android hides from us throw; skip them.
      }
    }
    return files;
  }

  Future<Map<String, dynamic>> listFiles({String? extension, String? sortBy}) async {
    if (!await ensureMediaPermission(includeVideoAudio: true)) {
      return {
        'error':
            'Photos & media permission is off. Allow it in Settings → Apps → Local Agent → Permissions.',
      };
    }
    final ext = extension?.trim().toLowerCase().replaceFirst('.', '');
    final files = await _scan(
        extensions: (ext == null || ext.isEmpty) ? null : {ext});
    switch (sortBy) {
      case 'name':
        files.sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
      case 'size':
        files.sort((a, b) => b.size.compareTo(a.size));
      default:
        files.sort((a, b) => b.modifiedDate.compareTo(a.modifiedDate));
    }
    return {
      'total': files.length,
      'files': [
        for (final f in files.take(20))
          {
            'name': f.name,
            'sizeKB': (f.size / 1024).round(),
            'modified': f.modifiedDate.toIso8601String().substring(0, 16),
          }
      ],
      'note': 'Only photos, videos, music and this app\'s own files are '
          'visible; Android hides other apps\' documents (e.g. PDFs).',
    };
  }

  Future<List<Map<String, dynamic>>> getRecentScreenshots({int limit = 5}) async {
    if (!await ensureMediaPermission()) return const [];
    final shots = <File>[];
    for (final dirPath in _screenshotDirs) {
      final dir = Directory(dirPath);
      if (!await dir.exists()) continue;
      try {
        await for (final e in dir.list()) {
          if (e is! File) continue;
          final n = e.path.toLowerCase();
          if (n.endsWith('.png') || n.endsWith('.jpg') || n.endsWith('.jpeg') || n.endsWith('.webp')) {
            shots.add(e);
          }
        }
      } catch (_) {}
    }
    final withTimes = <(File, DateTime)>[];
    for (final f in shots) {
      try {
        withTimes.add((f, (await f.stat()).modified));
      } catch (_) {}
    }
    withTimes.sort((a, b) => b.$2.compareTo(a.$2));
    return [
      for (final (file, modified) in withTimes.take(limit))
        {
          'name': file.uri.pathSegments.last,
          'path': file.path,
          'modified': modified.toIso8601String().substring(0, 16),
        }
    ];
  }
}
