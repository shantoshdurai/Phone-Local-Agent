import 'package:flutter_contacts/flutter_contacts.dart' hide Event;
import 'package:device_calendar/device_calendar.dart';
import 'package:url_launcher/url_launcher.dart';

class PersonalService {
  final DeviceCalendarPlugin _calendarPlugin = DeviceCalendarPlugin();

  Future<List<Map<String, dynamic>>> searchContacts(String query) async {
    if (await FlutterContacts.requestPermission()) {
      List<Contact> contacts = await FlutterContacts.getContacts(
        withProperties: true,
        withThumbnail: false,
      );

      final results = contacts.where((c) {
        final fullName = c.displayName.toLowerCase();
        return fullName.contains(query.toLowerCase());
      }).toList();

      return results.map((c) => {
        'name': c.displayName,
        'phones': c.phones.map((p) => p.number).toList(),
        'emails': c.emails.map((e) => e.address).toList(),
      }).toList();
    }
    return [];
  }

  Future<List<Map<String, dynamic>>> getCalendarEvents(DateTime start, DateTime end) async {
    final permissions = await _calendarPlugin.requestPermissions();
    if (permissions.isSuccess && permissions.data!) {
      final calendars = await _calendarPlugin.retrieveCalendars();
      if (calendars.isSuccess && calendars.data!.isNotEmpty) {
        // Just use the first calendar for now
        final calendarId = calendars.data!.first.id;
        final events = await _calendarPlugin.retrieveEvents(
          calendarId,
          RetrieveEventsParams(startDate: start, endDate: end),
        );
        
        if (events.isSuccess && events.data != null) {
          return events.data!.map((e) => {
            'title': e.title,
            'description': e.description,
            'start': e.start?.toIso8601String(),
            'end': e.end?.toIso8601String(),
            'allDay': e.allDay,
          }).toList();
        }
      }
    }
    return [];
  }

  Future<bool> scheduleEvent({
    required String title,
    required DateTime start,
    required DateTime end,
    String? description,
  }) async {
    final permissions = await _calendarPlugin.requestPermissions();
    if (permissions.isSuccess && permissions.data!) {
      final calendars = await _calendarPlugin.retrieveCalendars();
      if (calendars.isSuccess && calendars.data!.isNotEmpty) {
        final calendarId = calendars.data!.first.id;
        final event = Event(calendarId);
        event.title = title;
        event.start = TZDateTime.from(start, local);
        event.end = TZDateTime.from(end, local);
        event.description = description;
        
        final result = await _calendarPlugin.createOrUpdateEvent(event);
        return result?.isSuccess ?? false;
      }
    }
    return false;
  }

  Future<bool> sendWhatsApp(String phone, String message) async {
    // Sanitize phone number
    final cleanPhone = phone.replaceAll(RegExp(r'[^0-9]'), '');
    final url = Uri.parse('whatsapp://send?phone=$cleanPhone&text=${Uri.encodeComponent(message)}');
    final webUrl = Uri.parse('https://wa.me/$cleanPhone?text=${Uri.encodeComponent(message)}');

    try {
      if (await canLaunchUrl(url)) {
        return await launchUrl(url);
      } else {
        return await launchUrl(webUrl, mode: LaunchMode.externalApplication);
      }
    } catch (e) {
      return false;
    }
  }
}
