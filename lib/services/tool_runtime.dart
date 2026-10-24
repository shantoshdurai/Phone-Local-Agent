import 'dart:async';
import 'dart:convert';

import 'app_service.dart';
import 'app_settings.dart';
import 'database_service.dart';
import 'device_service.dart';
import 'file_service.dart';
import 'personal_service.dart';
import 'search_service.dart';
import 'utility_service.dart';

/// Tool execution + templated reply formatting, shared by the local
/// (flutter_gemma) and cloud (Gemini API) agent paths. Both paths pass the
/// model-emitted name + args to [execute], and both consult [formatDirect]
/// for trivially summarizable results.
///
/// Lives outside any specific LLM SDK so neither side gets coupled to the
/// other's `Tool` / `FunctionDeclaration` types.
/// Coercion helpers for model-supplied arguments.
///
/// A small model asked for a boolean will happily emit `"true"`, `1`, or
/// `"yes"`; asked for a number it may send `"50%"` or `"0.5"`. The previous
/// implementation used `args['on'] as bool?`, which threw a `TypeError` that
/// surfaced as a generic tool error — the tool never ran and the model blamed
/// the device. Everything is normalised here instead.
class _Arg {
  final Map<String, dynamic> raw;
  const _Arg(this.raw);

  bool? boolean(List<String> keys) {
    for (final k in keys) {
      final v = raw[k];
      if (v == null) continue;
      if (v is bool) return v;
      if (v is num) return v != 0;
      final s = v.toString().trim().toLowerCase();
      if (s == 'true' || s == 'on' || s == 'yes' || s == '1') return true;
      if (s == 'false' || s == 'off' || s == 'no' || s == '0') return false;
    }
    return null;
  }

  int? integer(List<String> keys) {
    for (final k in keys) {
      final v = raw[k];
      if (v == null) continue;
      if (v is int) return v;
      if (v is double) return v.round();
      final s = v.toString().replaceAll(RegExp(r'[^0-9.\-]'), '').trim();
      final d = double.tryParse(s);
      if (d != null) return d.round();
    }
    return null;
  }

  double? number(List<String> keys) {
    for (final k in keys) {
      final v = raw[k];
      if (v == null) continue;
      if (v is num) return v.toDouble();
      final s = v.toString().trim();
      final d = double.tryParse(s.replaceAll('%', '').trim());
      if (d != null) return d;
    }
    return null;
  }

  /// Percent-aware 0..1 coercion for volume-style values. `50`, `0.5` and
  /// `"50%"` all become `0.5`.
  double? fraction(List<String> keys) {
    final n = number(keys);
    if (n == null) return null;
    final v = n > 1.0 ? n / 100.0 : n;
    return v.clamp(0.0, 1.0);
  }

  String? text(List<String> keys) {
    for (final k in keys) {
      final v = raw[k];
      if (v == null) continue;
      final s = v.toString().trim();
      if (s.isNotEmpty) return s;
    }
    return null;
  }
}

class ToolRuntime {
  ToolRuntime._();
  static final ToolRuntime instance = ToolRuntime._();

  /// Tools that change something outside the app or contact another person.
  /// With "Confirm before actions" on (the default) the UI is asked first.
  static const Set<String> destructiveTools = {
    'uninstall_app',
    'make_phone_call',
    'send_whatsapp',
    'schedule_event',
  };

  /// Installed by the chat screen. Returns true when the user approves.
  /// Null in contexts with no UI (e.g. a headless turn) — those proceed, which
  /// matches the previous behaviour when the setting is off.
  static Future<bool> Function(String tool, Map<String, dynamic> args)?
      confirmAction;

  final _deviceService = DeviceService();
  final _fileService = FileService();
  final _dbService = DatabaseService();
  final _appService = AppService();
  final _utilityService = UtilityService();
  final _personalService = PersonalService();
  final _searchService = SearchService();

  /// Hard ceiling for a single tool call. Several tools touch the network or
  /// the filesystem; without a deadline one stalled request blocks the whole
  /// turn with no way for the user to recover except killing the app.
  static const Duration _deadline = Duration(seconds: 20);

