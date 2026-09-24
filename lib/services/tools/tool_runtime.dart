import 'dart:convert';

import '../app_service.dart';
import '../device_service.dart';
import '../file_service.dart';
import '../personal_service.dart';
import '../search_service.dart';
import '../utility_service.dart';
import '../weather_service.dart';
import 'tool_args.dart';
import 'tool_catalog.dart';

/// Asked before a sensitive tool runs (calls, messages, calendar writes,
/// uninstalls) when "Confirm before actions" is on.
class ToolConfirmation {
  final String toolName;
  final String title;
  final String detail;
  const ToolConfirmation(this.toolName, this.title, this.detail);
}

typedef ConfirmCallback = Future<bool> Function(ToolConfirmation request);

class ToolContext {
  final bool confirmSensitive;
  final ConfirmCallback? confirm;
  const ToolContext({this.confirmSensitive = true, this.confirm});
}

/// Executes tools for both backends and renders plain-language replies.
///
/// [execute] never throws: failures come back as `{'error': ...}` so the
/// model (or the templated reply) can tell the user what went wrong instead
/// of the whole turn crashing.
class ToolRuntime {
  ToolRuntime._();
  static final ToolRuntime instance = ToolRuntime._();

  final _device = DeviceService();
  final _files = FileService();
  final _apps = AppService();
  final _utility = UtilityService();
  final _personal = PersonalService();
  final _search = SearchService();
  final _weather = WeatherService();

  Future<Map<String, dynamic>> execute(
    String name,
    Map<String, dynamic> args, {
    ToolContext context = const ToolContext(),
  }) async {
    final spec = kToolsByName[name];
    if (spec == null) {
      return {'error': 'Unknown tool "$name". Use only the listed tools.'};
    }
    final missing = [
      for (final p in spec.requiredParams)
        if (args[p] == null || (args[p] is String && (args[p] as String).trim().isEmpty)) p
    ];
    if (missing.isNotEmpty) {
      return {'error': 'Missing required argument(s): ${missing.join(', ')}.'};
    }
    if (spec.sensitive && context.confirmSensitive && context.confirm != null) {
      final request = confirmationFor(name, args);
      final approved = await context.confirm!(request);
      if (!approved) {
        return {
          'cancelled': true,
          'error': 'The user declined: ${request.title}',
        };
      }
    }
    try {
      return await _dispatch(name, args);
    } catch (e) {
      return {'error': 'The $name tool failed: $e'};
    }
  }

