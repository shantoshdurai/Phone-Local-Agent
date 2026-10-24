import '../agent_response.dart';

/// Common surface for every remote backend, so [AgentService] does not care
/// whether the answer comes from Gemini or an OpenAI-compatible endpoint.
abstract class RemoteAgent {
  Stream<String> get statusStream;
  Stream<String> get tokenStream;
  bool get isReady;
  String get activeModelLabel;

  /// Whether this backend can actually read an image attachment.
  bool get supportsVision;
  Future<void> initialize();
  Future<void> loadSession(int sessionId);
  Future<void> stopGeneration();
  Future<AgentResponse> sendMessage(
    String text,
    int sessionId, {
    String? imagePath,
  });
}

/// The backend cannot serve this request at all (rejected key, no permitted
/// model). Unlike a per-tool or per-turn failure, this is worth retrying on a
/// different provider the user has already configured.
class RemoteUnavailable implements Exception {
  final String message;

  /// The credential itself was rejected — retrying the same provider is
  /// pointless; a different one may still work.
  final bool authFailure;

  const RemoteUnavailable(this.message, {this.authFailure = false});

  @override
  String toString() => message;
}
