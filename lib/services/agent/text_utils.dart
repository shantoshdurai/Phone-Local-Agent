/// Text helpers shared by the agent backends and voice mode. Pure functions,
/// unit-tested in test/text_utils_test.dart.
library;

import 'dart:convert';

/// Rough token estimate used for context budgeting. Deliberately
/// conservative (~3.2 chars/token vs ~4 for English) so we rebuild the
/// on-device session before the native KV cache overflows, not after.
int estimateTokens(String text) => (text.length / 3.2).ceil();

/// A tool call recovered from plain model text.
class TextToolCall {
  final String name;
  final Map<String, dynamic> args;
  const TextToolCall(this.name, this.args);
}

/// Small on-device models sometimes emit a tool call the runtime's parser
/// misses: wrapped in prose, in a ```json fence, with `arguments` instead of
/// `parameters`, or as Qwen-style XML with a Python literal. Finds the first
/// call naming one of [allowed] tools.
TextToolCall? extractToolCallFromText(String text, Set<String> allowed) {
  if (allowed.isEmpty) return null;
  final xml = _extractXmlToolCall(text, allowed);
  if (xml != null) return xml;
  if (!text.contains('{')) return null;
  for (final candidate in _jsonObjects(text)) {
    Object? decoded;
    try {
      decoded = jsonDecode(candidate);
    } catch (_) {
      continue;
    }
    if (decoded is! Map) continue;
    var map = Map<String, dynamic>.from(decoded);
    // {"function": {"name": ..., "arguments": ...}} / {"tool_call": {...}}
    for (final wrapper in const ['function', 'tool_call', 'function_call']) {
      if (map[wrapper] is Map) map = Map<String, dynamic>.from(map[wrapper] as Map);
    }
    final name = map['name'] ?? map['tool'] ?? map['tool_name'];
    if (name is! String || !allowed.contains(name)) continue;
    var args = map['parameters'] ?? map['arguments'] ?? map['args'] ?? const {};
    if (args is String) {
      try {
        args = jsonDecode(args);
      } catch (_) {
        args = const {};
      }
    }
    return TextToolCall(name, args is Map ? Map<String, dynamic>.from(args) : {});
  }
  return null;
}

/// Qwen3.5 / Qwen3-Coder style calls, which a model sometimes writes as text
/// when a value doesn't match the schema (e.g. Python's `True`):
/// `<function=set_alarm><parameter=hour>7</parameter></function>`.
TextToolCall? _extractXmlToolCall(String text, Set<String> allowed) {
  final fn = RegExp(r'<function=([A-Za-z0-9_\-]+)>([\s\S]*?)(?:</function>|$)').firstMatch(text);
  if (fn == null || !allowed.contains(fn.group(1))) return null;
  final args = <String, dynamic>{};
  for (final p in RegExp(r'<parameter=([A-Za-z0-9_\-]+)>([\s\S]*?)</parameter>').allMatches(fn.group(2)!)) {
    args[p.group(1)!] = coerceScalar(p.group(2)!.trim());
  }
  return TextToolCall(fn.group(1)!, args);
}

/// "True"/"false" → bool, "42" → int, "4.5" → double, JSON → decoded,
/// anything else stays a string.
Object? coerceScalar(String raw) {
  final lower = raw.toLowerCase();
  if (lower == 'true') return true;
  if (lower == 'false') return false;
  if (lower == 'null' || lower == 'none') return null;
  final i = int.tryParse(raw);
  if (i != null) return i;
  final d = double.tryParse(raw);
  if (d != null) return d;
  if ((raw.startsWith('{') && raw.endsWith('}')) || (raw.startsWith('[') && raw.endsWith(']'))) {
    try {
      return jsonDecode(raw);
    } catch (_) {}
  }
  return raw;
}

/// Balanced `{...}` substrings, outermost first, respecting JSON strings.
Iterable<String> _jsonObjects(String s) sync* {
  for (var start = s.indexOf('{'); start >= 0; start = s.indexOf('{', start + 1)) {
    var depth = 0;
    var inString = false;
    var escaped = false;
    for (var i = start; i < s.length; i++) {
      final c = s[i];
      if (inString) {
        if (escaped) {
          escaped = false;
        } else if (c == '\\') {
          escaped = true;
        } else if (c == '"') {
          inString = false;
        }
        continue;
      }
      if (c == '"') {
        inString = true;
      } else if (c == '{') {
        depth++;
      } else if (c == '}') {
        depth--;
        if (depth == 0) {
          yield s.substring(start, i + 1);
          break;
        }
      }
    }
  }
}

/// True while streamed text looks like the start of tool-call markup rather
/// than prose, so the UI can hold it back instead of flashing raw JSON.
bool looksLikeToolCallStart(String text) {
  final t = text.trimLeft();
  if (t.isEmpty) return false;
  return t.startsWith('{') ||
      t.startsWith('```') ||
      t.startsWith('<tool') ||
      t.startsWith('<|tool') ||
      t.startsWith('[{') ||
      t.startsWith('<function') ||
      t.startsWith('<start_function');
}

/// The part of streamed text that is safe to show: everything before the
/// first sign of tool-call markup. Some chat formats (Qwen3.5's XML calls)
/// stream the raw call into the text channel before it is parsed.
String visiblePrefix(String text) {
  if (looksLikeToolCallStart(text)) return '';
  const markers = [
    '<tool_call',
    '<|tool_call',
    '```json',
    '```tool',
    '{"name"',
    '{ "name"',
    '<start_function_call',
    '<function',
  ];
  var cut = text.length;
  for (final m in markers) {
    final i = text.indexOf(m);
    if (i >= 0 && i < cut) cut = i;
  }
  return text.substring(0, cut);
}

