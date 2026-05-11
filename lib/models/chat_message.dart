class ChatMessage {
  final String text;
  final bool isUser;
  final String? imagePath;
  final String? modelName;
  final int? retryCount;
  final double? tps;
  final double? evalTime;

  ChatMessage({
    required this.text,
    required this.isUser,
    this.imagePath,
    this.modelName,
    this.retryCount,
    this.tps,
    this.evalTime,
  });
}
