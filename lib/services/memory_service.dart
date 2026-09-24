import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

class Memory {
  final int id;
  final String text;
  final DateTime created;
  const Memory(this.id, this.text, this.created);

  Map<String, dynamic> toJson() => {'id': id, 'text': text, 'created': created.millisecondsSinceEpoch};

  static Memory? fromJson(Object? j) {
    if (j is! Map || j['id'] is! int || j['text'] is! String) return null;
    return Memory(
      j['id'] as int,
      j['text'] as String,
      DateTime.fromMillisecondsSinceEpoch((j['created'] as int?) ?? 0),
    );
  }
}

/// Facts the user asked the assistant to remember ("remember that my
/// sister's name is Priya"). Kept on the phone only.
///
/// Memories reach the model two ways: the remember/recall_memory tools,
/// and, when "Use memory" is on, a short block in the system prompt. The
/// block is part of the cached prompt prefix, so on-device models pay for it
/// once per chat, not on every message.
class MemoryService {
  MemoryService._();
  static final MemoryService instance = MemoryService._();

  static const _kMemories = 'memories_v1';
  static const _kEnabled = 'memory_enabled_v1';
  static const maxMemories = 100;
  static const maxLength = 300;

  Future<SharedPreferences> get _prefs => SharedPreferences.getInstance();

  Future<bool> enabled() async => (await _prefs).getBool(_kEnabled) ?? true;
  Future<void> setEnabled(bool value) async => (await _prefs).setBool(_kEnabled, value);

  Future<List<Memory>> all() async {
    try {
      final raw = (await _prefs).getString(_kMemories);
      if (raw == null) return [];
      return (jsonDecode(raw) as List).map(Memory.fromJson).whereType<Memory>().toList();
    } catch (_) {
      return [];
    }
  }

  Future<void> _save(List<Memory> list) async =>
      (await _prefs).setString(_kMemories, jsonEncode([for (final m in list) m.toJson()]));

  /// Saves [text]; returns the stored memory, or the existing one if the
  /// same fact is already saved.
  Future<Memory> add(String text) async {
    final clean = normalizeFact(text);
    final list = await all();
    for (final m in list) {
      if (m.text.toLowerCase() == clean.toLowerCase()) return m;
    }
    final id = list.isEmpty ? 1 : list.map((m) => m.id).reduce((a, b) => a > b ? a : b) + 1;
    final memory = Memory(id, clean, DateTime.now());
    list.add(memory);
    while (list.length > maxMemories) {
      list.removeAt(0);
    }
    await _save(list);
    return memory;
  }

  Future<void> delete(int id) async => _save((await all()).where((m) => m.id != id).toList());

  Future<void> clear() async => (await _prefs).remove(_kMemories);

  /// Memories most relevant to [query] (word overlap), or the newest ones
  /// when there is no query.
  Future<List<Memory>> search(String? query, {int limit = 8}) async =>
      rank(await all(), query, limit: limit);

  /// Short prompt block with the newest memories, or null when memory is off
  /// or empty.
  Future<String?> promptBlock({int maxChars = 600}) async {
    if (!await enabled()) return null;
    final list = await all();
    if (list.isEmpty) return null;
    final lines = <String>[];
    var used = 0;
    for (final m in list.reversed) {
      if (used + m.text.length + 3 > maxChars) break;
      lines.add('- ${m.text}');
      used += m.text.length + 3;
    }
    return 'Things the user asked you to remember:\n${lines.reversed.join('\n')}';
  }

  /// "that my sister's name is Priya." → "My sister's name is Priya".
  static String normalizeFact(String text) {
    var t = text.trim();
    t = t.replaceFirst(RegExp(r'^(?:that|this)\s+', caseSensitive: false), '');
    t = t.replaceAll(RegExp(r'[.!\s]+$'), '');
    if (t.length > maxLength) t = t.substring(0, maxLength);
    return t.isEmpty ? t : t[0].toUpperCase() + t.substring(1);
  }

  static List<Memory> rank(List<Memory> list, String? query, {int limit = 8}) {
    final words = _words(query ?? '');
    if (words.isEmpty) return list.reversed.take(limit).toList();
    final scored = <(int, Memory)>[];
    for (final m in list) {
      final overlap = _words(m.text).intersection(words).length;
      if (overlap > 0) scored.add((overlap, m));
    }
    scored.sort((a, b) => b.$1 != a.$1 ? b.$1.compareTo(a.$1) : b.$2.id.compareTo(a.$2.id));
    return scored.take(limit).map((e) => e.$2).toList();
  }

  static const _stop = {
    'the', 'a', 'an', 'my', 'is', 'are', 'was', 'of', 'to', 'and', 'what', 'who',
    'do', 'you', 'i', 'me', 'about', 'remember', 'know', 'in', 'on', 'for', 'at',
  };

  static Set<String> _words(String s) => s
      .toLowerCase()
      .split(RegExp(r"[^a-z0-9']+"))
      .where((w) => w.length > 1 && !_stop.contains(w))
      .map((w) => w.endsWith("'s") ? w.substring(0, w.length - 2) : w)
      .toSet();
}