/// Removes leftover control tokens and tool-call markup from final model
/// text.
String cleanModelText(String text) {
  var t = text;
  t = t.replaceAll(RegExp(r'<think>[\s\S]*?</think>'), '');
  t = t.replaceAll(RegExp(r'<tool_call>[\s\S]*?</tool_call>'), '');
  t = t.replaceAll(RegExp(r'<\|tool_call>[\s\S]*?<tool_call\|>'), '');
  t = t.replaceAll(RegExp(r'<function=[\s\S]*?</function>'), '');
  t = t.replaceAll(RegExp(r'</?tool_call>'), '');
  t = t.replaceAll(
      RegExp(r'<\|?(?:im_end|im_start|end_of_turn|start_of_turn|eot_id|end)\|?>'), '');
  t = t.replaceAll('<end_of_turn>', '').replaceAll('<start_of_turn>', '');
  return t.trim();
}

/// A reply that announces an action instead of doing it ("I will try again
/// with a better query", "Let me search for that"). Small models sometimes
/// stop there without emitting the tool call.
bool promisesAction(String text) {
  final t = text.toLowerCase();
  if (t.length > 400) return false;
  return RegExp(
    r"\b(?:i(?:'ll| will| am going to|'m going to| need to| should)|let me|allow me to)\s+"
    r"(?:now\s+|quickly\s+|first\s+)?"
    r"(?:try|search|look|check|find|do|get|call|open|set|use|run|fetch|query|see)\b",
  ).hasMatch(t);
}

/// Degenerate output from an overloaded small model: empty, whitespace, a
/// single repeated character, or a short token loop.
bool isDegenerateOutput(String text) {
  final t = text.trim();
  if (t.isEmpty) return true;
  final compact = t.replaceAll(RegExp(r'\s'), '');
  if (compact.isEmpty) return true;
  if (compact.length >= 12 && compact.split('').toSet().length <= 2) return true;
  final words = t.toLowerCase().split(RegExp(r'\s+'));
  if (words.length >= 30) {
    final unique = words.toSet().length;
    if (unique / words.length < 0.2) return true;
  }
  return false;
}

/// Detects a model stuck repeating itself mid-stream (e.g. "190 190 190",
/// or a cycling phrase). Checks the tail of the text only, so it is cheap
/// to call on every token.
bool isStuckInLoop(String text) {
  if (text.length < 120) return false;
  final tail = text.substring(text.length - 120);
  for (var period = 2; period <= 40; period++) {
    final unit = tail.substring(tail.length - period);
    if (unit.trim().isEmpty) continue;
    var repeats = 0;
    var pos = tail.length - period;
    while (pos >= 0 && tail.substring(pos, pos + period) == unit) {
      repeats++;
      pos -= period;
    }
    if (repeats * period >= 90 && repeats >= 4) return true;
  }
  return false;
}

/// Converts markdown to speakable text for TTS.
String stripForSpeech(String text) {
  var t = text;
  t = t.replaceAll(RegExp(r'```[\s\S]*?```'), ' ');
  t = t.replaceAllMapped(RegExp(r'`([^`]+)`'), (m) => m[1]!);
  t = t.replaceAllMapped(RegExp(r'!\[([^\]]*)\]\([^)]*\)'), (m) => m[1]!);
  t = t.replaceAllMapped(RegExp(r'\[([^\]]+)\]\([^)]*\)'), (m) => m[1]!);
  t = t.replaceAll(RegExp(r'https?://\S+'), 'a link');
  t = t.replaceAllMapped(RegExp(r'\*\*([^*]+)\*\*'), (m) => m[1]!);
  t = t.replaceAllMapped(RegExp(r'__([^_]+)__'), (m) => m[1]!);
  t = t.replaceAllMapped(RegExp(r'(?<![\w*])\*([^*\n]+)\*(?![\w*])'), (m) => m[1]!);
  t = t.replaceAll(RegExp(r'^#{1,6}\s*', multiLine: true), '');
  t = t.replaceAll(RegExp(r'^\s*[-*•]\s+', multiLine: true), '');
  t = t.replaceAll(RegExp(r'^\s*\d+\.\s+', multiLine: true), '');
  t = t.replaceAll(RegExp(r'^\s*>\s?', multiLine: true), '');
  t = t.replaceAll(RegExp(r'\|'), ' ');
  t = t.replaceAll('°C', ' degrees');
  t = t.replaceAll(RegExp(r'[ \t]+'), ' ');
  t = t.replaceAll(RegExp(r'\n{2,}'), '\n');
  return t.trim();
}

/// Splits text into TTS-sized chunks at sentence boundaries. Android's TTS
/// engine silently drops utterances longer than ~4000 characters.
List<String> splitForSpeech(String text, {int maxChars = 350}) {
  final sentences = text
      .split(RegExp(r'(?<=[.!?。])\s+|\n+'))
      .map((s) => s.trim())
      .where((s) => s.isNotEmpty);
  final out = <String>[];
  final current = StringBuffer();
  for (final s in sentences) {
    if (current.isNotEmpty && current.length + s.length + 1 > maxChars) {
      out.add(current.toString());
      current.clear();
    }
    if (s.length > maxChars) {
      for (var i = 0; i < s.length; i += maxChars) {
        out.add(s.substring(i, i + maxChars > s.length ? s.length : i + maxChars));
      }
      continue;
    }
    if (current.isNotEmpty) current.write(' ');
    current.write(s);
  }
  if (current.isNotEmpty) out.add(current.toString());
  return out;
}

String clip(String s, int max) =>
    s.length <= max ? s : '${s.substring(0, max).trimRight()}…';
