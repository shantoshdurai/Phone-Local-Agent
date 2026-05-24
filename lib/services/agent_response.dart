/// Shared response value for both [AgentService] (local) and
/// [GeminiService] (cloud). The chat UI consumes one of these per turn —
/// it doesn't need to know which backend produced it.
class AgentResponse {
  final String text;
  final String modelName;
  final int retryCount;
  final double? tps;
  final double? evalTime;
  final String? toolName;
  final String? imagePath;

  AgentResponse(
    this.text,
    this.modelName,
    this.retryCount, {
    this.tps,
    this.evalTime,
    this.toolName,
    this.imagePath,
  });
}
