import 'package:device_calendar/device_calendar.dart';
import 'package:flutter_contacts/flutter_contacts.dart' hide Event;
import 'package:url_launcher/url_launcher.dart';

class PersonalService {
  final DeviceCalendarPlugin _calendarPlugin = DeviceCalendarPlugin();

  /// Contacts whose name contains every word of [query]. Capped so a vague
  /// query can't dump the whole address book into the model's context.
  Future<Map<String, dynamic>> searchContacts(String query) async {
    final words = query
        .toLowerCase()
        .split(RegExp(r'\s+'))
        .where((w) => w.isNotEmpty)
        .toList();
    if (words.isEmpty) return {'error': 'A name to search for is required.'};
    if (!await FlutterContacts.requestPermission(readonly: true)) {
      return {
        'error': 'Contacts permission is off. Allow it in Settings → Apps → '
            'Local Agent → Permissions.',
      };
    }
    final contacts = await FlutterContacts.getContacts(
      withProperties: true,
      withThumbnail: false,
    );
    final matches = contacts.where((c) {
      final name = c.displayName.toLowerCase();
      return words.every(name.contains);
    }).toList()
      ..sort((a, b) {
        // Exact / prefix matches first.
        final q = words.join(' ');
        int rank(Contact c) {
          final n = c.displayName.toLowerCase();
          if (n == q) return 0;
          if (n.startsWith(q)) return 1;
          return 2;
        }

        return rank(a).compareTo(rank(b));
      });
    return {
      'count': matches.length,
      'contacts': [
        for (final c in matches.take(8))
          {
            'name': c.displayName,
            'phones': c.phones.map((p) => p.number).toSet().toList(),
            if (c.emails.isNotEmpty)
              'emails': c.emails.map((e) => e.address).toList(),
          }
      ],
    };
  }

  Future<Map<String, dynamic>> scheduleEvent({
    required String title,
    required DateTime start,
    DateTime? end,
    String? description,
  }) async {
    final permission = await _calendarPlugin.requestPermissions();
    if (!(permission.isSuccess && (permission.data ?? false))) {
      return {'error': 'Calendar permission is off.'};
    }
    final calendars = await _calendarPlugin.retrieveCalendars();
    final writable = (calendars.data ?? const <Calendar>[])
        .where((c) => c.isReadOnly != true)
        .toList();
    if (writable.isEmpty) {
      return {'error': 'No writable calendar found on this phone.'};
    }
    // Prefer the default calendar, then one tied to an account.
    writable.sort((a, b) {
      int rank(Calendar c) =>
          (c.isDefault == true ? 0 : 2) + (c.accountType == 'LOCAL' ? 1 : 0);
      return rank(a).compareTo(rank(b));
    });
    final calendar = writable.first;
    final event = Event(calendar.id)
      ..title = title
      ..description = description
      ..start = TZDateTime.from(start, local)
      ..end = TZDateTime.from(end ?? start.add(const Duration(hours: 1)), local);
    final result = await _calendarPlugin.createOrUpdateEvent(event);
    if (result?.isSuccess ?? false) {
      return {
        'success': true,
        'calendar': calendar.name,
        'start': start.toIso8601String(),
      };
    }
    return {'error': 'The calendar app refused the event.'};
  }

  /// Opens WhatsApp with the message ready; the user presses send.
  Future<bool> sendWhatsApp(String phone, String message) async {
    final cleanPhone = phone.replaceAll(RegExp(r'[^0-9]'), '');
    if (cleanPhone.length < 6) return false;
    final text = Uri.encodeComponent(message);
    try {
      final app = Uri.parse('whatsapp://send?phone=$cleanPhone&text=$text');
      if (await canLaunchUrl(app)) return await launchUrl(app);
      return await launchUrl(
        Uri.parse('https://wa.me/$cleanPhone?text=$text'),
        mode: LaunchMode.externalApplication,
      );
    } catch (_) {
      return false;
    }
  }

  /// Opens the default SMS app with the message filled in; the user presses
  /// send. (Sending silently needs SEND_SMS, which Play only grants to
  /// default SMS apps.)
  Future<bool> sendSms(String phone, String message) async {
    final clean = phone.replaceAll(RegExp(r'[^0-9+]'), '');
    if (clean.replaceAll('+', '').length < 3) return false;
    try {
      // Uri(queryParameters:) encodes spaces as "+", which some messaging
      // apps show literally.
      return await launchUrl(Uri.parse('sms:$clean?body=${Uri.encodeComponent(message)}'));
    } catch (_) {
      return false;
    }
  }
}