  Future<Map<String, dynamic>> _dispatch(
      String name, Map<String, dynamic> args) async {
    switch (name) {
      case 'get_date_time':
        return dateTimeInfo(DateTime.now());
      case 'get_device_info':
        return _device.getDeviceInfo();
      case 'search_web':
        return _search.searchWeb(argString(args, 'query')!);
      case 'get_weather':
        return _weather.getWeather(argString(args, 'location'));
      case 'launch_app_by_name':
        return _apps.launchAppByName(argString(args, 'appName')!);
      case 'toggle_flashlight':
        final on = argBool(args, 'on') ?? true;
        return (await _utility.toggleFlashlight(on))
            ? {'success': true, 'on': on}
            : {'error': 'Couldn\'t switch the flashlight. Another app may be using the camera.'};
      case 'set_timer':
        final seconds = argInt(args, 'seconds');
        if (seconds == null || seconds < 1 || seconds > 86400) {
          return {'error': 'seconds must be between 1 and 86400.'};
        }
        return (await _utility.setTimer(seconds, argString(args, 'message') ?? 'Timer'))
            ? {'success': true, 'seconds': seconds}
            : {'error': 'No clock app accepted the timer.'};
      case 'set_alarm':
        final hour = argInt(args, 'hour');
        final minute = argInt(args, 'minute');
        if (hour == null || hour < 0 || hour > 23 || minute == null || minute < 0 || minute > 59) {
          return {'error': 'hour must be 0-23 and minute 0-59.'};
        }
        return (await _utility.setAlarm(hour, minute, argString(args, 'message') ?? 'Alarm'))
            ? {'success': true, 'hour': hour, 'minute': minute}
            : {'error': 'No clock app accepted the alarm.'};
      case 'set_volume':
        final level = argFraction(args, 'level');
        if (level == null) return {'error': 'level must be a number from 0 to 100.'};
        return (await _utility.setVolume(level))
            ? {'success': true, 'percent': (level * 100).round()}
            : {'error': 'Couldn\'t change the volume.'};
      case 'search_contacts':
        return _personal.searchContacts(argString(args, 'query')!);
      case 'make_phone_call':
        final phone = argString(args, 'phone')!;
        return (await _utility.makePhoneCall(phone))
            ? {'success': true, 'phone': phone}
            : {'error': 'Couldn\'t open the dialer for "$phone".'};
      case 'vibrate':
        var ms = argInt(args, 'duration') ?? 500;
        if (ms > 0 && ms <= 10) ms *= 1000; // models sometimes send seconds
        ms = ms.clamp(50, 10000);
        return (await _utility.vibrate(duration: ms))
            ? {'success': true, 'durationMs': ms}
            : {'error': 'This phone has no vibration motor.'};
      case 'open_url':
        final url = argString(args, 'url')!;
        if (UtilityService.normalizeUrl(url) == null) {
          return {'error': '"$url" is not a valid web address.'};
        }
        return (await _utility.openUrl(url))
            ? {'success': true, 'url': UtilityService.normalizeUrl(url).toString()}
            : {'error': 'No browser could open $url.'};
      case 'check_connectivity':
        return _utility.checkConnectivity();
      case 'read_notifications':
        return _utility.readNotifications(_apps.labelFor);
      case 'copy_to_clipboard':
        await _utility.copyToClipboard(argString(args, 'text')!);
        return {'success': true};
      case 'read_clipboard':
        final text = await _utility.readFromClipboard();
        return {'text': (text == null || text.isEmpty) ? null : _clip(text, 1500)};
      case 'send_whatsapp':
        return (await _personal.sendWhatsApp(
                argString(args, 'phone')!, argString(args, 'message')!))
            ? {'success': true}
            : {'error': 'Couldn\'t open WhatsApp. Is it installed?'};
      case 'schedule_event':
        final start = parseLocalDateTime(argString(args, 'start')!);
        if (start == null) {
          return {'error': 'start must be an ISO date-time like 2026-09-25T17:00.'};
        }
        if (start.isBefore(DateTime.now().subtract(const Duration(days: 1)))) {
          return {
            'error': 'That start time (${start.toIso8601String()}) is in the '
                'past. Check today\'s date with get_date_time.',
          };
        }
        final endRaw = argString(args, 'end');
        var end = endRaw == null ? null : parseLocalDateTime(endRaw);
        if (end != null && !end.isAfter(start)) end = null;
        return _personal.scheduleEvent(
          title: argString(args, 'title')!,
          start: start,
          end: end,
          description: argString(args, 'description'),
        );
      case 'get_recent_screenshots':
        final shots = await _files.getRecentScreenshots();
        return shots.isEmpty
            ? {'error': 'No screenshots found (or photo permission is off).'}
            : {'screenshots': shots};
      case 'list_files':
        return _files.listFiles(
          extension: argString(args, 'extension'),
          sortBy: argString(args, 'sortBy'),
        );
      case 'list_apps':
        final apps = await _apps.getInstalledApps();
        return {
          'total': apps.length,
          'apps': [
            for (final a in apps.take(40))
              {
                'name': a['name'],
                'package': a['package'],
                if ((a['sizeBytes'] as int) > 0)
                  'sizeMB': ((a['sizeBytes'] as int) / (1024 * 1024)).round(),
              }
          ],
        };
      case 'uninstall_app':
        return (await _apps.uninstallApp(argString(args, 'packageName')!))
            ? {'success': true}
            : {'error': 'Couldn\'t open the uninstall dialog for that package.'};
      case 'search_play_store':
        return (await _apps.searchPlayStore(argString(args, 'query')!))
            ? {'success': true}
            : {'error': 'Couldn\'t open the Play Store.'};
      case 'get_public_ip':
        return _search.getPublicIP();
    }
    return {'error': 'Unknown tool "$name".'};
  }

  /// Human-readable description of a sensitive action for the confirm
  /// dialog.
  static ToolConfirmation confirmationFor(String name, Map<String, dynamic> args) {
    switch (name) {
      case 'make_phone_call':
        return ToolConfirmation(name, 'Call ${argString(args, 'phone')}?',
            'Opens the dialer. You still press the call button.');
      case 'send_whatsapp':
        return ToolConfirmation(name, 'WhatsApp ${argString(args, 'phone')}?',
            '"${argString(args, 'message') ?? ''}"');
      case 'schedule_event':
        final start = parseLocalDateTime(argString(args, 'start') ?? '');
        return ToolConfirmation(
          name,
          'Add "${argString(args, 'title')}" to your calendar?',
          start == null ? 'Time: ${argString(args, 'start')}' : 'On ${describeDateTime(start)}',
        );
      case 'uninstall_app':
        return ToolConfirmation(name, 'Uninstall ${argString(args, 'packageName')}?',
            'Opens Android\'s uninstall dialog.');
      default:
        return ToolConfirmation(name, 'Allow $name?', jsonEncode(args));
    }
  }