  /// Dispatch a tool by name. Returns a JSON-shaped map. Never throws — any
  /// error is captured as `{'error': '<message>'}` so the model can react
  /// rather than the surrounding stream blowing up.
  Future<Map<String, dynamic>> execute(
      String name, Map<String, dynamic> args) async {
    try {
      if (AppSettings.confirmBeforeActions &&
          destructiveTools.contains(name) &&
          confirmAction != null) {
        final approved = await confirmAction!(name, args);
        if (!approved) {
          return {
            'error': 'The user cancelled this action.',
            'cancelled': true,
          };
        }
      }
      final result = await _dispatch(name, args).timeout(_deadline);
      return _shrink(result);
    } on TimeoutException {
      return {
        'error': '$name took too long and was stopped. '
            'Try a narrower or offline request.'
      };
    } catch (e) {
      return {'error': 'Tool failed: $e'};
    }
  }

  Future<Map<String, dynamic>> _dispatch(
      String name, Map<String, dynamic> args) async {
    final a = _Arg(args);
    try {
      switch (name) {
        case 'get_date_time':
          final now = DateTime.now();
          const days = [
            'Monday', 'Tuesday', 'Wednesday', 'Thursday',
            'Friday', 'Saturday', 'Sunday'
          ];
          return {
            'date':
                '${now.year}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}',
            'time':
                '${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}',
            'dayOfWeek': days[now.weekday - 1],
            'timezone': now.timeZoneName,
          };
        case 'get_device_info':
          return await _deviceService.getDeviceInfo();
        case 'get_public_ip':
          return await _searchService.getPublicIP();
        case 'list_files':
          {
            final all = await _fileService.indexDocuments();
            final extFilter = a.text(['extension', 'ext'])?.toLowerCase();
            var filtered = all;
            if (extFilter != null && extFilter.isNotEmpty) {
              final wanted = extFilter.startsWith('.')
                  ? extFilter.substring(1)
                  : extFilter;
              filtered =
                  all.where((f) => f.type.toLowerCase() == wanted).toList();
            }
            final sortBy =
                (a.text(['sortBy', 'sort']) ?? 'modified').toLowerCase();
            switch (sortBy) {
              case 'name':
                filtered.sort((x, y) => x.name.compareTo(y.name));
                break;
              case 'size':
                filtered.sort((x, y) => y.size.compareTo(x.size));
                break;
              case 'modified':
              default:
                filtered
                    .sort((x, y) => y.modifiedDate.compareTo(x.modifiedDate));
            }
            return {
              // 20 rows keeps the tool response inside a 1280-token KV window
              // once the model echoes it back.
              'files': filtered
                  .take(20)
                  .map((f) => {
                        'name': f.name,
                        'path': f.path,
                        'sizeKB': (f.size / 1024).round(),
                        'modified': f.modifiedDate.toIso8601String(),
                      })
                  .toList(),
              'total': filtered.length,
              'filterExtension': extFilter,
              'sortedBy': sortBy,
            };
          }
        case 'toggle_flashlight':
          final on = a.boolean(['on', 'enabled', 'state']);
          if (on == null) {
            return {
              'error': 'Missing required argument "on" (true to turn on, '
                  'false to turn off).'
            };
          }
          return {'success': await _utilityService.toggleFlashlight(on)};
        case 'list_apps':
          final apps = await _appService.getInstalledApps();
          apps.sort((a, b) => (b['sizeBytes'] as int? ?? 0)
              .compareTo(a['sizeBytes'] as int? ?? 0));
          return {
            'apps': apps.take(30).map((a) {
              final bytes = a['sizeBytes'] as int? ?? 0;
              final mb = bytes > 0 ? (bytes / (1024 * 1024)) : 0;
              return {
                'name': a['name'],
                'pkg': a['packageName'],
                'sizeMB': mb > 0 ? double.parse(mb.toStringAsFixed(1)) : null,
              };
            }).toList(),
            'total': apps.length,
            'sortedBySizeDesc': true,
          };
        case 'launch_app':
          final pkg = a.text(['packageName', 'package', 'pkg']);
          if (pkg == null) return {'error': 'packageName required'};
          return {'success': await _appService.launchApp(pkg)};
        case 'uninstall_app':
          final pkg = a.text(['packageName', 'package', 'pkg']);
          if (pkg == null) return {'error': 'packageName required'};
          return {'success': await _appService.uninstallApp(pkg)};
        case 'search_play_store':
          final query = a.text(['query', 'q']);
          if (query == null) return {'error': 'query required'};
          final opened = await _appService.searchPlayStore(query);
          return {'success': opened};
        case 'open_play_store':
          final pkg = a.text(['packageName', 'package', 'pkg']);
          if (pkg == null) return {'error': 'packageName required'};
          return {'success': await _appService.openPlayStore(pkg)};
        case 'vibrate':
          final duration = (a.integer(['duration', 'milliseconds', 'ms']) ?? 500)
              .clamp(50, 5000);
          await _utilityService.vibrate(duration: duration);
          return {'success': true, 'duration': duration};
        case 'set_volume':
          final level = a.fraction(['level', 'volume', 'percent']);
          if (level == null) {
            return {'error': 'Missing required argument "level" (0.0–1.0).'};
          }
          await _utilityService.setVolume(level);
          return {'success': true, 'level': level};
        case 'copy_to_clipboard':
          final text = a.text(['text', 'content']);
          if (text == null) return {'error': 'text required'};
          await _utilityService.copyToClipboard(text);
          return {'success': true};
        case 'read_clipboard':
          final clip = await _utilityService.readFromClipboard();
          if (clip == null) {
            return {
              'text': '',
              'note': 'Clipboard is empty or blocked by Android because the '
                  'app is not in the foreground.'
            };
          }
          // Never forward an unbounded clipboard: it is the most likely place
          // for an OTP, password or address, and it would also blow the KV
          // window.
          final capped =
              clip.length > 400 ? '${clip.substring(0, 400)}…' : clip;
          return {
            'text': capped,
            if (clip.length > 400) 'truncated': true,
          };
        case 'check_connectivity':
          return await _utilityService.checkConnectivityDetailed();
        case 'search_web':
          final query = a.text(['query', 'q']);
          if (query == null) return {'error': 'query required'};
          final raw = await _searchService.searchWeb(query);
          return truncate(raw, 1500);
        case 'open_url':
          final url = a.text(['url', 'link']);
          if (url == null) return {'error': 'url required'};
          // Allowlist schemes: the model must not be able to emit
          // `intent://`, `file://` or `javascript:` and reach into other apps.
          final uri = Uri.tryParse(url);
          final okScheme = uri != null &&
              (uri.scheme == 'http' || uri.scheme == 'https');
          if (!okScheme) {
            return {'error': 'Only http(s) URLs can be opened.'};
          }
          return {'success': await _utilityService.openUrl(url)};
        case 'make_phone_call':
          final phone = a.text(['phone', 'number']);
          if (phone == null) return {'error': 'phone number required'};
          return {'success': await _utilityService.makePhoneCall(phone)};
        case 'set_alarm':
          final hour = a.integer(['hour', 'h']);
          final minute = a.integer(['minute', 'minutes', 'm']);
          final message = a.text(['message', 'label']) ?? 'Alarm';
          if (hour == null || minute == null) {
            return {'error': 'hour and minute required'};
          }
          if (hour < 0 || hour > 23 || minute < 0 || minute > 59) {
            return {'error': 'hour must be 0–23 and minute 0–59.'};
          }
          return {'success': await _utilityService.setAlarm(hour, minute, message)};
        case 'set_timer':
          final seconds = a.integer(['seconds', 'duration', 's']);
          final message = a.text(['message', 'label']) ?? 'Timer';
          if (seconds == null) return {'error': 'seconds required'};
          if (seconds <= 0 || seconds > 86400) {
            return {'error': 'seconds must be between 1 and 86400.'};
          }
          return {'success': await _utilityService.setTimer(seconds, message)};
        case 'read_notifications':
          return await _utilityService.readNotifications();
        case 'launch_app_by_name':
          final appName = a.text(['appName', 'app_name', 'name', 'app']);
          if (appName == null) return {'error': 'appName required'};
          return await _appService.launchAppByName(appName);
        case 'get_recent_screenshots':
          return {'screenshots': await _fileService.getRecentScreenshots()};
        case 'search_contacts':
          final query = a.text(['query', 'name', 'q']);
          if (query == null) {
            // Without this guard `contains('')` matches every contact and the
            // whole address book lands in the prompt (and in the cloud path,
            // at Google).
            return {
              'error': 'A contact name is required.',
              'contacts': const [],
            };
          }
          final found = await _personalService.searchContacts(query);
          return {
            'contacts': found.take(5).toList(),
            'total': found.length,
          };
        case 'schedule_event':
          final title = a.text(['title', 'name']);
          final startStr = a.text(['start', 'startTime']);
          final endStr = a.text(['end', 'endTime']);
          if (title == null || startStr == null || endStr == null) {
            return {'error': 'title, start, and end are required'};
          }
          try {
            final start = DateTime.parse(startStr);
            final end = DateTime.parse(endStr);
            if (!end.isAfter(start)) {
              return {'error': 'The event must end after it starts.'};
            }
            return {
              'success': await _personalService.scheduleEvent(
                title: title,
                start: start,
                end: end,
                description: a.text(['description', 'notes']),
              )
            };
          } catch (e) {
            return {'error': 'Invalid date format: $e'};
          }
        case 'send_whatsapp':
          final phone = a.text(['phone', 'number']);
          final message = a.text(['message', 'text']);
          if (phone == null || message == null) {
            return {'error': 'phone and message required'};
          }
          return {
            'success': await _personalService.sendWhatsApp(phone, message)
          };
        case 'get_weather':
          final loc = a.text(['location', 'city', 'place']) ?? '';
          return await _utilityService.getWeather(loc);
        case 'create_note':
          final body = a.text(['body', 'text', 'content', 'note']);
          if (body == null) return {'error': 'Note text is required.'};
          final title = a.text(['title']) ??
              (body.length > 40 ? '${body.substring(0, 40)}…' : body);
          final id = await _dbService.insertNote(title, body);
          return {'success': true, 'id': id, 'title': title};
        case 'list_notes':
          final notes =
              await _dbService.getNotes(limit: a.integer(['limit']) ?? 10);
          return {
            'notes': notes
                .map((n) => {
                      'title': n['title'],
                      'body': n['body'],
                      'created': n['created_at'],
                    })
                .toList(),
            'total': notes.length,
          };
        case 'delete_note':
          final query = a.text(['title', 'query', 'text']);
          if (query == null) {
            return {'error': 'Which note? Pass a title or phrase from it.'};
          }
          final deleted = await _dbService.deleteNotes(query);
          return {'success': deleted > 0, 'deleted': deleted, 'query': query};
        case 'open_settings':
          final section = a.text(['section', 'screen']) ?? 'settings';
          return {'success': await _utilityService.openSettings(section)};
        case 'send_sms':
          final phone = a.text(['phone', 'number']);
          final message = a.text(['message', 'text']);
          if (phone == null || message == null) {
            return {'error': 'phone and message required'};
          }
          return {
            'success': await _utilityService.sendSms(phone, message),
          };
        case 'compose_email':
          final to = a.text(['to', 'email', 'address']);
          if (to == null) return {'error': 'Recipient email required.'};
          return {
            'success': await _utilityService.composeEmail(
              to: to,
              subject: a.text(['subject']),
              body: a.text(['body', 'message']),
            ),
          };
        default:
          return {'error': 'Unknown tool: $name'};
      }
    } catch (e) {
      return {'error': e.toString()};
    }
  }

