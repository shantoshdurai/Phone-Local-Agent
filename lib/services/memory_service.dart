import 'dart:async';

import 'database_service.dart';

/// What kind of fact this is. Identity facts (name, city) outrank preferences
/// when the prompt budget is tight.
enum FactKind { identity, preference, other }

FactKind _kindFromString(String s) {
  switch (s) {
    case 'identity':
      return FactKind.identity;
    case 'preference':
      return FactKind.preference;
    default:
      return FactKind.other;
  }
}

String kindToString(FactKind k) {
  switch (k) {
    case FactKind.identity:
      return 'identity';
    case FactKind.preference:
      return 'preference';
    case FactKind.other:
      return 'other';
  }
}

class MemoryFact {
  final int id;
  final String text;
  final FactKind kind;
  final DateTime createdAt;
  final int useCount;

  const MemoryFact({
    required this.id,
    required this.text,
    required this.kind,
    required this.createdAt,
    required this.useCount,
  });
}

/// Persistent, on-device memory of durable facts about the user.
///
/// Design choices:
/// - **Heuristic capture, not a second model call.** Asking a 1.5B model
///   "extract facts from this message" on every turn doubles latency and
///   hallucinates. A small set of high-precision patterns catches the things
///   people actually say ("my name is…", "I live in…", "remember that…") at
///   zero cost. Anything else can be added manually in the Memory screen.
/// - **Bounded prompt injection.** Facts are injected as a short block in the
///   system prompt, capped by count and characters. Unbounded memory is how
///   small models get worse over time.
/// - **User-visible and editable.** Every fact can be deleted, and capturing
///   one shows an undo toast. Invisible memory is a trust bug, not a feature.
class MemoryService {
  MemoryService._();
  static final MemoryService instance = MemoryService._();

  final DatabaseService _db = DatabaseService();
  final StreamController<MemoryFact> _captured =
      StreamController<MemoryFact>.broadcast();

  /// Emits every fact captured automatically, so the UI can offer an undo.
  Stream<MemoryFact> get captured => _captured.stream;

  List<MemoryFact>? _cache;

  static const int maxFacts = 60;
  static const int _promptMaxFacts = 10;
  static const int _promptMaxChars = 420;

  Future<List<MemoryFact>> all() async {
    if (_cache != null) return _cache!;
    try {
      final rows = await _db.getFacts();
      _cache = rows
          .map((r) => MemoryFact(
                id: r['id'] as int,
                text: r['text'] as String,
                kind: _kindFromString((r['kind'] as String?) ?? 'other'),
                createdAt:
                    DateTime.tryParse((r['created_at'] as String?) ?? '') ??
                        DateTime.now(),
                useCount: (r['use_count'] as int?) ?? 0,
              ))
          .toList();
    } catch (_) {
      _cache = const [];
    }
    return _cache!;
  }

  Future<int> count() async => (await all()).length;

  /// The block appended to the system prompt. Empty string when there is
  /// nothing to say, so callers can concatenate unconditionally.
  Future<String> promptBlock() async {
    final facts = await all();
    if (facts.isEmpty) return '';

    // Identity first (name/city are referenced most), then preferences, then
    // free-form notes; newest first inside each kind.
    final ordered = [...facts]..sort((a, b) {
        final byKind = a.kind.index.compareTo(b.kind.index);
        if (byKind != 0) return byKind;
        return b.createdAt.compareTo(a.createdAt);
      });

    final lines = <String>[];
    var chars = 0;
    for (final f in ordered) {
      if (lines.length >= _promptMaxFacts) break;
      final line = '- ${f.text}';
      if (chars + line.length > _promptMaxChars) break;
      lines.add(line);
      chars += line.length + 1;
    }
    if (lines.isEmpty) return '';

    return 'Known facts the user shared in earlier conversations. '
        'Use them naturally when relevant. Never list them back, never mention '
        'that you have a memory list, and never invent facts that are not '
        'listed here.\n${lines.join('\n')}';
  }

