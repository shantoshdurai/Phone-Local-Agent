import 'dart:io';

import '../llm/llm_types.dart';
import '../llm/providers.dart';
import '../tools/tool_catalog.dart';
import '../tools/tool_runtime.dart';
import 'agent_types.dart';
import 'prompts.dart';

/// Provider-agnostic agent loop for cloud models: stream a turn, execute any
/// tool calls, feed results back, repeat until the model answers.
class CloudAgent {
  final LlmClient client;
  final CloudConfig config;
  final ToolExecutor _executeTool;
  final DateTime Function() _clock;

  /// Completed exchanges as plain text. Past turns are replayed as text
  /// only: provider-native tool calls and thinking/signature blocks are only
  /// required within the turn that produced them, and replaying old tool
  /// results would multiply token cost.
  final List<(String, String)> _history = [];

  CancelToken? _cancel;

  static const int maxSteps = 8;
  static const int _maxHistoryTurns = 12;
  static const int _toolResultChars = 8000;

  CloudAgent({
    required this.client,
    required this.config,
    ToolExecutor? executeTool,
    DateTime Function()? clock,
  })  : _executeTool = executeTool ?? runTool,
        _clock = clock ?? DateTime.now;

  static final List<LlmToolDef> _tools = [
    for (final t in kToolCatalog)
      LlmToolDef(name: t.name, description: t.description, parameters: t.parameters),
  ];

  void resetConversation(List<(String, String)> history) {
    _history
      ..clear()
      ..addAll(history.length > _maxHistoryTurns
          ? history.sublist(history.length - _maxHistoryTurns)
          : history);
  }

  /// Records an exchange handled without the model (instant command).
  void addNote(String userText, String outcome) => _remember(userText, outcome);

  /// Saved memories added to the system prompt (null when memory is off).
  String? memory;

  void _remember(String user, String assistant) {
    _history.add((user, assistant));
    if (_history.length > _maxHistoryTurns) _history.removeAt(0);
  }

  void stop() => _cancel?.cancel();

  Future<AgentReply> run(
    String userText, {
    String? imagePath,
    required AgentEventSink sink,
    required ToolContext toolContext,
  }) async {
    final cancel = _cancel = CancelToken();
    final sw = Stopwatch()..start();
    final toolsUsed = <String>[];
    String? replyImage;
    var streamed = '';
    var outputTokens = 0;

    AgentReply reply(String text, {bool stopped = false, bool isError = false}) =>
        AgentReply(
          text: text,
          modelLabel: config.label,
          toolsUsed: toolsUsed,
          seconds: sw.elapsedMilliseconds / 1000,
          tokensPerSecond: outputTokens > 0 && sw.elapsedMilliseconds > 0
              ? outputTokens / (sw.elapsedMilliseconds / 1000)
              : null,
          imagePath: replyImage,
          stopped: stopped,
          isError: isError,
        );

    final images = <LlmImage>[
      if (imagePath != null)
        LlmImage(await File(imagePath).readAsBytes(), mimeTypeForPath(imagePath)),
    ];
    final turn = <LlmMessage>[LlmMessage.user(userText, images: images)];
    final system = cloudSystemPrompt(_clock(), memory: memory);

    try {
      sink.status('Thinking…');
      for (var step = 0; step < maxSteps; step++) {
        final request = LlmRequest(
          model: config.model,
          system: system,
          messages: [
            for (final (user, assistant) in _history) ...[
              LlmMessage.user(user),
              LlmMessage.assistant(assistant),
            ],
            ...turn,
          ],
          tools: _tools,
        );

        LlmTurn? result;
        streamed = '';
        await for (final event in client.stream(request, cancel: cancel)) {
          switch (event) {
            case LlmTextDelta(:final text):
              streamed += text;
              sink.partial(streamed);
            case LlmDone(turn: final done):
              result = done;
          }
        }
        if (result == null) {
          throw const LlmException(LlmErrorKind.unknown, 'The response ended unexpectedly.');
        }
        outputTokens += result.outputTokens ?? 0;

        switch (result.stopReason) {
          case LlmStopReason.refusal:
            // A refusal can cut output off mid-turn: discard the partial text
            // and never run tools from this turn.
            sink.clear();
            return reply('The model declined this request.', isError: true);
          case LlmStopReason.blocked:
            sink.clear();
            return reply(
              'The provider blocked this response for safety reasons. Try rephrasing.',
              isError: true,
            );
          case LlmStopReason.maxTokens when result.toolCalls.isNotEmpty:
            // Tool input may be truncated; don't act on it.
            sink.clear();
            return reply('The response was cut off before the model finished. Try again.',
                isError: true);
          default:
            break;
        }

        if (result.toolCalls.isEmpty) {
          final text = result.text.trim();
          if (text.isEmpty) {
            return reply(
              'The model returned an empty response${result.detail != null ? ' (${result.detail})' : ''}. Try rephrasing.',
              isError: true,
            );
          }
          _remember(userText, text);
          return reply(text);
        }

        if (streamed.isNotEmpty) sink.clear();
        turn.add(result.toMessage());
        final results = <LlmToolResult>[];
        for (final call in result.toolCalls) {
          if (cancel.isCancelled) break;
          if (call.invalidArgs != null) {
            results.add(LlmToolResult(
              callId: call.id,
              name: call.name,
              output: {'INVALID_JSON': call.invalidArgs},
              isError: true,
            ));
            continue;
          }
          sink.status(toolStatusLabel(call.name));
          final output = await _executeTool(call.name, call.args, toolContext);
          toolsUsed.add(call.name);
          if (call.name == 'get_recent_screenshots') {
            final shots = output['screenshots'];
            if (shots is List && shots.isNotEmpty) {
              replyImage ??= (shots.first as Map)['path'] as String?;
            }
          }
          results.add(LlmToolResult(
            callId: call.id,
            name: call.name,
            output: ToolRuntime.fitToBudget(output, _toolResultChars),
            isError: output.containsKey('error'),
          ));
        }
        if (cancel.isCancelled) {
          throw const LlmException(LlmErrorKind.cancelled, 'Cancelled');
        }
        // Every call gets a result, in one message — providers reject a
        // turn whose tool calls aren't all answered.
        turn.add(LlmMessage.toolResults(results));
        sink.status('Thinking…');
      }

      const text = 'I ran several steps but couldn\'t finish. Try breaking the '
          'request into smaller parts.';
      return reply(text, isError: true);
    } on LlmException catch (e) {
      if (e.kind == LlmErrorKind.cancelled || cancel.isCancelled) {
        final partial = streamed.trim();
        if (partial.isNotEmpty) _remember(userText, partial);
        return reply(partial.isEmpty ? 'Stopped.' : partial, stopped: true);
      }
      sink.clear();
      return reply(e.userMessage, isError: true);
    } finally {
      if (identical(_cancel, cancel)) _cancel = null;
    }
  }
}

String mimeTypeForPath(String path) {
  final ext = path.toLowerCase().split('.').last;
  switch (ext) {
    case 'png':
      return 'image/png';
    case 'webp':
      return 'image/webp';
    case 'gif':
      return 'image/gif';
    case 'heic':
      return 'image/heic';
    case 'heif':
      return 'image/heif';
    default:
      return 'image/jpeg';
  }
}
