import 'package:flutter_test/flutter_test.dart';
import 'package:local_agent/services/agent/quick_commands.dart';

void main() {
  QuickCommand? m(String s) => QuickCommands.match(s);

  group('flashlight', () {
    test('matches common phrasings', () {
      for (final s in [
        'turn on the flashlight',
        'Turn on flashlight.',
        'switch the torch on',
        'flashlight on',
        'Hey, turn on the flash light please',
        'can you turn on my torch',
      ]) {
        final cmd = m(s);
        expect(cmd?.tool, 'toggle_flashlight', reason: s);
        expect(cmd?.args['on'], true, reason: s);
      }
      expect(m('turn off the flashlight')?.args['on'], false);
      expect(m('torch off')?.args['on'], false);
    });

    test('does not hijack questions or compound requests', () {
      for (final s in [
        'how do flashlights work',
        'what is a flashlight',
        'turn on the flashlight and set a timer for 5 minutes',
        'buy a flashlight',
      ]) {
        expect(m(s), isNull, reason: s);
      }
    });
  });

  group('timer', () {
    test('parses durations', () {
      expect(m('set a timer for 5 minutes')?.args['seconds'], 300);
      expect(m('timer 90 seconds')?.args['seconds'], 90);
      expect(m('start a 10 minute timer')?.args['seconds'], 600);
      expect(m('set timer for 1 hour and 30 minutes')?.args['seconds'], 5400);
      expect(m('set a timer for half an hour')?.args['seconds'], 1800);
      expect(m('set a timer for an hour')?.args['seconds'], 3600);
      expect(m('5 min timer')?.args['seconds'], 300);
      expect(m('set a timer for 1.5 hours')?.args['seconds'], 5400);
    });

    test('needs a real duration', () {
      expect(m('set a timer'), isNull);
      expect(m('set a timer for my workout'), isNull);
      expect(m('what is a kitchen timer'), isNull);
    });
  });

  group('alarm', () {
    test('parses times', () {
      expect(m('set an alarm for 7 am')?.args, {'hour': 7, 'minute': 0});
      expect(m('set alarm at 6:30 pm')?.args, {'hour': 18, 'minute': 30});
      expect(m('wake me up at 5.45')?.args, {'hour': 5, 'minute': 45});
      expect(m('set an alarm for 12 am')?.args, {'hour': 0, 'minute': 0});
      expect(m('set an alarm for 12 pm')?.args, {'hour': 12, 'minute': 0});
      expect(m('set an alarm for 21:15')?.args, {'hour': 21, 'minute': 15});
      expect(m('set an alarm for 7 tomorrow')?.args, {'hour': 7, 'minute': 0});
      expect(m('set an alarm for 8 in the evening')?.args, {'hour': 20, 'minute': 0});
      expect(m('set an alarm for noon')?.args, {'hour': 12, 'minute': 0});
    });

    test('rejects nonsense times', () {
      expect(m('set an alarm for 25:00'), isNull);
      expect(m('set an alarm for 13 pm'), isNull);
      expect(m('set an alarm for when the sun rises'), isNull);
    });
  });

  test('volume', () {
    expect(m('set volume to 50%')?.args['level'], 50);
    expect(m('volume 30')?.args['level'], 30);
    expect(m('set the media volume to 80 percent')?.args['level'], 80);
    expect(m('mute')?.args['level'], 0);
    expect(m('max volume')?.args['level'], 100);
    expect(m('set volume to 150'), isNull);
  });

  test('time, date and battery', () {
    expect(m("what's the time")?.tool, 'get_date_time');
    expect(m('what time is it')?.tool, 'get_date_time');
    expect(m("what's today's date")?.tool, 'get_date_time');
    expect(m('what day is it')?.tool, 'get_date_time');
    expect(m('battery')?.tool, 'get_device_info');
    expect(m('how much battery do I have left')?.tool, 'get_device_info');
    expect(m('is my phone charging')?.tool, 'get_device_info');
    expect(m('why is my battery draining so fast'), isNull);
    expect(m('what time does the store close'), isNull);
  });

  test('formatters produce sentences', () {
    final time = m('what time is it')!;
    expect(time.format!({'time12': '2:05 PM'}), "It's 2:05 PM.");
    final battery = m('battery level')!;
    expect(battery.format!({'batteryPercent': 76, 'charging': true}), 'Battery is at 76% and charging.');
  });

  test('weather', () {
    expect(m("what's the weather")?.tool, 'get_weather');
    expect(m('weather in Chennai')?.args, {'location': 'chennai'});
    expect(m('what is the weather like in new york today')?.args, {'location': 'new york'});
    expect(m('is it going to rain')?.tool, 'get_weather');
    expect(m('will it rain tomorrow'), isNull, reason: 'forecast questions go to the model');
  });

  test('open app vs url', () {
    expect(m('open whatsapp')?.tool, 'launch_app_by_name');
    expect(m('open the camera app')?.args, {'appName': 'camera'});
    expect(m('open whatsapp')?.fallThroughOnError, true);
    expect(m('open github.com')?.tool, 'open_url');
    expect(m('go to https://example.com/path')?.tool, 'open_url');
    expect(m('open youtube and play some music'), isNull);
  });

  test('calls', () {
    expect(m('call 98765 43210')?.tool, 'make_phone_call');
    expect(m('call +91 98765-43210')?.args['phone'], '+9198765-43210');
    expect(m('call mom')?.tool, 'call_contact');
    expect(m('call mom')?.fallThroughOnError, true);
    expect(m('call me later'), isNull);
    expect(m('call it a day'), isNull);
  });

  test('read-only helpers', () {
    expect(m('show my latest screenshot')?.tool, 'get_recent_screenshots');
    expect(m("what's on my clipboard")?.tool, 'read_clipboard');
    expect(m('read my notifications')?.tool, 'read_notifications');
    expect(m("what's my ip")?.tool, 'get_public_ip');
    expect(m('am i online')?.tool, 'check_connectivity');
    expect(m('vibrate')?.args['duration'], 500);
    expect(m('vibrate for 2 seconds')?.args['duration'], 2000);
  });

  test('general chat is never matched', () {
    for (final s in [
      'hi',
      'tell me a joke',
      'what is the capital of france',
      'write a poem about rain',
      'how do I reset my phone',
      'explain quantum computing',
      '',
    ]) {
      expect(m(s), isNull, reason: s);
    }
  });

  test('parseDuration and parseClockTime edge cases', () {
    expect(QuickCommands.parseDuration('2 hours 15 minutes'), 8100);
    expect(QuickCommands.parseDuration('twenty seconds'), 20);
    expect(QuickCommands.parseDuration('some minutes'), isNull);
    expect(QuickCommands.parseClockTime('7'), (7, 0));
    expect(QuickCommands.parseClockTime('7:61'), isNull);
  });
}
