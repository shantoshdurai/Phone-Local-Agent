import 'dart:convert';
import 'dart:io';

import 'package:android_intent_plus/android_intent.dart';
import 'package:http/http.dart' as http;
import 'package:url_launcher/url_launcher.dart';

/// "Play X on YouTube / Spotify / YouTube Music".
///
/// Android has no API for an app to control another app's playback, but two
/// public routes get close to what assistants do:
///  * YouTube: find the top video for the query and open its watch URL; the
///    YouTube app opens it and starts playing.
///  * Music apps: MEDIA_PLAY_FROM_SEARCH, the intent Google Assistant uses
///    for "play X on Spotify"; Spotify and YouTube Music start playback
///    directly.
class MediaService {
  MediaService({http.Client Function()? clientFactory})
      : _clientFactory = clientFactory ?? http.Client.new;

  final http.Client Function() _clientFactory;

  static const _packages = {
    'spotify': 'com.spotify.music',
    'youtube_music': 'com.google.android.apps.youtube.music',
    'youtube': 'com.google.android.youtube',
  };

  static const _appNames = {
    'spotify': 'Spotify',
    'youtube_music': 'YouTube Music',
    'youtube': 'YouTube',
    'any': 'your music app',
  };

  /// [app] is `youtube`, `youtube_music`, `spotify` or `any`.
  Future<Map<String, dynamic>> play(String query, {String app = 'youtube'}) async {
    final q = query.trim();
    if (q.isEmpty) return {'error': 'Tell me what to play.'};
    final target = _appNames.containsKey(app) ? app : 'youtube';

    if (target != 'youtube' && Platform.isAndroid) {
      final started = await _playFromSearch(q, package: _packages[target]);
      if (started) {
        return {'success': true, 'app': _appNames[target], 'query': q, 'playing': true};
      }
      if (target == 'spotify') {
        final opened = await _launch(Uri.parse('spotify:search:${Uri.encodeComponent(q)}'));
        if (opened) return {'success': true, 'app': 'Spotify', 'query': q, 'playing': false};
      }
      if (target == 'youtube_music') {
        final opened = await _launch(Uri.https('music.youtube.com', '/search', {'q': q}));
        if (opened) return {'success': true, 'app': 'YouTube Music', 'query': q, 'playing': false};
      }
      // No music app handled it: fall back to YouTube.
    }

    final video = await findYouTubeVideo(q);
    if (video != null) {
      final opened = await _launch(Uri.https('www.youtube.com', '/watch', {'v': video.id}));
      if (opened) {
        return {
          'success': true,
          'app': 'YouTube',
          'query': q,
          'title': video.title,
          'playing': true,
        };
      }
    }
    final opened = await _launch(Uri.https('www.youtube.com', '/results', {'search_query': q}));
    return opened
        ? {'success': true, 'app': 'YouTube', 'query': q, 'playing': false}
        : {'error': 'Couldn\'t open YouTube.'};
  }

  Future<bool> _playFromSearch(String query, {String? package}) async {
    try {
      final intent = AndroidIntent(
        action: 'android.media.action.MEDIA_PLAY_FROM_SEARCH',
        package: package,
        arguments: {
          'query': query,
          'android.intent.extra.focus': 'vnd.android.cursor.item/*',
        },
      );
      if (await intent.canResolveActivity() != true) return false;
      await intent.launch();
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<bool> _launch(Uri uri) async {
    try {
      return await launchUrl(uri, mode: LaunchMode.externalApplication);
    } catch (_) {
      return false;
    }
  }

  /// Top YouTube search result, without an API key.
  Future<({String id, String? title})?> findYouTubeVideo(String query) async {
    final client = _clientFactory();
    try {
      final res = await client.get(
        Uri.https('www.youtube.com', '/results', {'search_query': query}),
        headers: const {
          // A mobile user agent is redirected to m.youtube.com, whose page
          // uses different renderers; the desktop page is stable.
          'user-agent': 'Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 '
              '(KHTML, like Gecko) Chrome/128.0 Safari/537.36',
          'accept-language': 'en-US,en;q=0.8',
          // Skips the EU cookie-consent interstitial.
          'cookie': 'CONSENT=YES+1',
        },
      ).timeout(const Duration(seconds: 8));
      if (res.statusCode != 200) return null;
      return parseFirstVideo(utf8.decode(res.bodyBytes, allowMalformed: true));
    } catch (_) {
      return null;
    } finally {
      client.close();
    }
  }

  /// First organic video in a YouTube results page (ads and shorts use
  /// other renderers). Visible for testing.
  static ({String id, String? title})? parseFirstVideo(String html) {
    final m = RegExp(r'"videoRenderer":\{"videoId":"([A-Za-z0-9_-]{11})"').firstMatch(html);
    if (m == null) return null;
    final window = html.substring(m.end, (m.end + 4000).clamp(0, html.length));
    final t = RegExp(r'"title":\{"runs":\[\{"text":"((?:[^"\\]|\\.)*)"').firstMatch(window);
    String? title;
    if (t != null) {
      try {
        title = jsonDecode('"${t.group(1)}"') as String;
      } catch (_) {
        title = t.group(1);
      }
    }
    return (id: m.group(1)!, title: title);
  }
}
