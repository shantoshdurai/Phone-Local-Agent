/// The single source of truth for every tool the agent can call.
///
/// Both backends read from here: cloud models get the full [ToolSpec.description];
/// small on-device models get the terse [ToolSpec.localDescription] and only a
/// budgeted subset (see [selectToolsForBudget]) because each declaration costs
/// context tokens. Descriptions must only promise data the tool actually
/// returns — a description that mentions a field the tool doesn't produce is
/// an invitation for the model to invent it.
library;

enum ToolTier {
  /// Always offered, even to the smallest local model.
  core,

  /// Everyday phone control; offered while budget remains.
  common,

  /// Specialised or token-heavy; big models only.
  niche,
}

class ToolSpec {
  final String name;
  final String description;
  final String localDescription;
  final Map<String, dynamic> parameters;
  final ToolTier tier;

  /// Contacts people or changes data — confirmed with the user first when
  /// "Confirm before actions" is on.
  final bool sensitive;

  const ToolSpec({
    required this.name,
    required this.description,
    required this.localDescription,
    required this.parameters,
    required this.tier,
    this.sensitive = false,
  });

  List<String> get requiredParams =>
      ((parameters['required'] as List?) ?? const []).cast<String>();
}

const Map<String, dynamic> _noParams = {
  'type': 'object',
  'properties': <String, dynamic>{},
};

