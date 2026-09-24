import '../tools/tool_runtime.dart';

/// A request recognised well enough to run without the language model.
class QuickCommand {
  final String tool;
  final Map<String, dynamic> args;

  /// When the tool can't do it (no app with that name, contact not found),
  /// hand the message to the model instead of replying with the failure.
  final bool fallThroughOnError;

  /// Custom reply; defaults to [ToolRuntime.formatDirect].
  final String Function(Map<String, dynamic> result)? format;

  const QuickCommand(
    this.tool,
    this.args, {
    this.fallThroughOnError = false,
    this.format,
  });
}

/// Instant, deterministic handling of the most common phone commands.
///
/// This is what makes the app usable on low-end phones: "flashlight on",
/// "timer for 5 minutes", "battery?" run in milliseconds with no model at
/// all. Patterns match the *whole* utterance, so questions like "how do
/// flashlights work?" or compound requests go to the model instead.
class QuickCommands {
  QuickCommands._();

  static QuickCommand? match(String input) {
    final s = normalize(input);
    if (s.isEmpty || s.length > 80) return null;
    for (final matcher in _matchers) {
      final cmd = matcher(s);
      if (cmd != null) return cmd;
    }
    return null;
  }

  /// Lower-cases, strips politeness and trailing punctuation, expands common
  /// contractions. Visible for testing.
  static String normalize(String input) {
    var s = input.toLowerCase().trim();
    s = s.replaceAll(RegExp(r'[’‘]'), "'");
    s = s.replaceAll(RegExp(r'[.!?;:]+$'), '').trim();
    s = s.replaceAll(RegExp(r',\s*'), ' ');
    s = s.replaceAll(RegExp(r'\s+'), ' ');
    s = s.replaceAll(RegExp(r"\bwhat'?s\b"), 'what is');
    s = s.replaceAll(RegExp(r"\bhow'?s\b"), 'how is');
    s = s.replaceAll(RegExp(r"\btoday'?s\b"), 'today');
    const prefixes = [
      'hey agent ', 'ok agent ', 'hey ', 'ok ', 'okay ', 'please ',
      'can you ', 'could you ', 'would you ', 'will you ', 'can u ',
      'i want you to ', 'i need you to ', 'go ahead and ', 'just ',
    ];
    var changed = true;
    while (changed) {
      changed = false;
      for (final p in prefixes) {
        if (s.startsWith(p)) {
          s = s.substring(p.length).trim();
          changed = true;
        }
      }
    }
    for (final suffix in const [' please', ' for me', ' right now', ' now']) {
      if (s.endsWith(suffix)) s = s.substring(0, s.length - suffix.length).trim();
    }
    return s;
  }

  static final List<QuickCommand? Function(String)> _matchers = [
    _flashlight,
    _timer,
    _alarm,
    _volume,
    _vibrate,
    _dateTime,
    _battery,
    _weather,
    _screenshot,
    _clipboard,
    _notifications,
    _publicIp,
    _connectivity,
    _call,
    _openUrl,
    _openApp,
  ];

  // ── flashlight ───────────────────────────────────────────────────────────
  static const _torch = r'(?:flash ?light|torch|flash)';

  static QuickCommand? _flashlight(String s) {
    final patterns = [
      RegExp('^(?:turn|switch|put) (on|off) (?:the |my )?$_torch\$'),
      RegExp('^(?:turn|switch|put) (?:the |my )?$_torch (on|off)\$'),
      RegExp('^$_torch (on|off)\$'),
    ];
    for (final p in patterns) {
      final m = p.firstMatch(s);
      if (m != null) return QuickCommand('toggle_flashlight', {'on': m[1] == 'on'});
    }
    if (RegExp('^(?:enable|activate|light up) (?:the |my )?$_torch\$').hasMatch(s)) {
      return const QuickCommand('toggle_flashlight', {'on': true});
    }
    if (RegExp('^(?:disable|deactivate) (?:the |my )?$_torch\$').hasMatch(s)) {
      return const QuickCommand('toggle_flashlight', {'on': false});
    }
    return null;
  }

