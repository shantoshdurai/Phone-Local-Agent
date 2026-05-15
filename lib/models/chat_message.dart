class ChatMessage {
  final String text;
  final bool isUser;
  final String? imagePath;
  final String? modelName;
  final int? retryCount;
  final double? tps;
  final double? evalTime;
  final String? toolName;
  // When true, MessageBubble skips its entrance animation. Used for assistant
  // messages that just finished streaming so the final render slots into the
  // same position the streamed text already occupied — no flash, no replay.
  final bool skipEntrance;

  ChatMessage({
    required this.text,
    required this.isUser,
    this.imagePath,
    this.modelName,
    this.retryCount,
    this.tps,
    this.evalTime,
    this.toolName,
    this.skipEntrance = false,
  });
}
