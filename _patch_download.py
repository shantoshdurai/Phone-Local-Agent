import re

with open('lib/services/agent_service.dart', 'r') as f:
    content = f.read()

old_block = """    // ─── Apps: download/install from Play Store ───
    if (msg.contains('download') || msg.contains('install') || msg.contains('apk') ||
        msg.contains('play store') || msg.contains('playstore') || msg.contains('get the app')) {
      // Extract app name by removing noise words
      var appName = msg;
      final noiseWords = [
        'download', 'install', 'the', 'latest', 'apk', 'app', 'application',
        'from', 'play', 'store', 'playstore', 'please', 'can', 'you', 'i',
        'want', 'to', 'need', 'get', 'me', 'for', 'a', 'an',
      ];
      for (final w in noiseWords) {
        appName = appName.replaceAll(RegExp('\\\\b\$w\\\\b', caseSensitive: false), '');
      }
      appName = appName.replaceAll(RegExp(r'\\s+'), ' ').trim();
      if (appName.isNotEmpty) {
        return {'tool_name': 'search_play_store', 'arguments': {'query': appName}};
      }
    }"""

new_block = """    // ─── Apps: download/install ───
    if (msg.contains('download') || msg.contains('install') || msg.contains('apk') ||
        msg.contains('play store') || msg.contains('playstore') || msg.contains('get the app')) {
      // Extract app name by removing noise words
      var appName = msg;
      final noiseWords = [
        'download', 'install', 'the', 'latest', 'apk', 'app', 'application',
        'from', 'play', 'store', 'playstore', 'please', 'can', 'you', 'i',
        'want', 'to', 'need', 'get', 'me', 'for', 'a', 'an', 'browser',
      ];
      for (final w in noiseWords) {
        appName = appName.replaceAll(RegExp('\\\\b\$w\\\\b', caseSensitive: false), '');
      }
      appName = appName.replaceAll(RegExp(r'\\s+'), ' ').trim();

      if (appName.isNotEmpty) {
        // "apk" mentioned → open browser to search for APK download
        // (for third-party apps like ReVanced, modded apps, etc.)
        if (msg.contains('apk')) {
          final searchQuery = Uri.encodeComponent('\$appName APK download');
          return {
            'tool_name': 'open_url',
            'arguments': {'url': 'https://www.google.com/search?q=\$searchQuery'}
          };
        }
        // No "apk" → Play Store (regular installs)
        return {'tool_name': 'search_play_store', 'arguments': {'query': appName}};
      }
    }"""

if old_block in content:
    content = content.replace(old_block, new_block)
    with open('lib/services/agent_service.dart', 'w') as f:
        f.write(content)
    print("PATCHED successfully")
else:
    print("OLD BLOCK NOT FOUND")