  // ── timer ────────────────────────────────────────────────────────────────
  static QuickCommand? _timer(String s) {
    final patterns = [
      RegExp(r'^(?:set|start|create|make) (?:a |an |me a )?timer (?:for |of )?(.+)$'),
      RegExp(r'^(?:set|start|create|make) (?:a |an |me a )?(.+?) timer$'),
      RegExp(r'^timer (?:for )?(.+)$'),
      RegExp(r'^(.+?) timer$'),
    ];
    for (final p in patterns) {
      final m = p.firstMatch(s);
      if (m == null) continue;
      final seconds = parseDuration(m[1]!);
      if (seconds != null && seconds > 0 && seconds <= 86400) {
        return QuickCommand('set_timer', {'seconds': seconds});
      }
    }
    return null;
  }

  static const Map<String, double> _numberWords = {
    'a': 1, 'an': 1, 'one': 1, 'two': 2, 'three': 3, 'four': 4, 'five': 5,
    'six': 6, 'seven': 7, 'eight': 8, 'nine': 9, 'ten': 10, 'eleven': 11,
    'twelve': 12, 'fifteen': 15, 'twenty': 20, 'thirty': 30, 'forty': 40,
    'forty five': 45, 'fifty': 50, 'sixty': 60, 'ninety': 90,
    'half a': 0.5, 'half an': 0.5,
  };

  /// "5 minutes", "1 hour and 30 minutes", "half an hour", "90 sec" →
  /// seconds. Returns null if anything else is in the phrase, so "set a
  /// timer for my workout" doesn't match. Visible for testing.
  static int? parseDuration(String phrase) {
    final unitRe = RegExp(
        r'^(\d+(?:\.\d+)?|forty five|half an?|[a-z]+) ?(seconds?|secs?|s|minutes?|mins?|m|hours?|hrs?|h)\b');
    var rest = phrase.trim();
    var total = 0.0;
    var found = false;
    while (rest.isNotEmpty) {
      final m = unitRe.firstMatch(rest);
      if (m == null) return null;
      final numText = m[1]!;
      final n = double.tryParse(numText) ?? _numberWords[numText];
      if (n == null) return null;
      final unit = m[2]!;
      final mult = unit.startsWith('h')
          ? 3600
          : unit.startsWith('m')
              ? 60
              : 1;
      total += n * mult;
      found = true;
      rest = rest.substring(m.end).trim();
      rest = rest.replaceFirst(RegExp(r'^(?:and|,)\s*'), '').trim();
    }
    return found ? total.round() : null;
  }

  // ── alarm ────────────────────────────────────────────────────────────────
  static QuickCommand? _alarm(String s) {
    final patterns = [
      RegExp(r'^(?:set|create|make) (?:an |the |my |me an )?alarm (?:for |at |to )?(.+)$'),
      RegExp(r'^wake me(?: up)? (?:at )?(.+)$'),
      RegExp(r'^alarm (?:for |at )?(.+)$'),
    ];
    for (final p in patterns) {
      final m = p.firstMatch(s);
      if (m == null) continue;
      final time = parseClockTime(m[1]!);
      if (time != null) {
        return QuickCommand('set_alarm', {'hour': time.$1, 'minute': time.$2});
      }
    }
    return null;
  }

  /// "7", "7am", "6:30 pm", "18:45", "7.15", "noon" → (hour24, minute).
  /// Visible for testing.
  static (int, int)? parseClockTime(String phrase) {
    var p = phrase.trim().replaceAll(RegExp(r'\s+(?:tomorrow|today)$'), '');
    if (p == 'noon' || p == 'midday') return (12, 0);
    if (p == 'midnight') return (0, 0);
    final m = RegExp(
      r"^(\d{1,2})(?:[:.](\d{2}))? ?(?:o'?clock)? ?(am|pm|a\.m|p\.m|in the morning|in the evening|in the afternoon|at night|tonight)?$",
    ).firstMatch(p);
    if (m == null) return null;
    var hour = int.parse(m[1]!);
    final minute = m[2] == null ? 0 : int.parse(m[2]!);
    final meridiem = m[3];
    if (minute > 59) return null;
    if (meridiem != null) {
      if (hour < 1 || hour > 12) return null;
      final pm = meridiem.startsWith('p') ||
          meridiem.contains('evening') ||
          meridiem.contains('afternoon') ||
          meridiem.contains('night');
      if (pm && hour != 12) hour += 12;
      if (!pm && hour == 12) hour = 0;
    }
    if (hour > 23) return null;
    return (hour, minute);
  }

