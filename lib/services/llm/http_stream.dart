import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

import 'llm_types.dart';

typedef HttpClientFactory = http.Client Function();

http.Client defaultHttpClientFactory() => http.Client();

/// One Server-Sent Event.
class SseEvent {
  final String? event;
  final String data;
  const SseEvent(this.event, this.data);
}

/// Minimal, spec-compliant SSE parser (`event:` / `data:` fields, comment
/// lines, multi-line data, CRLF). UTF-8 decoding is chunk-safe, so multi-byte
/// characters split across TCP packets decode correctly.
Stream<SseEvent> parseSse(Stream<List<int>> bytes) async* {
  String? event;
  final data = StringBuffer();
  var hasData = false;
  await for (final line
      in bytes.transform(utf8.decoder).transform(const LineSplitter())) {
    if (line.isEmpty) {
      if (hasData) yield SseEvent(event, data.toString());
      event = null;
      data.clear();
      hasData = false;
      continue;
    }
    if (line.startsWith(':')) continue;
    final colon = line.indexOf(':');
    final field = colon < 0 ? line : line.substring(0, colon);
    var value = colon < 0 ? '' : line.substring(colon + 1);
    if (value.startsWith(' ')) value = value.substring(1);
    switch (field) {
      case 'event':
        event = value;
      case 'data':
        if (hasData) data.write('\n');
        data.write(value);
        hasData = true;
    }
  }
  if (hasData) yield SseEvent(event, data.toString());
}

/// Decodes an SSE `data:` payload, turning malformed JSON into a typed error
/// instead of a raw FormatException bubbling into the UI.
Map<String, dynamic> decodeEventJson(String data) {
  try {
    final decoded = jsonDecode(data);
    if (decoded is Map<String, dynamic>) return decoded;
  } catch (_) {}
  throw LlmException(
    LlmErrorKind.unknown,
    'Unexpected response from provider: ${_clip(data)}',
  );
}

/// An open streaming HTTP response bound to its own client, so cancelling
/// closes the socket.
class OpenStream {
  final http.StreamedResponse response;
  final http.Client _client;
  final CancelToken? _cancel;
  final void Function() _onCancel;

  OpenStream._(this.response, this._client, this._cancel, this._onCancel);

  /// Response bytes with an idle timeout: a provider that goes silent
  /// mid-stream surfaces as [LlmErrorKind.timeout] instead of hanging the
  /// chat forever.
  Stream<List<int>> bytes({Duration idle = const Duration(seconds: 90)}) {
    return response.stream.timeout(idle, onTimeout: (sink) {
      sink.addError(const LlmException(
        LlmErrorKind.timeout,
        'No data received from the provider for a while.',
      ));
      sink.close();
    });
  }

  void close() {
    _cancel?.removeOnCancel(_onCancel);
    _client.close();
  }
}

/// Sends [request] and returns the open response when the status is 2xx.
/// Non-2xx responses are read fully and converted into an [LlmException] by
/// [errorFromBody]. Transport failures map to network / timeout / cancelled.
Future<OpenStream> openStream(
  http.BaseRequest request, {
  required HttpClientFactory clientFactory,
  required LlmException Function(int status, String body, Map<String, String> headers)
      errorFromBody,
  CancelToken? cancel,
  Duration connectTimeout = const Duration(seconds: 45),
}) async {
  if (cancel?.isCancelled ?? false) {
    throw const LlmException(LlmErrorKind.cancelled, 'Cancelled');
  }
  final client = clientFactory();
  void onCancel() => client.close();
  cancel?.onCancel(onCancel);
  try {
    final response = await client.send(request).timeout(connectTimeout);
    if (response.statusCode >= 200 && response.statusCode < 300) {
      return OpenStream._(response, client, cancel, onCancel);
    }
    final body = await response.stream
        .bytesToString()
        .timeout(const Duration(seconds: 20), onTimeout: () => '');
    cancel?.removeOnCancel(onCancel);
    client.close();
    throw errorFromBody(response.statusCode, body, response.headers);
  } on LlmException {
    rethrow;
  } catch (e) {
    cancel?.removeOnCancel(onCancel);
    client.close();
    throw mapTransportError(e, cancel);
  }
}

