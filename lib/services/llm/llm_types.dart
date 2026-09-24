import 'dart:async';
import 'dart:typed_data';

/// Provider-neutral types shared by every cloud LLM client.
///
/// The agent loop only ever speaks these types; each client
/// (Gemini / OpenAI-compatible / Anthropic) translates them to and from its
/// own wire format. That keeps provider quirks out of the agent logic and
/// lets the loop be unit-tested with a fake client.

enum LlmRole { user, assistant, tool }

class LlmImage {
  final Uint8List bytes;
  final String mimeType;
  const LlmImage(this.bytes, this.mimeType);
}

class LlmToolCall {
  final String id;
  final String name;
  final Map<String, dynamic> args;

  /// Raw argument text when the model streamed arguments that are not valid
  /// JSON. When set, [args] is empty and the call must not be executed —
  /// the agent reports the problem back to the model instead.
  final String? invalidArgs;

  const LlmToolCall({
    required this.id,
    required this.name,
    required this.args,
    this.invalidArgs,
  });
}

class LlmToolResult {
  final String callId;
  final String name;
  final Map<String, dynamic> output;
  final bool isError;

  const LlmToolResult({
    required this.callId,
    required this.name,
    required this.output,
    this.isError = false,
  });
}

class LlmMessage {
  final LlmRole role;
  final String text;
  final List<LlmImage> images;
  final List<LlmToolCall> toolCalls;
  final List<LlmToolResult> toolResults;

  /// Provider-native form of an assistant turn (Gemini `parts`, Anthropic
  /// `content` blocks). Replayed verbatim to the provider that produced it so
  /// thought signatures and thinking blocks survive — both Gemini 3 and
  /// Claude reject tool continuations that drop them.
  final Object? native;
  final String? nativeProvider;

  const LlmMessage._({
    required this.role,
    this.text = '',
    this.images = const [],
    this.toolCalls = const [],
    this.toolResults = const [],
    this.native,
    this.nativeProvider,
  });

  factory LlmMessage.user(String text, {List<LlmImage> images = const []}) =>
      LlmMessage._(role: LlmRole.user, text: text, images: images);

  factory LlmMessage.assistant(
    String text, {
    List<LlmToolCall> toolCalls = const [],
    Object? native,
    String? nativeProvider,
  }) =>
      LlmMessage._(
        role: LlmRole.assistant,
        text: text,
        toolCalls: toolCalls,
        native: native,
        nativeProvider: nativeProvider,
      );

  factory LlmMessage.toolResults(List<LlmToolResult> results) =>
      LlmMessage._(role: LlmRole.tool, toolResults: results);
}

class LlmToolDef {
  final String name;
  final String description;

  /// JSON Schema (`{"type": "object", "properties": {...}, "required": [...]}`).
  final Map<String, dynamic> parameters;

  const LlmToolDef({
    required this.name,
    required this.description,
    required this.parameters,
  });

  bool get hasParameters =>
      (parameters['properties'] as Map?)?.isNotEmpty ?? false;
}

class LlmRequest {
  final String model;
  final String system;
  final List<LlmMessage> messages;
  final List<LlmToolDef> tools;

  const LlmRequest({
    required this.model,
    required this.system,
    required this.messages,
    this.tools = const [],
  });
}

enum LlmStopReason { end, toolUse, maxTokens, refusal, blocked, other }

/// The complete result of one model call.
class LlmTurn {
  final String text;
  final List<LlmToolCall> toolCalls;
  final LlmStopReason stopReason;

  /// Provider-native assistant turn for exact replay (see [LlmMessage.native]).
  final Object? native;
  final String? nativeProvider;

  /// Raw provider stop/finish reason, for diagnostics and error messages.
  final String? detail;
  final int? outputTokens;

  const LlmTurn({
    required this.text,
    required this.toolCalls,
    required this.stopReason,
    this.native,
    this.nativeProvider,
    this.detail,
    this.outputTokens,
  });

  LlmMessage toMessage() => LlmMessage.assistant(
        text,
        toolCalls: toolCalls,
        native: native,
        nativeProvider: nativeProvider,
      );
}