const List<ToolSpec> kToolCatalog = [
  // ── core ────────────────────────────────────────────────────────────────
  ToolSpec(
    name: 'get_device_info',
    description:
        'Get this phone\'s battery level and charging state, free and total '
        'storage, total RAM, manufacturer, model and Android version. Call it '
        'when the user asks about battery, storage, memory or their phone.',
    localDescription: 'Battery %, charging, storage, RAM, phone model, Android version.',
    parameters: _noParams,
    tier: ToolTier.core,
  ),
  ToolSpec(
    name: 'get_date_time',
    description: 'Get the current local date, time, weekday and time zone.',
    localDescription: 'Current date, time and weekday.',
    parameters: _noParams,
    tier: ToolTier.core,
  ),
  ToolSpec(
    name: 'search_web',
    description:
        'Search the web and return the top results (title, snippet, url). '
        'Call it for news, prices, sports, facts after your training data, or '
        'anything you are not sure about. Base your answer only on the results.',
    localDescription: 'Search the web for current information.',
    parameters: {
      'type': 'object',
      'properties': {
        'query': {'type': 'string', 'description': 'Search query.'},
      },
      'required': ['query'],
    },
    tier: ToolTier.core,
  ),
  ToolSpec(
    name: 'get_weather',
    description:
        'Get current weather and a short forecast. Omit location to use the '
        'phone\'s approximate location.',
    localDescription: 'Current weather. location optional.',
    parameters: {
      'type': 'object',
      'properties': {
        'location': {
          'type': 'string',
          'description': 'City name, e.g. "Chennai". Optional.',
        },
      },
    },
    tier: ToolTier.core,
  ),
  ToolSpec(
    name: 'launch_app_by_name',
    description: 'Open an installed app by its name, e.g. "WhatsApp", "Camera".',
    localDescription: 'Open an installed app by name.',
    parameters: {
      'type': 'object',
      'properties': {
        'appName': {'type': 'string', 'description': 'App name.'},
      },
      'required': ['appName'],
    },
    tier: ToolTier.core,
  ),

  ToolSpec(
    name: 'play_media',
    description:
        'Play a song, video, artist or playlist. app: "youtube" (default) opens '
        'the top video in the YouTube app; "spotify" or "youtube_music" start '
        'playing in that app.',
    localDescription: 'Play music or a video (YouTube, Spotify, YouTube Music).',
    parameters: {
      'type': 'object',
      'properties': {
        'query': {'type': 'string', 'description': 'What to play.'},
        'app': {
          'type': 'string',
          'enum': ['youtube', 'youtube_music', 'spotify'],
          'description': 'Which app. Optional.',
        },
      },
      'required': ['query'],
    },
    tier: ToolTier.core,
  ),

  // ── common ──────────────────────────────────────────────────────────────
  ToolSpec(
    name: 'toggle_flashlight',
    description: 'Turn the flashlight (torch) on or off.',
    localDescription: 'Flashlight on/off.',
    parameters: {
      'type': 'object',
      'properties': {
        'on': {'type': 'boolean', 'description': 'true = on, false = off.'},
      },
      'required': ['on'],
    },
    tier: ToolTier.common,
  ),
  ToolSpec(
    name: 'set_timer',
    description: 'Start a countdown timer in the clock app.',
    localDescription: 'Start a countdown timer.',
    parameters: {
      'type': 'object',
      'properties': {
        'seconds': {'type': 'integer', 'description': 'Timer length in seconds.'},
        'message': {'type': 'string', 'description': 'Optional label.'},
      },
      'required': ['seconds'],
    },
    tier: ToolTier.common,
  ),
  ToolSpec(
    name: 'set_alarm',
    description: 'Set an alarm in the clock app for the next occurrence of a time.',
    localDescription: 'Set an alarm (24-hour time).',
    parameters: {
      'type': 'object',
      'properties': {
        'hour': {'type': 'integer', 'description': 'Hour, 0-23.'},
        'minute': {'type': 'integer', 'description': 'Minute, 0-59.'},
        'message': {'type': 'string', 'description': 'Optional label.'},
      },
      'required': ['hour', 'minute'],
    },
    tier: ToolTier.common,
  ),
  ToolSpec(
    name: 'set_volume',
    description: 'Set media volume. level is 0-100 (percent).',
    localDescription: 'Set media volume 0-100.',
    parameters: {
      'type': 'object',
      'properties': {
        'level': {'type': 'number', 'description': 'Volume percent, 0-100.'},
      },
      'required': ['level'],
    },
    tier: ToolTier.common,
  ),
  ToolSpec(
    name: 'search_contacts',
    description:
        'Find contacts by name and return their phone numbers and emails. '
        'Call it before calling or messaging someone by name.',
    localDescription: 'Find a contact\'s phone number by name.',
    parameters: {
      'type': 'object',
      'properties': {
        'query': {'type': 'string', 'description': 'Name to search for.'},
      },
      'required': ['query'],
    },
    tier: ToolTier.common,
  ),
  ToolSpec(
    name: 'make_phone_call',
    description:
        'Open the dialer with a number filled in; the user presses call. '
        'The number must come from search_contacts or the user.',
    localDescription: 'Open the dialer with a phone number.',
    parameters: {
      'type': 'object',
      'properties': {
        'phone': {'type': 'string', 'description': 'Phone number.'},
      },
      'required': ['phone'],
    },
    tier: ToolTier.common,
    sensitive: true,
  ),
  ToolSpec(
    name: 'vibrate',
    description: 'Vibrate the phone. duration is in milliseconds (default 500).',
    localDescription: 'Vibrate the phone.',
    parameters: {
      'type': 'object',
      'properties': {
        'duration': {'type': 'integer', 'description': 'Milliseconds.'},
      },
    },
    tier: ToolTier.common,
  ),
  ToolSpec(
    name: 'open_url',
    description: 'Open a web page in the browser.',
    localDescription: 'Open a web page.',
    parameters: {
      'type': 'object',
      'properties': {
        'url': {'type': 'string', 'description': 'Full URL or domain.'},
      },
      'required': ['url'],
    },
    tier: ToolTier.common,
  ),
  ToolSpec(
    name: 'check_connectivity',
    description:
        'Check whether the phone is online: connection type (Wi-Fi, mobile '
        'data), internet latency and the local IP address.',
    localDescription: 'Online status, Wi-Fi or mobile data, latency.',
    parameters: _noParams,
    tier: ToolTier.common,
  ),
  ToolSpec(
    name: 'read_notifications',
    description:
        'Read the notifications currently in the status bar (app, title, '
        'text). Needs notification access; if it is missing the result says so.',
    localDescription: 'Read current notifications.',
    parameters: _noParams,
    tier: ToolTier.common,
  ),
  ToolSpec(
    name: 'copy_to_clipboard',
    description: 'Copy text to the clipboard.',
    localDescription: 'Copy text to the clipboard.',
    parameters: {
      'type': 'object',
      'properties': {
        'text': {'type': 'string'},
      },
      'required': ['text'],
    },
    tier: ToolTier.common,
  ),
  ToolSpec(
    name: 'read_clipboard',
    description: 'Read the text currently on the clipboard.',
    localDescription: 'Read the clipboard.',
    parameters: _noParams,
    tier: ToolTier.common,
  ),

  ToolSpec(
    name: 'send_whatsapp',
    description:
        'Open WhatsApp with a message ready to send to a number; the user '
        'presses send. Get the number with search_contacts first when the user '
        'names a person; never make a number up.',
    localDescription: 'Open WhatsApp with a message to a number.',
    parameters: {
      'type': 'object',
      'properties': {
        'phone': {'type': 'string', 'description': 'Phone number.'},
        'message': {'type': 'string'},
      },
      'required': ['phone', 'message'],
    },
    tier: ToolTier.common,
    sensitive: true,
  ),
  ToolSpec(
    name: 'send_sms',
    description:
        'Open the SMS app with a text message ready to send to a number; the '
        'user presses send. Get the number with search_contacts first when the '
        'user names a person; never make a number up.',
    localDescription: 'Open the SMS app with a message to a number.',
    parameters: {
      'type': 'object',
      'properties': {
        'phone': {'type': 'string', 'description': 'Phone number.'},
        'message': {'type': 'string'},
      },
      'required': ['phone', 'message'],
    },
    tier: ToolTier.common,
    sensitive: true,
  ),
  ToolSpec(
    name: 'remember',
    description:
        'Save a fact the user wants you to remember across chats (a name, a '
        'preference, a date). Only when the user asks you to remember '
        'something.',
    localDescription: 'Save a fact the user asked you to remember.',
    parameters: {
      'type': 'object',
      'properties': {
        'fact': {'type': 'string', 'description': 'The fact, as a short sentence.'},
      },
      'required': ['fact'],
    },
    tier: ToolTier.common,
  ),
  ToolSpec(
    name: 'recall_memory',
    description:
        'Look up facts the user asked you to remember earlier. Call it when '
        'the user asks about something personal you might have saved.',
    localDescription: 'Look up facts the user asked you to remember.',
    parameters: {
      'type': 'object',
      'properties': {
        'query': {'type': 'string', 'description': 'What to look for. Optional.'},
      },
    },
    tier: ToolTier.common,
  ),

  // ── niche ───────────────────────────────────────────────────────────────
  ToolSpec(
    name: 'schedule_event',
    description:
        'Add an event to the phone\'s calendar. Times are ISO-8601 local time '
        'like 2026-09-25T17:00. end defaults to one hour after start.',
    localDescription: 'Add a calendar event (ISO start time).',
    parameters: {
      'type': 'object',
      'properties': {
        'title': {'type': 'string'},
        'start': {'type': 'string', 'description': 'ISO-8601 start time.'},
        'end': {'type': 'string', 'description': 'ISO-8601 end time. Optional.'},
        'description': {'type': 'string'},
      },
      'required': ['title', 'start'],
    },
    tier: ToolTier.niche,
    sensitive: true,
  ),
  ToolSpec(
    name: 'get_recent_screenshots',
    description: 'Find the most recent screenshots and show the latest one.',
    localDescription: 'Show the latest screenshot.',
    parameters: _noParams,
    tier: ToolTier.niche,
  ),
  ToolSpec(
    name: 'list_files',
    description:
        'List photos, videos, music and downloads this app is allowed to see, '
        'newest first. Android does not let this app see other apps\' '
        'documents (like PDFs), so say so if the user asks for them.',
    localDescription: 'List recent media files.',
    parameters: {
      'type': 'object',
      'properties': {
        'extension': {
          'type': 'string',
          'description': 'Filter by extension, e.g. "jpg" or "mp4".',
        },
        'sortBy': {
          'type': 'string',
          'enum': ['modified', 'name', 'size'],
        },
      },
    },
    tier: ToolTier.niche,
  ),
  ToolSpec(
    name: 'list_apps',
    description:
        'List installed apps with their approximate size in MB, largest first. '
        'Useful for "what can I uninstall to free space".',
    localDescription: 'List installed apps by size.',
    parameters: _noParams,
    tier: ToolTier.niche,
  ),
  ToolSpec(
    name: 'uninstall_app',
    description:
        'Open the system uninstall dialog for an app (the user confirms). '
        'Get the exact package name from list_apps first.',
    localDescription: 'Uninstall an app by package name.',
    parameters: {
      'type': 'object',
      'properties': {
        'packageName': {'type': 'string'},
      },
      'required': ['packageName'],
    },
    tier: ToolTier.niche,
    sensitive: true,
  ),
  ToolSpec(
    name: 'search_play_store',
    description: 'Open a Google Play Store search.',
    localDescription: 'Search the Play Store.',
    parameters: {
      'type': 'object',
      'properties': {
        'query': {'type': 'string'},
      },
      'required': ['query'],
    },
    tier: ToolTier.niche,
  ),
  ToolSpec(
    name: 'get_public_ip',
    description: 'Get the phone\'s public (internet-facing) IP address.',
    localDescription: 'Public IP address.',
    parameters: _noParams,
    tier: ToolTier.niche,
  ),
];