  /// Add a fact manually (Memory screen) or from capture. Returns null when it
  /// duplicates something already known.
  Future<MemoryFact?> add(String rawText, {FactKind kind = FactKind.other}) async {
    final text = _clean(rawText);
    if (text.isEmpty) return null;

    final existing = await all();
    final normalized = _normalize(text);
    for (final f in existing) {
      if (_normalize(f.text) == normalized) return null;
    }

    // A new name supersedes the old one instead of accumulating aliases.
    if (text.toLowerCase().startsWith('name:')) {
      for (final f in existing) {
        if (f.text.toLowerCase().startsWith('name:')) {
          await _db.deleteFact(f.id);
        }
      }
    }

    final id = await _db.insertFact(text, kindToString(kind));
    await _db.trimFacts(cap: maxFacts);
    _cache = null;

    return MemoryFact(
      id: id,
      text: text,
      kind: kind,
      createdAt: DateTime.now(),
      useCount: 0,
    );
  }

  Future<void> remove(int id) async {
    await _db.deleteFact(id);
    _cache = null;
  }

  Future<void> clear() async {
    await _db.clearFacts();
    _cache = null;
  }

  // ── Heuristic capture ───────────────────────────────────────────────────

  /// Inspect a user message for a durable fact. Returns the captured fact, or
  /// null when nothing high-confidence was found.
  Future<MemoryFact?> captureFromUserText(String message) async {
    final text = message.trim();
    if (text.length < 6 || text.length > 600) return null;

    // Questions are requests for information, not statements about the user,
    // unless they explicitly ask us to remember something.
    final explicitRemember = RegExp(r'\b(remember|note that|keep in mind)\b',
            caseSensitive: false)
        .hasMatch(text);
    if (!explicitRemember && _looksLikeQuestion(text)) return null;

    // A single message often contains two facts ("my name is Sam and I live in
    // Paris"). Capture up to two, but never let a broad "remember …" pattern
    // duplicate a specific one.
    MemoryFact? first;
    var added = 0;
    for (final pattern in _patterns) {
      if (added >= 2) break;
      if (pattern.label == null && added > 0) continue;
      final match = pattern.regex.firstMatch(text);
      if (match == null) continue;

      String value;
      String label;
      if (pattern.label == null) {
        value = (match.group(1) ?? '').trim();
        label = '';
      } else if (pattern.label == 'Favourite') {
        final thing = (match.group(1) ?? '').trim();
        value = (match.group(2) ?? '').trim();
        label = 'Favourite ${thing.isEmpty ? 'thing' : thing}';
      } else {
        value = (match.group(1) ?? '').trim();
        label = pattern.label!;
      }

      value = _cleanValue(value, label: label);
      if (value.isEmpty) continue;

      final factText = label.isEmpty ? value : '$label: $value';
      final fact = await add(factText, kind: pattern.kind);
      if (fact == null) continue;

      first ??= fact;
      added++;
      // Only automatic captures go on the stream, so the chat UI can offer an
      // undo. Manual additions in the Memory screen are already visible there.
      if (!_captured.isClosed) _captured.add(fact);
    }
    return first;
  }

  bool _looksLikeQuestion(String text) {
    if (text.endsWith('?')) return true;
    return RegExp(r'^(what|who|where|when|why|how|is|are|can|could|should|do|does|did|will|would)\b',
            caseSensitive: false)
        .hasMatch(text);
  }

