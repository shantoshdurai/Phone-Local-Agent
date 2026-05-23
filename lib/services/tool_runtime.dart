import 'dart:convert';

import 'app_service.dart';
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
class ToolRuntime {
  ToolRuntime._();
  static final ToolRuntime instance = ToolRuntime._();

  final _deviceService = DeviceService();
  final _fileService = FileService();
  // ignore: unused_field
  final _dbService = DatabaseService();
  final _appService = AppService();
  final _utilityService = UtilityService();
  final _personalService = PersonalService();
  final _searchService = SearchService();

  /// Dispatch a tool by name. Returns a JSON-shaped map. Never throws — any
  /// error is captured as `{'error': '<message>'}` so the model can react
  /// rather than the surrounding stream blowing up.
  Future<Map<String, dynamic>> execute(
      String name, Map<String, dynamic> args) async {
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
            final extFilter =
                (args['extension'] as String?)?.trim().toLowerCase();
            var filtered = all;
            if (extFilter != null && extFilter.isNotEmpty) {
              final wanted = extFilter.startsWith('.')
                  ? extFilter.substring(1)
                  : extFilter;
              filtered =
                  all.where((f) => f.type.toLowerCase() == wanted).toList();
            }
            final sortBy = (args['sortBy'] as String?)?.trim().toLowerCase() ??
                'modified';
            switch (sortBy) {
              case 'name':
                filtered.sort((a, b) => a.name.compareTo(b.name));
                break;
              case 'size':
                filtered.sort((a, b) => b.size.compareTo(a.size));
                break;
              case 'modified':
              default:
                filtered
                    .sort((a, b) => b.modifiedDate.compareTo(a.modifiedDate));
            }
            return {
              'files': filtered
                  .take(30)
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
          return {
            'success': await _utilityService
                .toggleFlashlight(args['on'] as bool? ?? true)
          };
        case 'list_apps':
          final apps = await _appService.getInstalledApps();
          apps.sort((a, b) => (b['sizeBytes'] as int? ?? 0)
              .compareTo(a['sizeBytes'] as int? ?? 0));
          return {
            'apps': apps.take(60).map((a) {
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
          final pkg = args['packageName'] as String? ?? '';
          if (pkg.isEmpty) return {'error': 'packageName required'};
          return {'success': await _appService.launchApp(pkg)};
        case 'uninstall_app':
          final pkg = args['packageName'] as String? ?? '';
          if (pkg.isEmpty) return {'error': 'packageName required'};
          return {'success': await _appService.uninstallApp(pkg)};
        case 'search_play_store':
          final query = args['query'] as String? ?? '';
          if (query.isEmpty) return {'error': 'query required'};
          await _appService.searchPlayStore(query);
          return {'success': true};
        case 'open_play_store':
          final pkg = args['packageName'] as String? ?? '';
          if (pkg.isEmpty) return {'error': 'packageName required'};
          return {'success': await _appService.openPlayStore(pkg)};
        case 'vibrate':
          final duration = (args['duration'] as num?)?.toInt() ?? 500;
          await _utilityService.vibrate(duration: duration);
          return {'success': true, 'duration': duration};
        case 'set_volume':
          final level = (args['level'] as num?)?.toDouble() ?? 0.5;
          await _utilityService.setVolume(level);
          return {'success': true, 'level': level};
        case 'copy_to_clipboard':
          final text = args['text'] as String? ?? '';
          if (text.isEmpty) return {'error': 'text required'};
          await _utilityService.copyToClipboard(text);
          return {'success': true};
        case 'read_clipboard':
          return {
            'text': await _utilityService.readFromClipboard() ??
                'Clipboard is empty'
          };
        case 'check_connectivity':
          return await _utilityService.checkConnectivityDetailed();
        case 'search_web':
          final query = args['query'] as String? ?? '';
          if (query.isEmpty) return {'error': 'query required'};
          final raw = await _searchService.searchWeb(query);
          return truncate(raw, 1500);
        case 'open_url':
          final url = args['url'] as String? ?? '';
          if (url.isEmpty) return {'error': 'url required'};
          return {'success': await _utilityService.openUrl(url)};
        case 'make_phone_call':
          final phone = args['phone'] as String? ?? '';
          if (phone.isEmpty) return {'error': 'phone number required'};
          return {'success': await _utilityService.makePhoneCall(phone)};
        case 'launch_app_by_name':
          final appName = args['appName'] as String? ?? '';
          if (appName.isEmpty) return {'error': 'appName required'};
          return await _appService.launchAppByName(appName);
        case 'get_recent_screenshots':
          return {'screenshots': await _fileService.getRecentScreenshots()};
        case 'search_contacts':
          return {
            'contacts': await _personalService
                .searchContacts(args['query'] as String? ?? '')
          };
        case 'schedule_event':
          final title = args['title'] as String? ?? '';
          final startStr = args['start'] as String? ?? '';
          final endStr = args['end'] as String? ?? '';
          if (title.isEmpty || startStr.isEmpty || endStr.isEmpty) {
            return {'error': 'title, start, and end are required'};
          }
          try {
            return {
              'success': await _personalService.scheduleEvent(
                title: title,
                start: DateTime.parse(startStr),
                end: DateTime.parse(endStr),
                description: args['description'] as String?,
              )
            };
          } catch (e) {
            return {'error': 'Invalid date format: $e'};
          }
        case 'send_whatsapp':
          final phone = args['phone'] as String? ?? '';
          final message = args['message'] as String? ?? '';
          if (phone.isEmpty || message.isEmpty) {
            return {'error': 'phone and message required'};
          }
          return {
            'success': await _personalService.sendWhatsApp(phone, message)
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
        final on = args['on'] as bool? ?? true;
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
        return text == 'Clipboard is empty'
            ? 'Your clipboard is empty.'
            : 'Clipboard contains: "$text"';

      case 'open_url':
        return result['success'] == true
            ? 'Opening in your browser.'
            : 'Could not open that URL.';

      case 'make_phone_call':
        return result['success'] == true
            ? 'Initiating phone call...'
            : 'Could not initiate phone call.';

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
        return 'Opened Play Store search.';

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

      default:
        return null;
    }
  }

  /// Trim a tool-result map so a single response can't blow out the model's
  /// context window. Used by both the local (4K KV) and cloud paths.
  Map<String, dynamic> truncate(Map<String, dynamic> result, int maxChars) {
    final encoded = jsonEncode(result);
    if (encoded.length <= maxChars) return result;
    return {
      'summary': encoded.substring(0, maxChars),
      'note': 'Result truncated to fit context window.',
    };
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
];
