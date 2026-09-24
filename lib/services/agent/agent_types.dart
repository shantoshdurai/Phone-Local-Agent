import '../llm/providers.dart';
import '../local/local_model.dart';

/// What the agent is currently running on.
sealed class AgentTarget {
  const AgentTarget();

  String get label;
  bool get isCloud;
}

class LocalTarget extends AgentTarget {
  final LocalModel model;
  const LocalTarget(this.model);

  @override
  String get label => model.name;

  @override
  bool get isCloud => false;
}

class CloudTarget extends AgentTarget {
  final CloudConfig config;
  const CloudTarget(this.config);

  @override
  String get label => config.label;

  @override
  bool get isCloud => true;
}

/// Live progress of a turn, for the chat UI and voice mode.
sealed class AgentEvent {
  const AgentEvent();
}

/// Human-readable progress ("Thinking…", "Checking the weather…").
/// An empty string means idle.
class AgentStatus extends AgentEvent {
  final String text;
  const AgentStatus(this.text);
}

/// Streamed reply text. [text] is the whole reply so far (not a delta), so
/// listeners never have to reassemble tokens.
class AgentPartialText extends AgentEvent {
  final String text;
  const AgentPartialText(this.text);
}

/// The streamed text was provisional (a preamble before a tool call, or a
/// response that got discarded) and should be cleared.
class AgentClearText extends AgentEvent {
  const AgentClearText();
}

/// Sink the backends report progress into.
abstract class AgentEventSink {
  void status(String text);
  void partial(String text);
  void clear();
}

/// The final result of one user turn.
class AgentReply {
  final String text;
  final String modelLabel;
  final List<String> toolsUsed;
  final double? seconds;
  final double? tokensPerSecond;

  /// An image to show with the reply (e.g. the latest screenshot).
  final String? imagePath;

  /// Handled instantly without the language model.
  final bool instant;
  final bool stopped;
  final bool isError;

  const AgentReply({
    required this.text,
    required this.modelLabel,
    this.toolsUsed = const [],
    this.seconds,
    this.tokensPerSecond,
    this.imagePath,
    this.instant = false,
    this.stopped = false,
    this.isError = false,
  });

  Map<String, dynamic> toMeta() => {
        'model': modelLabel,
        if (toolsUsed.isNotEmpty) 'tools': toolsUsed,
        if (seconds != null) 'seconds': double.parse(seconds!.toStringAsFixed(1)),
        if (tokensPerSecond != null)
          'tps': double.parse(tokensPerSecond!.toStringAsFixed(1)),
        if (imagePath != null) 'image': imagePath,
        if (instant) 'instant': true,
        if (isError) 'error': true,
      };
}

/// Friendly progress label for a tool.
String toolStatusLabel(String toolName) {
  switch (toolName) {
    case 'search_web':
      return 'Searching the web…';
    case 'get_weather':
      return 'Checking the weather…';
    case 'get_device_info':
      return 'Checking your phone…';
    case 'search_contacts':
      return 'Looking up contacts…';
    case 'read_notifications':
      return 'Reading notifications…';
    case 'launch_app_by_name':
      return 'Opening the app…';
    case 'check_connectivity':
      return 'Checking your connection…';
    case 'list_apps':
      return 'Listing apps…';
    case 'list_files':
      return 'Looking through files…';
    case 'play_media':
      return 'Finding it…';
    case 'remember':
      return 'Saving that…';
    case 'recall_memory':
      return 'Checking what you told me…';
    case 'send_whatsapp':
      return 'Opening WhatsApp…';
    case 'send_sms':
      return 'Opening Messages…';
    default:
      return 'Running ${toolName.replaceAll('_', ' ')}…';
  }
}