  // ── volume ───────────────────────────────────────────────────────────────
  static QuickCommand? _volume(String s) {
    final pct = RegExp(
            r'^(?:set |change |turn |put )?(?:the |my )?(?:media |music )?volume (?:to |at )?(\d{1,3}) ?(?:%|percent)?$')
        .firstMatch(s);
    if (pct != null) {
      final v = int.parse(pct[1]!);
      if (v <= 100) return QuickCommand('set_volume', {'level': v});
    }
    if (RegExp(r'^(?:set |turn )?(?:the )?volume (?:to )?(?:max|maximum|full)$').hasMatch(s) ||
        RegExp(r'^(?:max|maximum|full) volume$').hasMatch(s)) {
      return const QuickCommand('set_volume', {'level': 100});
    }
    if (RegExp(r'^(?:mute|silence)(?: the| my)?(?: volume| sound| media| phone| music)?$').hasMatch(s)) {
      return const QuickCommand('set_volume', {'level': 0});
    }
    if (RegExp(r'^unmute(?: the| my)?(?: volume| sound| media| phone| music)?$').hasMatch(s)) {
      return const QuickCommand('set_volume', {'level': 50});
    }
    return null;
  }

  // ── vibrate ──────────────────────────────────────────────────────────────
  static QuickCommand? _vibrate(String s) {
    final m = RegExp(r'^(?:vibrate|buzz)(?: my| the)?(?: phone)?(?: for (.+))?$').firstMatch(s);
    if (m == null) return null;
    var ms = 500;
    if (m[1] != null) {
      final seconds = parseDuration(m[1]!);
      if (seconds == null || seconds > 10) return null;
      ms = seconds * 1000;
    }
    return QuickCommand('vibrate', {'duration': ms});
  }

  // ── date & time ──────────────────────────────────────────────────────────
  static QuickCommand? _dateTime(String s) {
    final isTime = RegExp(r'^what (?:is )?(?:the )?time(?: is it)?$').hasMatch(s) ||
        RegExp(r'^what time is it$').hasMatch(s) ||
        RegExp(r'^(?:tell me )?the time$').hasMatch(s) ||
        s == 'time';
    if (isTime) {
      return QuickCommand('get_date_time', const {},
          format: (r) => 'It\'s ${r['time12']}.');
    }
    final isDate = RegExp(r'^what (?:is )?(?:the )?(?:today )?date(?: today)?$').hasMatch(s) ||
        RegExp(r'^what day is (?:it|today)(?: today)?$').hasMatch(s) ||
        RegExp(r'^(?:what is )?today date$').hasMatch(s) ||
        s == 'date';
    if (isDate) {
      return QuickCommand('get_date_time', const {},
          format: (r) => 'Today is ${r['date']}.');
    }
    return null;
  }

  // ── battery ──────────────────────────────────────────────────────────────
  static QuickCommand? _battery(String s) {
    final match = RegExp(
                r'^(?:what is |how is |check |show )?(?:my |the )?(?:phone |phone\x27s )?battery(?: level| percentage| percent| status| life| health)?$')
            .hasMatch(s) ||
        RegExp(r'^how much (?:battery|charge)(?: do i have| is left| left| remaining)?(?: left)?$')
            .hasMatch(s) ||
        RegExp(r'^(?:is my phone|am i) charging$').hasMatch(s);
    if (!match) return null;
    return QuickCommand('get_device_info', const {}, format: (r) {
      final b = r['batteryPercent'];
      if (b is! num) return 'I couldn\'t read the battery level.';
      return 'Battery is at $b%${r['charging'] == true ? ' and charging' : ''}.';
    });
  }

  // ── weather ──────────────────────────────────────────────────────────────
  static QuickCommand? _weather(String s) {
    if (s.contains('tomorrow') || s.contains('week')) return null;
    final patterns = [
      RegExp(r'^(?:what is |how is |check |show )?(?:the )?weather(?: like)?(?: today| outside)?(?: (?:in|at|for) (.+?))?(?: today)?$'),
      RegExp(r'^(?:is it|will it) (?:going to )?rain(?: today)?(?: (?:in|at) (.+?))?(?: today)?$'),
      RegExp(r'^how (?:hot|cold|warm) is it(?: today| outside)?(?: (?:in|at) (.+?))?$'),
    ];
    for (final p in patterns) {
      final m = p.firstMatch(s);
      if (m == null) continue;
      final place = m.groupCount >= 1 ? m[1]?.trim() : null;
      if (place != null && place.split(' ').length > 4) return null;
      return QuickCommand('get_weather', {
        if (place != null && place.isNotEmpty) 'location': place,
      });
    }
    return null;
  }