  // RegExp is not a const constructor, so this list is `final` rather than
  // `const`; it is built once at class initialization.
  static final List<({RegExp regex, FactKind kind, String? label})> _patterns = [
    (
      regex: RegExp(r"\bmy name is ([a-z][a-z .'\-]{0,30})",
          caseSensitive: false),
      kind: FactKind.identity,
      label: 'Name',
    ),
    (
      regex: RegExp(r"\bcall me ([a-z][a-z .'\-]{0,24})", caseSensitive: false),
      kind: FactKind.identity,
      label: 'Name',
    ),
    (
      regex: RegExp(r"\bi live in ([a-z0-9][a-z0-9 ,.'\-]{0,40})",
          caseSensitive: false),
      kind: FactKind.identity,
      label: 'Lives in',
    ),
    (
      regex: RegExp(r"\bi(?:'m| am) from ([a-z0-9][a-z0-9 ,.'\-]{0,40})",
          caseSensitive: false),
      kind: FactKind.identity,
      label: 'From',
    ),
    (
      regex: RegExp(r"\bi work (?:at|for) ([a-z0-9][a-z0-9 ,.&'\-]{0,48})",
          caseSensitive: false),
      kind: FactKind.identity,
      label: 'Works at',
    ),
    (
      regex: RegExp(r"\bi work as (?:a |an )?([a-z0-9][a-z0-9 ,.'\-]{0,48})",
          caseSensitive: false),
      kind: FactKind.identity,
      label: 'Works as',
    ),
    (
      regex: RegExp(r"\bmy birthday is ([a-z0-9][a-z0-9 ,.'\-]{0,28})",
          caseSensitive: false),
      kind: FactKind.identity,
      label: 'Birthday',
    ),
    (
      regex: RegExp(r"\bmy timezone is ([a-z0-9/_+\- ]{2,40})",
          caseSensitive: false),
      kind: FactKind.preference,
      label: 'Timezone',
    ),
    (
      regex: RegExp(
          r"\bmy (?:favourite|favorite) ([a-z ]{2,24}) is ([a-z0-9][a-z0-9 ,.'\-]{0,40})",
          caseSensitive: false),
      kind: FactKind.preference,
      label: 'Favourite',
    ),
    (
      regex: RegExp(r"\bi prefer ([a-z0-9][a-z0-9 ,.'\-]{0,60})",
          caseSensitive: false),
      kind: FactKind.preference,
      label: 'Prefers',
    ),
    (
      regex: RegExp(r"\bi (?:don't|do not) like ([a-z0-9][a-z0-9 ,.'\-]{0,50})",
          caseSensitive: false),
      kind: FactKind.preference,
      label: 'Dislikes',
    ),
    (
      regex: RegExp(r"\bi (?:really )?(?:like|love) ([a-z0-9][a-z0-9 ,.'\-]{0,50})",
          caseSensitive: false),
      kind: FactKind.preference,
      label: 'Likes',
    ),
    (
      regex: RegExp(r"\bremember (?:that |this:? )?(.{3,140})",
          caseSensitive: false),
      kind: FactKind.other,
      label: null,
    ),
    (
      regex: RegExp(r"\bnote that (.{3,140})", caseSensitive: false),
      kind: FactKind.other,
      label: null,
    ),
    (
      regex: RegExp(r"\bkeep in mind (?:that )?(.{3,140})",
          caseSensitive: false),
      kind: FactKind.other,
      label: null,
    ),
  ];

  static const Set<String> _stopPrefixes = {
    'this', 'that', 'it', 'these', 'those', 'you', 'your', 'him', 'her',
    'them', 'the', 'a', 'an', 'to', 'so', 'but', 'when', 'if', 'how', 'why',
    'what', 'being', 'feeling', 'doing', 'going', 'having', 'getting', 'not',
    'really', 'very', 'just', 'about', 'for', 'with', 'because',
  };

  String _cleanValue(String value, {required String label}) {
    var v = value.trim();
    // Cut clause tails: "I live in Paris and work in London" → "Paris".
    for (final cut in [' and ', ' but ', ' because ', ' so ', ' which ']) {
      final i = v.indexOf(cut);
      if (i > 0) v = v.substring(0, i);
    }
    v = v.replaceAll(RegExp(r'[\s,.;:!?]+$'), '').trim();
    if (v.length < 2 || v.length > 140) return '';
    final first = v.split(RegExp(r'\s+')).first.toLowerCase();
    if (label != 'Name' &&
        label.isNotEmpty &&
        _stopPrefixes.contains(first) &&
        label != 'Likes' &&
        label != 'Dislikes' &&
        label != 'Prefers') {
      return '';
    }
    if ((label == 'Likes' || label == 'Dislikes' || label == 'Prefers') &&
        _stopPrefixes.contains(first)) {
      return '';
    }
    return _capitalize(v);
  }

  String _clean(String raw) {
    var v = raw.replaceAll(RegExp(r'\s+'), ' ').trim();
    v = v.replaceAll(RegExp(r'[\s,.;:!?]+$'), '');
    if (v.length > 160) v = '${v.substring(0, 160)}…';
    return v;
  }

  String _normalize(String s) =>
      s.toLowerCase().replaceAll(RegExp(r'[^a-z0-9 ]'), '').trim();

  String _capitalize(String s) =>
      s.isEmpty ? s : s[0].toUpperCase() + s.substring(1);
}
