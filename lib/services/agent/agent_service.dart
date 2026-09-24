import 'dart:async';

import 'package:flutter/services.dart';

import '../app_settings.dart';
import '../database_service.dart';
import '../llm/llm_types.dart';
import '../llm/providers.dart';
import '../tools/tool_runtime.dart';
import 'agent_types.dart';
import 'cloud_agent.dart';
import 'local_agent.dart';
import 'quick_commands.dart';

export 'agent_types.dart';

/// The one object screens talk to. Owns the active backend (on-device or
/// cloud), persists messages, runs instant commands, and reports progress
/// through [events].
class AgentService implements AgentEventSink {
  static final AgentService _instance = AgentService._();
  factory AgentService() => _instance;
  AgentService._();

  final _events = StreamController<AgentEvent>.broadcast();
  final DatabaseService _db = DatabaseService();
  final LocalAgent _local = LocalAgent();
  CloudAgent? _cloud;
  AgentTarget? _target;
  int? _sessionId;
  bool _busy = false;
  Future<void>? _activating;

  /// Shows a confirmation dialog for sensitive actions. Set by whichever
  /// screen is in front (chat or voice mode).
  ConfirmCallback? confirmHandler;

  Stream<AgentEvent> get events => _events.stream;
  AgentTarget? get target => _target;
  int? get sessionId => _sessionId;
  bool get isBusy => _busy;
  bool get usingGpu => _local.usingGpu;
  String get modelLabel => _target?.label ?? '';

  bool get supportsImages => switch (_target) {
        LocalTarget(:final spec) => spec.supportsVision,
        CloudTarget(:final config) => config.supportsImages ?? true,
        null => false,
      };

  @override
  void status(String text) => _events.add(AgentStatus(text));

  @override
  void partial(String text) => _events.add(AgentPartialText(text));

  @override
  void clear() => _events.add(const AgentClearText());

  bool isActive(AgentTarget target) {
    final current = _target;
    if (current is LocalTarget && target is LocalTarget) {
      return current.spec.fileName == target.spec.fileName && _local.isLoaded;
    }
    if (current is CloudTarget && target is CloudTarget) {
      return _cloud != null &&
          current.config.providerId == target.config.providerId &&
          current.config.model == target.config.model &&
          current.config.baseUrl == target.config.baseUrl;
    }
    return false;
  }

  /// Loads a local model or connects a cloud provider. Idempotent.
  Future<void> activate(AgentTarget target) async {
    while (_activating != null) {
      await _activating;
    }
    if (isActive(target)) return;
    final completer = Completer<void>();
    _activating = completer.future;
    try {
      if (_busy) await stop();
      switch (target) {
        case LocalTarget(:final spec):
          _cloud = null;
          await _local.load(spec, preferGpu: await AppSettings.useGpu(), onStatus: status);
          await AppSettings.setLastLocalModel(spec.fileName);
          await AppSettings.setMode(AgentMode.local);
        case CloudTarget(:final config):
          final key = await KeyStore.read(config.providerId);
          if (config.preset.keyRequired && key == null) {
            throw StateError('No API key saved for ${config.preset.name}. Add one in Settings.');
          }
          // Free the RAM a loaded on-device model holds (up to ~3 GB).
          await _local.unload();
          _cloud = CloudAgent(
            client: createLlmClient(
              preset: config.preset,
              apiKey: key ?? '',
              baseUrl: config.baseUrl,
              config: config,
            ),
            config: config,
          );
          await AppSettings.setCloudConfig(config);
          await AppSettings.setMode(AgentMode.cloud);
      }
      _target = target;
      if (_sessionId != null) await openSession(_sessionId!);
    } finally {
      status('');
      _activating = null;
      completer.complete();
    }
  }

  /// Makes [sessionId] the current conversation and primes the backend with
  /// its history.
  Future<void> openSession(int sessionId) async {
    _sessionId = sessionId;
    final exchanges = await _db.getExchanges(sessionId);
    await _local.resetConversation(exchanges);
    _cloud?.resetConversation(exchanges);
  }

  /// Starts an empty conversation. The database row is created lazily on the
  /// first message, so abandoned "New Chat"s don't pile up.
  Future<void> startBlankSession() async {
    _sessionId = null;
    await _local.resetConversation(const []);
    _cloud?.resetConversation(const []);
  }

  Future<int> newSession() async {
    await _db.deleteEmptySessions();
    final id = await _db.createSession('New Chat');
    await openSession(id);
    return id;
  }

  Future<AgentReply> send(String text, {String? imagePath}) async {
    final sessionId = _sessionId ?? await newSession();
    if (_busy) await stop();
    _busy = true;
    final trimmed = text.trim();
    try {
      await _db.saveMessage('user', trimmed, sessionId,
          meta: imagePath == null ? null : {'image': imagePath});
      await _titleSession(sessionId, trimmed, hasImage: imagePath != null);

      AgentReply? reply;
      if (imagePath == null && trimmed.isNotEmpty && await AppSettings.instantCommands()) {
        reply = await _tryInstant(trimmed);
        if (reply != null) {
          _local.addNote(trimmed, reply.text);
          _cloud?.addNote(trimmed, reply.text);
        }
      }
      reply ??= await _runModel(trimmed.isEmpty ? 'Describe this image.' : trimmed, imagePath);
      await _db.saveMessage('assistant', reply.text, sessionId, meta: reply.toMeta());
      return reply;
    } catch (e) {
      final reply = AgentReply(
        text: friendlyError(e),
        modelLabel: modelLabel,
        isError: true,
      );
      await _db.saveMessage('assistant', reply.text, sessionId, meta: reply.toMeta());
      return reply;
    } finally {
      _busy = false;
      status('');
    }
  }