  /// A finished sentence for tools whose result is easy to state. Used for
  /// instant commands and by the on-device backend (small models are slow and
  /// unreliable at summarising JSON). Returns null when the model should
  /// summarise instead (e.g. web search results).
  static String? formatDirect(
      String name, Map<String, dynamic> args, Map<String, dynamic> r) {
    if (r['cancelled'] == true) return 'Okay, I didn\'t do that.';
    final error = r['error'];
    if (error is String) {
      if (name == 'search_web' || name == 'launch_app_by_name') {
        return name == 'launch_app_by_name' ? _appNotFound(args, r) : null;
      }
      return error;
    }
    switch (name) {
      case 'toggle_flashlight':
        return 'Flashlight ${r['on'] == true ? 'on' : 'off'}.';
      case 'set_timer':
        return 'Timer set for ${describeDuration(r['seconds'] as int)}.';
      case 'set_alarm':
        return 'Alarm set for ${formatClock(r['hour'] as int, r['minute'] as int)}.';
      case 'set_volume':
        return 'Volume set to ${r['percent']}%.';
      case 'vibrate':
        return 'Buzz!';
      case 'open_url':
        return 'Opening ${Uri.parse('${r['url']}').host}.';
      case 'launch_app_by_name':
        return 'Opening ${r['appName']}.';
      case 'make_phone_call':
        return 'Opening the dialer for ${r['phone']}.';
      case 'send_whatsapp':
        return 'WhatsApp is open with your message — tap send.';
      case 'copy_to_clipboard':
        return 'Copied to clipboard.';
      case 'read_clipboard':
        final text = r['text'];
        return text == null ? 'Your clipboard is empty.' : 'Your clipboard says: "$text"';
      case 'search_play_store':
        return 'Opened the Play Store.';
      case 'uninstall_app':
        return 'The uninstall dialog is open.';
      case 'schedule_event':
        final start = DateTime.tryParse('${r['start']}');
        return 'Added to your ${r['calendar']} calendar'
            '${start == null ? '' : ' for ${describeDateTime(start)}'}.';
      case 'get_date_time':
        return 'It\'s ${r['time12']} on ${r['date']}.';
      case 'get_public_ip':
        return 'Your public IP address is ${r['ip']}.';
      case 'get_device_info':
        final battery = r['batteryPercent'];
        final parts = <String>[
          if (battery is num)
            'Battery is at $battery%${r['charging'] == true ? ' and charging' : ''}',
          if (r['storageFreeGB'] != null)
            '${r['storageFreeGB']} GB of ${r['storageTotalGB']} GB storage free',
          if (r['ramTotalGB'] != null) '${r['ramTotalGB']} GB RAM',
          if (r['model'] != null)
            '${r['manufacturer']} ${r['model']}'
                '${r['androidVersion'] != null ? ' on Android ${r['androidVersion']}' : ''}',
        ];
        return parts.isEmpty ? null : '${parts.join('. ')}.';
      case 'check_connectivity':
        if (r['online'] != true) {
          return 'You\'re offline (connection: ${r['connection']}).';
        }
        return 'You\'re online via ${r['connection']}'
            '${r['latencyMs'] != null ? ' (${r['latencyMs']} ms latency)' : ''}.';
      case 'get_weather':
        final place = r['location'] != null ? ' in ${r['location']}' : '';
        final today = (r['forecast'] as List?)?.firstOrNull;
        final range = today is Map && today['minC'] != null
            ? ' Today: ${today['minC']}–${today['maxC']}°C'
                '${today['rainChancePercent'] != null ? ', ${today['rainChancePercent']}% chance of rain' : ''}.'
            : '';
        return 'It\'s ${r['temperatureC']}°C and ${'${r['condition']}'.toLowerCase()}$place '
            '(feels like ${r['feelsLikeC']}°C).$range';
      case 'search_contacts':
        final contacts = (r['contacts'] as List?) ?? const [];
        if (contacts.isEmpty) return 'No contacts match "${argString(args, 'query')}".';
        return [
          'Found ${r['count']} contact${r['count'] == 1 ? '' : 's'}:',
          for (final c in contacts.take(5))
            '• ${c['name']}: ${(c['phones'] as List).isEmpty ? 'no number' : (c['phones'] as List).join(', ')}',
        ].join('\n');
      case 'read_notifications':
        final items = (r['notifications'] as List?) ?? const [];
        if (items.isEmpty) return 'You have no notifications.';
        return [
          'You have ${items.length} notification${items.length == 1 ? '' : 's'}:',
          for (final n in items.take(8))
            '• **${n['app']}**: ${[n['title'], n['text']].where((s) => '$s'.isNotEmpty).join(' — ')}',
        ].join('\n');
      case 'get_recent_screenshots':
        return 'Here\'s your latest screenshot.';
      case 'list_apps':
        final apps = (r['apps'] as List?) ?? const [];
        final sized = apps.where((a) => a['sizeMB'] != null).take(5).toList();
        if (sized.isEmpty) return 'You have ${r['total']} apps installed.';
        return [
          'You have ${r['total']} apps. The largest:',
          for (final a in sized) '• ${a['name']} — ${a['sizeMB']} MB',
        ].join('\n');
      case 'list_files':
        final files = (r['files'] as List?) ?? const [];
        if (files.isEmpty) return 'I couldn\'t find any matching files. ${r['note'] ?? ''}'.trim();
        return [
          'Found ${r['total']} file${r['total'] == 1 ? '' : 's'}. Most recent:',
          for (final f in files.take(5)) '• ${f['name']} (${f['sizeKB']} KB)',
        ].join('\n');
    }
    return null;
  }