  /// Direct templated reply for tools whose results are trivially stringifiable.
  /// Returning null means "let the model summarize". Returning a string means
  /// "skip the follow-up model call and use this verbatim".
  String? formatDirect(
      String toolName, Map<String, dynamic> args, Map<String, dynamic> result) {
    if (result.containsKey('error')) return null;

    switch (toolName) {
      case 'toggle_flashlight':
        final on = _Arg(args).boolean(['on', 'enabled', 'state']) ?? true;
        return result['success'] == true
            ? 'Flashlight turned ${on ? "on" : "off"}.'
            : 'Could not toggle flashlight. Another app may be using the camera.';

      case 'vibrate':
        final ms = result['duration'] as int? ?? 500;
        final secs = ms / 1000.0;
        final label = secs == secs.truncateToDouble()
            ? '${secs.toInt()} second${secs.toInt() == 1 ? "" : "s"}'
            : '${secs.toStringAsFixed(1)} seconds';
        return 'Phone vibrated for $label.';

      case 'set_volume':
        final pct = ((result['level'] as num?)?.toDouble() ?? 0.5) * 100;
        return 'Volume set to ${pct.toStringAsFixed(0)}%.';

      case 'copy_to_clipboard':
        return 'Copied to clipboard.';

      case 'read_clipboard':
        final text = result['text'] as String? ?? '';
        if (text.isEmpty) {
          return 'Your clipboard is empty (or Android blocked the read '
              'because the app was in the background).';
        }
        return 'Clipboard contains: "$text"';

      case 'open_url':
        return result['success'] == true
            ? 'Opening in your browser.'
            : 'Could not open that URL.';

      case 'make_phone_call':
        return result['success'] == true
            ? 'Initiating phone call...'
            : 'Could not initiate phone call.';

      case 'set_alarm':
        return result['success'] == true
            ? 'Your clock app is open with the alarm ready — tap Save.'
            : 'Could not open the clock app.';

      case 'set_timer':
        return result['success'] == true
            ? 'Your clock app is open with the timer ready — tap Start.'
            : 'Could not open the clock app.';

      case 'launch_app':
        return result['success'] == true
            ? 'App launched.'
            : 'Could not launch that app.';

      case 'launch_app_by_name':
        if (result['success'] == true) {
          return '${result['appName'] ?? 'App'} opened.';
        }
        final suggestions =
            (result['suggestions'] as List?)?.cast<String>() ?? [];
        return suggestions.isNotEmpty
            ? 'App not found. Did you mean: ${suggestions.join(', ')}?'
            : 'App not found on this device.';

      case 'uninstall_app':
        return result['success'] == true
            ? 'Uninstall dialog opened.'
            : 'Could not initiate uninstall.';

      case 'search_play_store':
        return result['success'] == true
            ? 'Opened Play Store search.'
            : 'Could not open the Play Store on this device.';

      case 'open_play_store':
        return result['success'] == true
            ? 'Opened in Play Store.'
            : 'Could not open Play Store.';

      case 'get_public_ip':
        final ip = result['ip'] as String? ??
            result['query'] as String? ??
            'unknown';
        return 'Your public IP address is $ip.';

      case 'send_whatsapp':
        return result['success'] == true
            ? 'Opening WhatsApp...'
            : 'Could not open WhatsApp. Make sure it is installed.';

      case 'schedule_event':
        return result['success'] == true
            ? 'Event added to your calendar.'
            : 'Could not create the calendar event.';

      case 'create_note':
        return result['success'] == true
            ? 'Saved note “${result['title'] ?? 'note'}”.'
            : 'Could not save the note.';

      case 'delete_note':
        final deleted = result['deleted'] as int? ?? 0;
        return deleted > 0
            ? 'Deleted $deleted note${deleted == 1 ? '' : 's'}.'
            : 'No matching note found.';

      case 'open_settings':
        return result['success'] == true
            ? 'Opened your settings.'
            : 'Could not open settings on this device.';

      case 'send_sms':
        return result['success'] == true
            ? 'SMS composer opened — tap send to deliver it.'
            : 'Could not open the SMS app.';

      case 'compose_email':
        return result['success'] == true
            ? 'Email composer opened — review and send.'
            : 'Could not open the email app.';

      default:
        return null;
    }
  }