  Future<AgentReply> _runModel(String text, String? imagePath) async {
    final context = await _toolContext();
    final target = _target;
    switch (target) {
      case LocalTarget():
        return _local.run(text, imagePath: imagePath, sink: this, toolContext: context);
      case CloudTarget():
        final cloud = _cloud;
        if (cloud == null) throw StateError('Cloud model isn\'t connected yet.');
        return cloud.run(text, imagePath: imagePath, sink: this, toolContext: context);
      case null:
        throw StateError('No model is loaded yet.');
    }
  }

  Future<ToolContext> _toolContext() async => ToolContext(
        confirmSensitive: await AppSettings.confirmActions(),
        confirm: confirmHandler,
      );

  /// Runs a recognised command without the model. Returns null to fall
  /// through to the model.
  Future<AgentReply?> _tryInstant(String text) async {
    final cmd = QuickCommands.match(text);
    if (cmd == null) return null;
    final sw = Stopwatch()..start();
    final context = await _toolContext();
    var tool = cmd.tool;
    var args = cmd.args;

    if (tool == 'call_contact') {
      final phone = await _uniqueContactNumber('${args['name']}');
      if (phone == null) return null; // ambiguous or unknown: let the model ask
      tool = 'make_phone_call';
      args = {'phone': phone};
    }

    final result = await ToolRuntime.instance.execute(tool, args, context: context);
    final failed = result.containsKey('error') && result['cancelled'] != true;
    if (failed && cmd.fallThroughOnError) return null;

    String? imagePath;
    if (tool == 'get_recent_screenshots') {
      final shots = result['screenshots'];
      if (shots is List && shots.isNotEmpty) imagePath = (shots.first as Map)['path'] as String?;
    }
    final reply = (!failed && cmd.format != null)
        ? cmd.format!(result)
        : ToolRuntime.formatDirect(tool, args, result) ?? '${result['error'] ?? 'Done.'}';
    return AgentReply(
      text: reply,
      modelLabel: 'Instant',
      toolsUsed: [tool],
      seconds: sw.elapsedMilliseconds / 1000,
      imagePath: imagePath,
      instant: true,
      isError: failed,
    );
  }

  Future<String?> _uniqueContactNumber(String name) async {
    final lookup = await ToolRuntime.instance.execute('search_contacts', {'query': name});
    final contacts = (lookup['contacts'] as List?) ?? const [];
    final withPhones = contacts.where((c) => (c['phones'] as List).isNotEmpty).toList();
    if (withPhones.isEmpty) return null;
    final exact = withPhones
        .where((c) => '${c['name']}'.toLowerCase() == name.toLowerCase())
        .toList();
    final pick = exact.length == 1
        ? exact.first
        : (withPhones.length == 1 ? withPhones.first : null);
    if (pick == null) return null;
    final phones = (pick['phones'] as List).cast<String>();
    return phones.length == 1 ? phones.first : null;
  }

  Future<void> _titleSession(int sessionId, String text, {required bool hasImage}) async {
    final session = await _db.getSession(sessionId);
    if (session == null || session['title'] != 'New Chat') return;
    await _db.updateSessionTitle(sessionId, titleFor(text, hasImage: hasImage));
  }

  static String titleFor(String text, {bool hasImage = false}) {
    var t = text.trim();
    if (t.isEmpty) return hasImage ? 'Image question' : 'New Chat';
    const fillers = [
      'can you ', 'could you ', 'please ', 'hey ', 'how do i ', 'tell me ',
      'what is ', 'what\'s ', 'help me ', 'i want to ', 'i need to ',
    ];
    var changed = true;
    while (changed) {
      changed = false;
      for (final f in fillers) {
        if (t.toLowerCase().startsWith(f) && t.length > f.length) {
          t = t.substring(f.length);
          changed = true;
        }
      }
    }
    t = t.replaceAll(RegExp(r'[?!.]+$'), '');
    final words = t.split(RegExp(r'\s+'));
    var title = words.take(5).join(' ');
    if (words.length > 5) title = '$title…';
    return title.isEmpty ? 'New Chat' : title[0].toUpperCase() + title.substring(1);
  }

  Future<void> stop() async {
    switch (_target) {
      case LocalTarget():
        await _local.stop();
      case CloudTarget():
        _cloud?.stop();
      case null:
        break;
    }
  }

  static String friendlyError(Object e) {
    if (e is LlmException) return e.userMessage;
    if (e is StateError) return e.message;
    final s = e.toString();
    if (s.contains('OUT_OF_RANGE') || s.toLowerCase().contains('too long')) {
      return 'That was too long for the on-device model. Start a new chat or shorten the message.';
    }
    if (s.contains('Previous invocation')) {
      return 'The model was still finishing the last reply. Try again.';
    }
    if (e is PlatformException) {
      return 'The on-device model hit an error: ${e.message ?? e.code}. Try again, or reload the model from Settings.';
    }
    return 'Something went wrong: ${s.length > 200 ? '${s.substring(0, 200)}…' : s}';
  }
}
