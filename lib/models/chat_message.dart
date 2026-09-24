import '../services/agent/agent_types.dart';
import '../services/database_service.dart';

class ChatMessage {
  final String text;
  final bool isUser;
  final String? imagePath;
  final String? modelLabel;
  final List<String> toolsUsed;
  final double? tokensPerSecond;
  final double? seconds;
  final bool instant;
  final bool isError;

  /// Skips the entrance animation (a reply that just finished streaming
  /// replaces the streamed text in place).
  final bool skipEntrance;

  const ChatMessage({
    required this.text,
    required this.isUser,
    this.imagePath,
    this.modelLabel,
    this.toolsUsed = const [],
    this.tokensPerSecond,
    this.seconds,
    this.instant = false,
    this.isError = false,
    this.skipEntrance = false,
  });

  factory ChatMessage.fromReply(AgentReply reply, {bool skipEntrance = false}) =>
      ChatMessage(
        text: reply.text,
        isUser: false,
        imagePath: reply.imagePath,
        modelLabel: reply.modelLabel,
        toolsUsed: reply.toolsUsed,
        tokensPerSecond: reply.tokensPerSecond,
        seconds: reply.seconds,
        instant: reply.instant,
        isError: reply.isError,
        skipEntrance: skipEntrance,
      );

  /// Rebuilds a message from a `chat_history` row.
  factory ChatMessage.fromRow(Map<String, dynamic> row) {
    final meta = DatabaseService.decodeMeta(row['meta']);
    return ChatMessage(
      text: (row['content'] as String?) ?? '',
      isUser: row['role'] == 'user',
      imagePath: meta['image'] as String?,
      modelLabel: meta['model'] as String?,
      toolsUsed: (meta['tools'] as List?)?.cast<String>() ?? const [],
      tokensPerSecond: (meta['tps'] as num?)?.toDouble(),
      seconds: (meta['seconds'] as num?)?.toDouble(),
      instant: meta['instant'] == true,
      isError: meta['error'] == true,
      skipEntrance: true,
    );
  }
}