  /// Trim a tool-result map so a single response can't blow out the model's
  /// context window. Used by both the local (1280 KV) and cloud paths.
  Map<String, dynamic> truncate(Map<String, dynamic> result, int maxChars) {
    final encoded = jsonEncode(result);
    if (encoded.length <= maxChars) return result;
    return {
      'result': '${encoded.substring(0, maxChars)}…',
      'truncated': true,
      'note': 'Result truncated to fit the context window.',
    };
  }

  /// Structural shrink: keeps the JSON valid (unlike cutting the encoded
  /// string) by trimming long lists and long strings field by field.
  ///
  /// A tool returning 60 apps × full paths used to produce a ~3 KB blob that
  /// the model then echoed back as prefill — 700+ tokens of pure cost on a
  /// 1280-token cache, which is how "no reply at all" happens.
  Map<String, dynamic> _shrink(Map<String, dynamic> result,
      {int maxChars = 2000}) {
    try {
      if (jsonEncode(result).length <= maxChars) return result;
    } catch (_) {
      return result;
    }

    final reduced = <String, dynamic>{};
    result.forEach((key, value) {
      if (value is String) {
        reduced[key] = value.length > 300 ? '${value.substring(0, 300)}…' : value;
      } else if (value is List) {
        reduced[key] = value
            .take(12)
            .map((e) => e is String && e.length > 200
                ? '${e.substring(0, 200)}…'
                : e)
            .toList();
        if (value.length > 12) reduced['${key}_omitted'] = value.length - 12;
      } else {
        reduced[key] = value;
      }
    });
    reduced['truncated'] = true;
    return reduced;
  }
}