/// Plain (non-streaming) GET/POST returning the decoded JSON body.
Future<Map<String, dynamic>> requestJson(
  http.BaseRequest request, {
  required HttpClientFactory clientFactory,
  required LlmException Function(int status, String body, Map<String, String> headers)
      errorFromBody,
  CancelToken? cancel,
}) async {
  final open = await openStream(
    request,
    clientFactory: clientFactory,
    errorFromBody: errorFromBody,
    cancel: cancel,
  );
  try {
    final body = await open.response.stream
        .bytesToString()
        .timeout(const Duration(seconds: 45));
    final decoded = jsonDecode(body);
    if (decoded is Map<String, dynamic>) return decoded;
    throw LlmException(LlmErrorKind.unknown, 'Unexpected response: ${_clip(body)}');
  } on LlmException {
    rethrow;
  } catch (e) {
    throw mapTransportError(e, cancel);
  } finally {
    open.close();
  }
}

LlmException mapTransportError(Object e, CancelToken? cancel) {
  if (e is LlmException) return e;
  if (cancel?.isCancelled ?? false) {
    return const LlmException(LlmErrorKind.cancelled, 'Cancelled');
  }
  if (e is TimeoutException) {
    return const LlmException(LlmErrorKind.timeout, 'Request timed out.');
  }
  if (e is SocketException ||
      e is HandshakeException ||
      e is http.ClientException ||
      e is HttpException) {
    return LlmException(LlmErrorKind.network, e.toString());
  }
  return LlmException(LlmErrorKind.unknown, e.toString());
}

/// Reads a `Retry-After` header (seconds form only).
Duration? retryAfterFrom(Map<String, String> headers) {
  final raw = headers['retry-after'];
  final seconds = raw == null ? null : double.tryParse(raw.trim());
  if (seconds == null || seconds < 0) return null;
  return Duration(milliseconds: (seconds * 1000).round());
}

/// Default status → kind mapping shared by the clients; each client refines
/// it with provider-specific error codes.
LlmErrorKind kindForStatus(int status) {
  if (status == 401) return LlmErrorKind.auth;
  if (status == 402) return LlmErrorKind.quota;
  if (status == 403) return LlmErrorKind.permission;
  if (status == 404) return LlmErrorKind.notFound;
  if (status == 408) return LlmErrorKind.timeout;
  if (status == 429) return LlmErrorKind.rateLimit;
  if (status >= 500) return LlmErrorKind.server;
  return LlmErrorKind.invalidRequest;
}

/// Wraps a single model turn with retries for transient failures (rate
/// limits, 5xx, dropped connections). Retries only happen before the first
/// event reaches the caller — once text has streamed to the UI, replaying
/// the turn would duplicate it.
Stream<LlmEvent> withRetries(
  Stream<LlmEvent> Function() attempt, {
  CancelToken? cancel,
  int maxRetries = 2,
}) async* {
  var tries = 0;
  while (true) {
    var emitted = false;
    try {
      await for (final event in attempt()) {
        emitted = true;
        yield event;
      }
      return;
    } on LlmException catch (e) {
      if (emitted || !e.retryable || tries >= maxRetries) rethrow;
      if (cancel?.isCancelled ?? false) rethrow;
      tries++;
      final wait = e.retryAfter ?? Duration(milliseconds: 800 * tries * tries);
      final capped = wait > const Duration(seconds: 10)
          ? const Duration(seconds: 10)
          : wait;
      await Future.delayed(capped);
      if (cancel?.isCancelled ?? false) {
        throw const LlmException(LlmErrorKind.cancelled, 'Cancelled');
      }
    }
  }
}

String _clip(String s, [int max = 300]) =>
    s.length <= max ? s : '${s.substring(0, max)}…';

String clipForError(String s) => _clip(s);
