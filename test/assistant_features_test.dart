import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:local_agent/services/agent/quick_commands.dart';
import 'package:local_agent/services/agent/text_utils.dart';
import 'package:local_agent/services/media_service.dart';
import 'package:local_agent/services/memory_service.dart';
import 'package:local_agent/services/search_service.dart';
import 'package:local_agent/services/tools/tool_runtime.dart';
import 'package:shared_preferences/shared_preferences.dart';

String fixture(String name) => File('test/fixtures/$name').readAsStringSync();

void main() {
  QuickCommand? m(String s) => QuickCommands.match(s);

  group('messages to contacts', () {
    test('WhatsApp by name keeps the message wording', () {
      final c = m("text mom on WhatsApp that I'm running late")!;
      expect(c.tool, 'message_contact_whatsapp');
      expect(c.args, {'name': 'mom', 'message': "I'm running late"});
      expect(c.fallThroughOnError, isTrue);

      expect(m('WhatsApp Priya: Happy birthday! 🎉')?.args,
          {'name': 'Priya', 'message': 'Happy birthday! 🎉'});
      expect(m('send a whatsapp message to John saying see you at 5')?.args,
          {'name': 'John', 'message': 'see you at 5'});
      expect(m('tell dad on whatsapp that dinner is ready')?.tool, 'message_contact_whatsapp');
    });

    test('text without WhatsApp goes to SMS', () {
      final c = m('text my sister that I reached home')!;
      expect(c.tool, 'message_contact_sms');
      expect(c.args, {'name': 'sister', 'message': 'I reached home'});
    });

    test('does not treat chat as a message request', () {
      for (final s in [
        'tell me a joke',
        'tell me that you love me',
        'tell mom that I said hi',
        'text me when you are done',
        'what is a text message',
      ]) {
        final c = m(s);
        expect(c == null || !c.tool.startsWith('message_contact'), isTrue, reason: s);
      }
    });
  });

  group('memory commands', () {
    test('remember keeps the fact as written', () {
      expect(m("Remember that my sister's name is Priya")?.args, {'fact': "my sister's name is Priya"});
      expect(m('please remember I park on level 3')?.args, {'fact': 'I park on level 3'});
      expect(m('remember me'), isNull);
      expect(m('remember what I told you yesterday?'), isNull);
      expect(m('what do you remember about me?')?.tool, 'recall_memory');
      expect(m('show my memories')?.tool, 'recall_memory');
    });
  });

  group('play', () {
    test('picks the app and cleans the query', () {
      expect(m('play Blinding Lights on Spotify')?.args, {'query': 'Blinding Lights', 'app': 'spotify'});
      expect(m('play lofi hip hop on youtube')?.args, {'query': 'lofi hip hop', 'app': 'youtube'});
      expect(m('put on some Arijit Singh songs on YouTube Music')?.args,
          {'query': 'Arijit Singh songs', 'app': 'youtube_music'});
      expect(m('play the video of Messi goals')?.args['app'], 'youtube');
    });

    test('games and vague requests go to the model', () {
      expect(m('play a game with me'), isNull);
      expect(m('play trivia'), isNull);
      expect(m('play music'), isNull);
    });

    test('reply sentences', () {
      expect(
        ToolRuntime.formatDirect('play_media', {}, {'success': true, 'playing': true, 'app': 'YouTube', 'title': 'Lofi mix', 'query': 'lofi'}),
        'Playing "Lofi mix" on YouTube.',
      );
      expect(
        ToolRuntime.formatDirect('send_whatsapp', {'contact': 'Mom'}, {'success': true}),
        'WhatsApp is open with your message to Mom. Tap send.',
      );
    });

    test('YouTube results page', () {
      final v = MediaService.parseFirstVideo(fixture('youtube_results_snippet.txt'))!;
      expect(v.id, 'n61ULEU7CO0');
      expect(v.title, contains('lofi hip hop'));
      expect(MediaService.parseFirstVideo('<html></html>'), isNull);
    });
  });

  group('search relevance', () {
    test('drops results that only share a stop-word', () {
      final results = [
        const SearchResult('WON Definition & Meaning - Merriam-Webster', 'The meaning of WON is...', 'https://www.merriam-webster.com/dictionary/won'),
        const SearchResult('Norris wins F1 Dutch Grand Prix race', 'Lando Norris won the race...', 'https://f1.com/x'),
      ];
      final kept = SearchService.filterRelevant(results, 'who won the last F1 race');
      expect(kept.map((r) => r.title), ['Norris wins F1 Dutch Grand Prix race']);
    });

    test('short queries need every term', () {
      final kept = SearchService.filterRelevant([
        const SearchResult('Chennai weather', '', 'https://x.com'),
        const SearchResult('Weather in London', '', 'https://y.com'),
      ], 'Chennai weather');
      expect(kept.length, 1);
    });

    test('Google News RSS', () {
      final news = SearchService.parseGoogleNewsRss(fixture('google_news_f1.xml'));
      expect(news.length, 3);
      expect(news.first.published, isNotNull);
      expect(news.first.source, isNotNull);
      expect(news.first.title, isNot(endsWith(' - ${news.first.source}')));
      final json = news.first.toJson();
      expect(json.containsKey('url'), isFalse, reason: 'long redirect URLs cost tokens');
      expect(json['published'], matches(RegExp(r'^\d{4}-\d{2}-\d{2}$')));
    });
  });

  group('agent text helpers', () {
    test('XML tool calls with Python literals are recovered', () {
      final c = extractToolCallFromText(
        "I'll turn it on! <tool_call> <function=toggle_flashlight> <parameter=on> True </parameter> </function> </tool_call>",
        {'toggle_flashlight'},
      );
      expect(c?.name, 'toggle_flashlight');
      expect(c?.args, {'on': true});
      expect(cleanModelText('Done. <function=x><parameter=a>1</parameter></function>'), 'Done.');
    });

    test('announced-but-not-taken actions are detected', () {
      expect(promisesAction('I will try again with a more specific query.'), isTrue);
      expect(promisesAction('Let me search for that.'), isTrue);
      expect(promisesAction("I'll check the weather now."), isTrue);
      expect(promisesAction('Norris won the Dutch Grand Prix.'), isFalse);
      expect(promisesAction('Let me know if you need anything else.'), isFalse);
    });
  });

  group('memory store', () {
    setUp(() => SharedPreferences.setMockInitialValues({}));

    test('adds, dedupes, ranks and builds the prompt block', () async {
      final mem = MemoryService.instance;
      await mem.add("that my sister's name is Priya.");
      await mem.add('I park on level 3');
      await mem.add("My sister's name is Priya");
      final all = await mem.all();
      expect(all.map((e) => e.text), ["My sister's name is Priya", 'I park on level 3']);
      expect((await mem.search("what's my sister called")).first.text, contains('Priya'));
      expect(await mem.search('parking level'), isNotEmpty);
      expect(await mem.promptBlock(), contains('- I park on level 3'));
      await mem.setEnabled(false);
      expect(await mem.promptBlock(), isNull);
      await mem.delete(all.first.id);
      expect((await mem.all()).length, 1);
    });
  });
}