/// Neutral tool catalogue — name, description, params schema as plain maps.
/// Each agent path converts these into its SDK's `FunctionDeclaration` /
/// `Tool` type. Source of truth so descriptions don't drift between local
/// and cloud variants.
const List<Map<String, dynamic>> kToolCatalog = [
  {
    'name': 'get_date_time',
    'description':
        'Get the current local date, time, day of the week, and timezone.',
    'parameters': {'type': 'object', 'properties': {}},
  },
  {
    'name': 'get_device_info',
    'description':
        'Get device manufacturer, model, OS version, battery percentage, '
            'free and total storage, and RAM.',
    'parameters': {'type': 'object', 'properties': {}},
  },
  {
    'name': 'check_connectivity',
    'description':
        'Check whether the device is online, the connection type (WiFi or cellular), '
            'WiFi SSID, and local IP address.',
    'parameters': {'type': 'object', 'properties': {}},
  },
  {
    'name': 'get_public_ip',
    'description': 'Get the public IP address of the device.',
    'parameters': {'type': 'object', 'properties': {}},
  },
  {
    'name': 'search_web',
    'description':
        'Search the web for facts, news, weather, sports scores, or anything '
            'that needs up-to-date information.',
    'parameters': {
      'type': 'object',
      'properties': {
        'query': {
          'type': 'string',
          'description': 'The search query in natural language.',
        },
      },
      'required': ['query'],
    },
  },
  {
    'name': 'open_url',
    'description': 'Open a URL in the device default browser.',
    'parameters': {
      'type': 'object',
      'properties': {
        'url': {
          'type': 'string',
          'description': 'The full URL including https://',
        },
      },
      'required': ['url'],
    },
  },
  {
    'name': 'list_files',
    'description':
        'List user files on the device. Filters: `extension` (e.g. "pdf"), '
            '`sortBy` ("modified" | "name" | "size").',
    'parameters': {
      'type': 'object',
      'properties': {
        'extension': {
          'type': 'string',
          'description': 'File extension without leading dot.',
        },
        'sortBy': {
          'type': 'string',
          'description': 'One of: "modified", "name", "size".',
        },
      },
    },
  },
  {
    'name': 'list_apps',
    'description':
        'List installed apps with display name, package, and approximate disk '
            'size in MB. Sorted largest-first.',
    'parameters': {'type': 'object', 'properties': {}},
  },
  {
    'name': 'launch_app_by_name',
    'description': 'Launch an installed app by its display name.',
    'parameters': {
      'type': 'object',
      'properties': {
        'appName': {'type': 'string'},
      },
      'required': ['appName'],
    },
  },
  {
    'name': 'launch_app',
    'description': 'Launch an installed app by its Android package name.',
    'parameters': {
      'type': 'object',
      'properties': {
        'packageName': {'type': 'string'},
      },
      'required': ['packageName'],
    },
  },
  {
    'name': 'uninstall_app',
    'description': 'Open the Android uninstall dialog for the given package.',
    'parameters': {
      'type': 'object',
      'properties': {
        'packageName': {'type': 'string'},
      },
      'required': ['packageName'],
    },
  },
  {
    'name': 'search_play_store',
    'description': 'Search the Google Play Store for an app.',
    'parameters': {
      'type': 'object',
      'properties': {
        'query': {'type': 'string'},
      },
      'required': ['query'],
    },
  },
  {
    'name': 'open_play_store',
    'description': 'Open a specific app page in the Google Play Store.',
    'parameters': {
      'type': 'object',
      'properties': {
        'packageName': {'type': 'string'},
      },
      'required': ['packageName'],
    },
  },
  {
    'name': 'toggle_flashlight',
    'description': 'Turn the device flashlight on or off.',
    'parameters': {
      'type': 'object',
      'properties': {
        'on': {'type': 'boolean'},
      },
      'required': ['on'],
    },
  },
  {
    'name': 'vibrate',
    'description': 'Vibrate the device for the given duration in milliseconds.',
    'parameters': {
      'type': 'object',
      'properties': {
        'duration': {'type': 'integer'},
      },
    },
  },
  {
    'name': 'set_volume',
    'description': 'Set the device media volume (0.0 to 1.0).',
    'parameters': {
      'type': 'object',
      'properties': {
        'level': {'type': 'number'},
      },
      'required': ['level'],
    },
  },
  {
    'name': 'copy_to_clipboard',
    'description': 'Copy text to the device clipboard.',
    'parameters': {
      'type': 'object',
      'properties': {
        'text': {'type': 'string'},
      },
      'required': ['text'],
    },
  },
  {
    'name': 'read_clipboard',
    'description': 'Read whatever text is currently on the device clipboard.',
    'parameters': {'type': 'object', 'properties': {}},
  },
  {
    'name': 'get_recent_screenshots',
    'description': 'Get a list of the recent screenshots on the device.',
    'parameters': {'type': 'object', 'properties': {}},
  },
  {
    'name': 'search_contacts',
    'description':
        'Search the device contacts by name. Returns matching contacts with '
            'their phone numbers and emails.',
    'parameters': {
      'type': 'object',
      'properties': {
        'query': {'type': 'string'},
      },
      'required': ['query'],
    },
  },
  {
    'name': 'schedule_event',
    'description': 'Create a calendar event on the device.',
    'parameters': {
      'type': 'object',
      'properties': {
        'title': {'type': 'string'},
        'start': {
          'type': 'string',
          'description': 'ISO-8601 start datetime.',
        },
        'end': {
          'type': 'string',
          'description': 'ISO-8601 end datetime.',
        },
        'description': {'type': 'string'},
      },
      'required': ['title', 'start', 'end'],
    },
  },
  {
    'name': 'send_whatsapp',
    'description':
        'Open WhatsApp with a prefilled message for a phone number. The phone '
            'must come from search_contacts or directly from the user — never '
            'invent one.',
    'parameters': {
      'type': 'object',
      'properties': {
        'phone': {
          'type': 'string',
          'description': 'Phone number in international format (e.g. +14155551234).',
        },
        'message': {'type': 'string'},
      },
      'required': ['phone', 'message'],
    },
  },
  {
    'name': 'make_phone_call',
    'description':
        'Open the dialer to make a phone call to a specified number. The phone '
            'must come from search_contacts or directly from the user.',
    'parameters': {
      'type': 'object',
      'properties': {
        'phone': {
          'type': 'string',
          'description': 'Phone number to call.',
        },
      },
      'required': ['phone'],
    },
  },
  {
    'name': 'set_alarm',
    'description': 'Set an alarm on the device clock natively.',
    'parameters': {
      'type': 'object',
      'properties': {
        'hour': {
          'type': 'integer',
          'description': 'Hour in 24-hour format (0-23).',
        },
        'minute': {
          'type': 'integer',
          'description': 'Minute (0-59).',
        },
        'message': {
          'type': 'string',
          'description': 'Optional label for the alarm.',
        },
      },
      'required': ['hour', 'minute'],
    },
  },
  {
    'name': 'set_timer',
    'description': 'Set a countdown timer on the device natively.',
    'parameters': {
      'type': 'object',
      'properties': {
        'seconds': {
          'type': 'integer',
          'description': 'Length of the timer in seconds.',
        },
        'message': {
          'type': 'string',
          'description': 'Optional label for the timer.',
        },
      },
      'required': ['seconds'],
    },
  },
  {
    'name': 'read_notifications',
    'description': 'Read the unread notifications from the device. May require the user to grant permission first.',
    'parameters': {'type': 'object', 'properties': {}},
  },
  {
    'name': 'get_weather',
    'description':
        'Get the current weather for a city, or for the user\'s approximate '
            'location when none is given.',
    'parameters': {
      'type': 'object',
      'properties': {
        'location': {
          'type': 'string',
          'description': 'City name. Omit for the current area.',
        },
      },
    },
  },
  {
    'name': 'create_note',
    'description':
        'Save a note on the device. Use for "note this down", "remember to…", '
            'lists and anything the user wants to keep.',
    'parameters': {
      'type': 'object',
      'properties': {
        'title': {'type': 'string', 'description': 'Short title.'},
        'body': {'type': 'string', 'description': 'Full note text.'},
      },
      'required': ['body'],
    },
  },
  {
    'name': 'list_notes',
    'description': 'List the user\'s saved notes, newest first.',
    'parameters': {
      'type': 'object',
      'properties': {
        'limit': {'type': 'integer', 'description': 'How many notes (1-50).'},
      },
    },
  },
  {
    'name': 'delete_note',
    'description': 'Delete notes whose title or body matches a phrase.',
    'parameters': {
      'type': 'object',
      'properties': {
        'query': {
          'type': 'string',
          'description': 'A phrase from the note to delete.',
        },
      },
      'required': ['query'],
    },
  },
  {
    'name': 'open_settings',
    'description':
        'Open a system settings screen: wifi, bluetooth, display, sound, '
            'battery, apps, location or data.',
    'parameters': {
      'type': 'object',
      'properties': {
        'section': {
          'type': 'string',
          'description': 'One of: wifi, bluetooth, display, sound, battery, '
              'apps, location, data, settings.',
        },
      },
      'required': ['section'],
    },
  },
  {
    'name': 'send_sms',
    'description':
        'Open the SMS composer with a number and message prefilled. The user '
            'taps send; the app cannot send silently.',
    'parameters': {
      'type': 'object',
      'properties': {
        'phone': {'type': 'string'},
        'message': {'type': 'string'},
      },
      'required': ['phone', 'message'],
    },
  },
  {
    'name': 'compose_email',
    'description': 'Open the email composer with recipient, subject and body.',
    'parameters': {
      'type': 'object',
      'properties': {
        'to': {'type': 'string', 'description': 'Recipient email address.'},
        'subject': {'type': 'string'},
        'body': {'type': 'string'},
      },
      'required': ['to'],
    },
  },
];
