import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:url_launcher/url_launcher.dart';

import 'app_settings.dart';
import 'llm/providers.dart';

/// Where "Report this response" goes when there is no Free cloud proxy:
/// flutter build ... --dart-define=SUPPORT_EMAIL=you@example.com
const String kSupportEmail = String.fromEnvironment('SUPPORT_EMAIL');

enum ReportResult { sent, emailOpened, unavailable }

/// Lets users flag an AI reply to the developer (Google Play requires this
/// for apps that generate content with AI). Reports go to the Free cloud
/// proxy's /report endpoint when this build has one, else to the support
/// email.
class ReportService {
  ReportService({http.Client Function()? clientFactory})
      : _clientFactory = clientFactory ?? http.Client.new;

  final http.Client Function() _clientFactory;

  static const reasons = [
    'Offensive or harmful',
    'Sexual or violent content',
    'Wrong or misleading',
    'Something else',
  ];

  Future<ReportResult> report({
    required String response,
    required String reason,
    String? model,
  }) async {
    final clipped = response.length > 2000 ? response.substring(0, 2000) : response;
    if (hostedCloudAvailable) {
      final client = _clientFactory();
      try {
        final res = await client
            .post(
              Uri.parse('${kHostedApiUrl.replaceAll(RegExp(r'/+$'), '')}/report'),
              headers: {
                'content-type': 'application/json',
                'x-goog-api-key': kHostedAppToken,
                'x-install-id': await AppSettings.installId(),
              },
              body: jsonEncode({'reason': reason, 'model': model, 'response': clipped}),
            )
            .timeout(const Duration(seconds: 10));
        if (res.statusCode == 200) return ReportResult.sent;
      } catch (_) {
        // Fall back to email.
      } finally {
        client.close();
      }
    }
    if (kSupportEmail.isNotEmpty) {
      final uri = Uri(
        scheme: 'mailto',
        path: kSupportEmail,
        query: 'subject=${Uri.encodeComponent('Local Agent: reported response ($reason)')}'
            '&body=${Uri.encodeComponent('Model: ${model ?? 'unknown'}\n\nResponse:\n$clipped')}',
      );
      if (await launchUrl(uri)) return ReportResult.emailOpened;
    }
    return ReportResult.unavailable;
  }
}