sealed class LlmEvent {
  const LlmEvent();
}

class LlmTextDelta extends LlmEvent {
  final String text;
  const LlmTextDelta(this.text);
}

class LlmDone extends LlmEvent {
  final LlmTurn turn;
  const LlmDone(this.turn);
}

enum LlmErrorKind {
  auth,
  permission,
  notFound,
  rateLimit,
  quota,
  invalidRequest,
  server,
  network,
  timeout,
  cancelled,
  unknown,
}

class LlmException implements Exception {
  final LlmErrorKind kind;
  final String message;
  final int? statusCode;
  final Duration? retryAfter;

  const LlmException(
    this.kind,
    this.message, {
    this.statusCode,
    this.retryAfter,
  });

  bool get retryable =>
      kind == LlmErrorKind.rateLimit ||
      kind == LlmErrorKind.server ||
      kind == LlmErrorKind.network ||
      kind == LlmErrorKind.timeout;

  /// A short explanation suitable for showing to the user.
  String get userMessage {
    switch (kind) {
      case LlmErrorKind.auth:
        return 'Your API key was rejected. Check it in Settings → API key.';
      case LlmErrorKind.permission:
        return 'Your API key isn\'t allowed to use this model or region. $message';
      case LlmErrorKind.notFound:
        return 'That model isn\'t available for your key. Pick another model in Settings.';
      case LlmErrorKind.rateLimit:
        return 'The provider is rate-limiting requests. Wait a moment and try again.';
      case LlmErrorKind.quota:
        return 'Your API quota or credit has run out. $message';
      case LlmErrorKind.network:
        return 'Couldn\'t reach the provider. Check your internet connection.';
      case LlmErrorKind.timeout:
        return 'The provider took too long to respond. Try again.';
      case LlmErrorKind.server:
        return 'The provider had a temporary problem. Try again in a moment.';
      case LlmErrorKind.cancelled:
        return 'Stopped.';
      case LlmErrorKind.invalidRequest:
      case LlmErrorKind.unknown:
        return 'The provider returned an error: $message';
    }
  }

  @override
  String toString() =>
      'LlmException(${kind.name}${statusCode != null ? ', $statusCode' : ''}): $message';
}

class LlmModelInfo {
  final String id;
  final String displayName;
  final bool? supportsImages;
  final bool? supportsEffort;
  final int? maxOutputTokens;

  const LlmModelInfo({
    required this.id,
    String? displayName,
    this.supportsImages,
    this.supportsEffort,
    this.maxOutputTokens,
  }) : displayName = displayName ?? id;
}

/// Cooperative cancellation for in-flight requests. Clients register a
/// callback (closing their HTTP client) so a stop aborts the socket instead
/// of waiting for the provider to finish generating.
class CancelToken {
  bool _cancelled = false;
  final List<void Function()> _callbacks = [];

  bool get isCancelled => _cancelled;

  void cancel() {
    if (_cancelled) return;
    _cancelled = true;
    for (final cb in List.of(_callbacks)) {
      try {
        cb();
      } catch (_) {}
    }
    _callbacks.clear();
  }

  void onCancel(void Function() callback) {
    if (_cancelled) {
      callback();
    } else {
      _callbacks.add(callback);
    }
  }

  void removeOnCancel(void Function() callback) => _callbacks.remove(callback);
}

abstract class LlmClient {
  /// Stable provider id ('gemini', 'openai', 'anthropic', ...), used to tag
  /// provider-native assistant turns.
  String get providerId;

  /// Stream one model turn. Emits zero or more [LlmTextDelta]s followed by
  /// exactly one [LlmDone]. Errors surface as [LlmException].
  Stream<LlmEvent> stream(LlmRequest request, {CancelToken? cancel});

  /// Models this key can use. Doubles as API-key validation: it costs no
  /// generation quota and fails fast with [LlmErrorKind.auth] on a bad key.
  Future<List<LlmModelInfo>> listModels({CancelToken? cancel});
}
