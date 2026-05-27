/// Rich, human-phrased descriptions of every tool the agent has, with a
/// handful of example queries each.
///
/// The point: when a user says "what's my battery" or "am I online" or
/// "send a message to mom", the embedding retriever needs to match that
/// phrasing against something — and "Get device manufacturer, OS, battery,
/// storage, and RAM" (the SDK-injected tool description) is too terse and
/// schema-flavored to embed well. The example queries are what makes the
/// retriever actually pick the right tool.
///
/// When adding a tool to ToolRuntime, add a doc here too — otherwise the
/// retriever will simply never recommend it. The agent still has the tool
/// available via the SDK-injected catalog; it just won't get a hint.
class ToolDoc {
  final String name;
  final String description;
  final List<String> examples;
  const ToolDoc({
    required this.name,
    required this.description,
    required this.examples,
  });

  /// The text we actually embed. Description + examples in one blob —
  /// MiniLM mean-pools across the whole thing, so packing varied
  /// phrasings here is what gives the retriever its breadth.
  String get embedText {
    final ex = examples.join('. ');
    return '$description. Example phrasings: $ex';
  }
}

const List<ToolDoc> kToolDocs = [
  ToolDoc(
    name: 'get_device_info',
    description:
        'Read the user\'s phone hardware and OS details: manufacturer, '
        'model, Android version, battery percentage, free and total '
        'storage, RAM size.',
    examples: [
      'what is my battery level',
      'how much battery do I have left',
      'tell me my device info',
      'what phone am I using',
      'how much free storage is left',
      'how much ram does this device have',
      'what android version am I running',
      'show me my hardware specs',
    ],
  ),
  ToolDoc(
    name: 'check_connectivity',
    description:
        'Check whether the phone is online right now, the connection '
        'type (WiFi vs cellular), the WiFi SSID, and the local IP '
        'address on the network.',
    examples: [
      'am I online',
      'am I connected to wifi',
      'what wifi network am I on',
      'what is my local ip address',
      'do I have internet right now',
      'am I on cellular or wifi',
    ],
  ),
  ToolDoc(
    name: 'get_public_ip',
    description:
        'Look up the phone\'s public (external, internet-facing) IP '
        'address by hitting an IP echo service.',
    examples: [
      'what is my public ip',
      'what ip address does the internet see',
      'show my external ip',
    ],
  ),
  ToolDoc(
    name: 'get_date_time',
    description:
        'Return the current local date, time, day of the week, and '
        'timezone on the device.',
    examples: [
      'what time is it',
      'what is today\'s date',
      'what day of the week is it',
      'what timezone am I in',
      'tell me the current time',
    ],
  ),
  ToolDoc(
    name: 'search_web',
    description:
        'Search the open web for facts, news, weather, sports scores, '
        'definitions, or anything that needs up-to-date information '
        'beyond the model\'s training data.',
    examples: [
      'what is the weather in london today',
      'who won the world cup last night',
      'latest news about openai',
      'lookup the population of canada',
      'what is the price of bitcoin right now',
    ],
  ),
  ToolDoc(
    name: 'open_url',
    description: 'Open a specific URL in the device default web browser.',
    examples: [
      'open google.com',
      'go to youtube in my browser',
      'launch this url',
    ],
  ),
  ToolDoc(
    name: 'list_files',
    description:
        'List the user\'s files on the device — documents, downloads, '
        'screenshots. Can filter by file extension and sort by modified, '
        'name, or size.',
    examples: [
      'show me my recent files',
      'list the pdfs on my phone',
      'what files do I have',
      'show my biggest documents',
      'list my downloads',
    ],
  ),
  ToolDoc(
    name: 'list_apps',
    description:
        'List the apps installed on the device along with their '
        'package names and approximate disk usage in megabytes, '
        'sorted largest first.',
    examples: [
      'what apps are installed',
      'show me my apps by size',
      'which apps use the most storage',
      'list installed applications',
    ],
  ),
  ToolDoc(
    name: 'launch_app_by_name',
    description:
        'Open an app by its visible display name (the label the user '
        'sees on the home screen). Use this for any "open X" or '
        '"launch X" request when X is an app name.',
    examples: [
      'open calculator',
      'launch youtube',
      'start the camera app',
      'open spotify',
      'open whatsapp',
      'launch chrome',
    ],
  ),
  ToolDoc(
    name: 'launch_app',
    description:
        'Launch an installed Android app by its package name '
        '(e.g. com.android.calculator2). Use this only when the '
        'package name is already known.',
    examples: [
      'launch the app with package com.spotify.music',
      'open package com.google.android.youtube',
    ],
  ),
  ToolDoc(
    name: 'uninstall_app',
    description:
        'Open the Android uninstall dialog for a specific package so '
        'the user can confirm removal.',
    examples: [
      'uninstall facebook',
      'remove the spotify app',
      'delete this app from my phone',
    ],
  ),
  ToolDoc(
    name: 'search_play_store',
    description:
        'Open Google Play Store with a search query so the user can '
        'find and install a new app.',
    examples: [
      'find me a flashlight app on the play store',
      'search for note-taking apps',
      'look up duolingo on the play store',
    ],
  ),
  ToolDoc(
    name: 'open_play_store',
    description:
        'Open a specific app\'s page in the Google Play Store by '
        'package name.',
    examples: [
      'show me whatsapp in the play store',
      'open the play store page for instagram',
    ],
  ),
  ToolDoc(
    name: 'toggle_flashlight',
    description:
        'Turn the device\'s camera-flash LED on or off so the phone '
        'becomes a flashlight.',
    examples: [
      'turn on the flashlight',
      'switch off the torch',
      'enable the flashlight',
      'i need a flashlight',
    ],
  ),
  ToolDoc(
    name: 'vibrate',
    description:
        'Vibrate the device for a given duration in milliseconds.',
    examples: [
      'make the phone vibrate',
      'vibrate for two seconds',
      'buzz my phone',
    ],
  ),
  ToolDoc(
    name: 'set_volume',
    description:
        'Set the device media volume to a specific level between 0 '
        '(silent) and 1 (max).',
    examples: [
      'turn the volume up to max',
      'mute the volume',
      'set volume to fifty percent',
      'make it louder',
      'turn down the volume',
    ],
  ),
  ToolDoc(
    name: 'copy_to_clipboard',
    description:
        'Copy a specific piece of text to the device clipboard so the '
        'user can paste it elsewhere.',
    examples: [
      'copy this to my clipboard',
      'put this on the clipboard',
      'copy that text',
    ],
  ),
  ToolDoc(
    name: 'read_clipboard',
    description: 'Read whatever text is currently on the device clipboard.',
    examples: [
      'what is on my clipboard',
      'read my clipboard',
      'show me the clipboard contents',
    ],
  ),
  ToolDoc(
    name: 'get_recent_screenshots',
    description:
        'Get a list of the most recent screenshots saved on the device.',
    examples: [
      'show my latest screenshot',
      'find my recent screenshots',
      'what was the last screenshot I took',
    ],
  ),
  ToolDoc(
    name: 'search_contacts',
    description:
        'Search the device contact list by name and return matching '
        'contacts with their phone numbers and emails.',
    examples: [
      'find sarah in my contacts',
      'look up mom\'s phone number',
      'search contacts for john',
      'what is the phone number for alice',
    ],
  ),
  ToolDoc(
    name: 'schedule_event',
    description:
        'Create a calendar event on the device with a title, start '
        'time, end time, and optional description.',
    examples: [
      'schedule a meeting tomorrow at 3pm',
      'add a dentist appointment to my calendar',
      'put lunch with alex on the calendar friday',
    ],
  ),
  ToolDoc(
    name: 'send_whatsapp',
    description:
        'Open WhatsApp with a prefilled message ready to send to a '
        'specific phone number. The phone number must come from '
        'search_contacts or directly from the user — never invented.',
    examples: [
      'message sarah on whatsapp',
      'send a whatsapp to mom saying I\'m on my way',
      'whatsapp this number hello',
    ],
  ),
  ToolDoc(
    name: 'make_phone_call',
    description:
        'Open the phone dialer to call a specific phone number. The '
        'number must come from search_contacts or the user, not '
        'invented.',
    examples: [
      'call mom',
      'phone sarah',
      'dial this number',
      'call my emergency contact',
    ],
  ),
  ToolDoc(
    name: 'set_alarm',
    description:
        'Set an alarm on the device\'s clock app for a specific hour '
        'and minute, with an optional label.',
    examples: [
      'set an alarm for 7am',
      'wake me up at 6:30 tomorrow',
      'add an alarm for 5pm labeled gym',
    ],
  ),
  ToolDoc(
    name: 'set_timer',
    description:
        'Set a countdown timer on the device clock for a specific '
        'number of seconds, with an optional label.',
    examples: [
      'set a timer for ten minutes',
      'start a 30 second countdown',
      'timer for 5 minutes called tea',
    ],
  ),
  ToolDoc(
    name: 'read_notifications',
    description:
        'Read the unread notifications currently on the device. May '
        'require the user to grant notification-listener permission.',
    examples: [
      'what notifications do I have',
      'read my unread notifications',
      'any new alerts',
    ],
  ),
];