final Map<String, ToolSpec> kToolsByName = {
  for (final t in kToolCatalog) t.name: t,
};

const List<ToolTier> _tierOrder = [ToolTier.core, ToolTier.common, ToolTier.niche];

/// Order in which common tools fill a limited budget: the actions people ask
/// a phone assistant for most, and that the instant router can't always
/// resolve on its own (messages need a contact lookup first).
const List<String> _commonPriority = [
  'search_contacts',
  'send_whatsapp',
  'send_sms',
  'make_phone_call',
  'set_timer',
  'set_alarm',
  'toggle_flashlight',
  'remember',
  'recall_memory',
  'set_volume',
  'open_url',
  'read_notifications',
  'check_connectivity',
  'vibrate',
  'copy_to_clipboard',
  'read_clipboard',
];

/// Tools for small models that only get lookups (see ToolUse.lookups).
const List<String> kLookupTools = [
  'search_web',
  'get_weather',
  'get_date_time',
  'get_device_info',
  'recall_memory',
];

int _rank(ToolSpec t) {
  final i = _commonPriority.indexOf(t.name);
  return i < 0 ? _commonPriority.length : i;
}

/// The subset of tools to expose to a model with a [budget]-tool limit.
/// Core tools are always included; common (by priority) then niche fill the
/// remainder, so the model's tool list is stable across sessions.
List<ToolSpec> selectToolsForBudget(int budget) {
  final out = <ToolSpec>[];
  for (final tier in _tierOrder) {
    final tools = kToolCatalog.where((t) => t.tier == tier).toList();
    if (tier == ToolTier.common) tools.sort((a, b) => _rank(a).compareTo(_rank(b)));
    for (final t in tools) {
      if (tier != ToolTier.core && out.length >= budget) return out;
      out.add(t);
    }
  }
  return out;
}

List<ToolSpec> lookupTools() => [for (final n in kLookupTools) kToolsByName[n]!];