  // ── misc read-only ───────────────────────────────────────────────────────
  static QuickCommand? _screenshot(String s) {
    if (RegExp(r'^(?:show|open|find|display)(?: me)?(?: my)?(?: the)? (?:last|latest|recent|most recent) screenshot$')
            .hasMatch(s) ||
        RegExp(r'^(?:show|open)(?: me)?(?: my)? screenshots?$').hasMatch(s)) {
      return const QuickCommand('get_recent_screenshots', {});
    }
    return null;
  }

  static QuickCommand? _clipboard(String s) {
    if (RegExp(r'^what is (?:in|on) (?:my |the )?clipboard$').hasMatch(s) ||
        RegExp(r'^(?:read|show)(?: me)? (?:my |the )?clipboard$').hasMatch(s)) {
      return const QuickCommand('read_clipboard', {});
    }
    return null;
  }

  static QuickCommand? _notifications(String s) {
    if (RegExp(r'^(?:read|show|check)(?: me)?(?: my)?(?: new)? notifications$').hasMatch(s) ||
        RegExp(r'^(?:do i have|any) (?:new )?notifications$').hasMatch(s) ||
        s == 'what did i miss') {
      return const QuickCommand('read_notifications', {});
    }
    return null;
  }

  static QuickCommand? _publicIp(String s) {
    if (RegExp(r'^what is my (?:public |external )?ip(?: address)?$').hasMatch(s)) {
      return const QuickCommand('get_public_ip', {});
    }
    return null;
  }

  static QuickCommand? _connectivity(String s) {
    if (RegExp(r'^am i (?:online|connected)(?: to the internet)?$').hasMatch(s) ||
        RegExp(r'^(?:check )?(?:my )?(?:internet|network) (?:connection|status)$').hasMatch(s) ||
        RegExp(r'^do i have internet$').hasMatch(s)) {
      return const QuickCommand('check_connectivity', {});
    }
    return null;
  }

  // ── call ─────────────────────────────────────────────────────────────────
  static QuickCommand? _call(String s) {
    final m = RegExp(r'^(?:call|phone|dial|ring) (.+)$').firstMatch(s);
    if (m == null) return null;
    final target = m[1]!.trim();
    if (RegExp(r'^\+?[\d\s\-()]{5,}$').hasMatch(target)) {
      return QuickCommand('make_phone_call', {'phone': target.replaceAll(' ', '')});
    }
    const notContacts = {'me', 'it', 'him', 'her', 'them', 'back', 'someone', 'you', 'this', 'that'};
    final words = target.split(' ');
    if (words.length > 3 || notContacts.contains(words.first)) return null;
    // Resolved in AgentService: exactly one matching contact → dialer.
    return QuickCommand('call_contact', {'name': target}, fallThroughOnError: true);
  }

  // ── open ─────────────────────────────────────────────────────────────────
  static final _domain = RegExp(r'^(?:https?://)?[a-z0-9-]+(?:\.[a-z0-9-]+)+(?:/\S*)?$');

  static QuickCommand? _openUrl(String s) {
    final m = RegExp(r'^(?:open|go to|visit|browse to|navigate to) (\S+)$').firstMatch(s);
    if (m == null || !_domain.hasMatch(m[1]!)) return null;
    return QuickCommand('open_url', {'url': m[1]!});
  }

  static QuickCommand? _openApp(String s) {
    final m = RegExp(r'^(?:open|launch|start|run) (?:the |my |up )?(.+?)(?: app| application)?$').firstMatch(s);
    if (m == null) return null;
    final target = m[1]!.trim();
    if (target.isEmpty || target.split(' ').length > 3) return null;
    return QuickCommand('launch_app_by_name', {'appName': target}, fallThroughOnError: true);
  }
}