  static String _appNotFound(Map<String, dynamic> args, Map<String, dynamic> r) {
    final suggestions = (r['suggestions'] as List?)?.cast<String>() ?? const [];
    final name = argString(args, 'appName') ?? 'that app';
    return suggestions.isEmpty
        ? 'I couldn\'t find an app called "$name" on this phone.'
        : 'I couldn\'t find "$name". Did you mean ${suggestions.join(', ')}?';
  }

  /// Shrinks a tool result so it fits a model's context budget. Long lists
  /// are cut first (keeping valid JSON), then long strings.
  static Map<String, dynamic> fitToBudget(Map<String, dynamic> result, int maxChars) {
    if (jsonEncode(result).length <= maxChars) return result;
    final copy = <String, dynamic>{...result};
    for (final key in copy.keys.toList()) {
      final v = copy[key];
      if (v is List && v.length > 3) {
        var n = v.length;
        while (n > 1 && jsonEncode({...copy, key: v.take(n).toList()}).length > maxChars) {
          n = (n * 2 / 3).floor();
        }
        copy[key] = v.take(n).toList();
        copy['truncated'] = true;
      }
    }
    if (jsonEncode(copy).length <= maxChars) return copy;
    final text = jsonEncode(copy);
    return {'summary': text.substring(0, maxChars - 60), 'truncated': true};
  }

  // ── formatting helpers ───────────────────────────────────────────────────

  static const _weekdays = [
    'Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday', 'Sunday'
  ];
  static const _months = [
    'January', 'February', 'March', 'April', 'May', 'June', 'July',
    'August', 'September', 'October', 'November', 'December'
  ];

  static Map<String, dynamic> dateTimeInfo(DateTime now) {
    final offset = now.timeZoneOffset;
    final sign = offset.isNegative ? '-' : '+';
    final h = offset.inHours.abs().toString().padLeft(2, '0');
    final m = (offset.inMinutes.abs() % 60).toString().padLeft(2, '0');
    return {
      'date': '${_weekdays[now.weekday - 1]}, ${now.day} ${_months[now.month - 1]} ${now.year}',
      'time24': '${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}',
      'time12': formatClock(now.hour, now.minute),
      'iso': now.toIso8601String().substring(0, 19),
      'timezone': '${now.timeZoneName} (UTC$sign$h:$m)',
    };
  }

  static String formatClock(int hour, int minute) {
    final h12 = hour % 12 == 0 ? 12 : hour % 12;
    return '$h12:${minute.toString().padLeft(2, '0')} ${hour < 12 ? 'AM' : 'PM'}';
  }

  static String describeDateTime(DateTime t) =>
      '${_weekdays[t.weekday - 1].substring(0, 3)} ${t.day} ${_months[t.month - 1].substring(0, 3)}, '
      '${formatClock(t.hour, t.minute)}';

  static String describeDuration(int seconds) {
    final h = seconds ~/ 3600;
    final m = (seconds % 3600) ~/ 60;
    final s = seconds % 60;
    String unit(int n, String word) => '$n $word${n == 1 ? '' : 's'}';
    return [
      if (h > 0) unit(h, 'hour'),
      if (m > 0) unit(m, 'minute'),
      if (s > 0) unit(s, 'second'),
    ].join(' ');
  }

  /// Parses ISO-8601 and "YYYY-MM-DD HH:MM" as local time.
  static DateTime? parseLocalDateTime(String raw) {
    final t = DateTime.tryParse(raw.trim().replaceFirst(' ', 'T'));
    if (t == null) return null;
    return t.isUtc ? t.toLocal() : t;
  }

  static String _clip(String s, int max) => s.length <= max ? s : '${s.substring(0, max)}…';
}
