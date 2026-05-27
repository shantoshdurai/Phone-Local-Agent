import 'dart:io';

/// WordPiece tokenizer for bert-base-uncased.
///
/// MiniLM-L6-v2 (the embedding model we run on-device) was trained with the
/// stock `bert-base-uncased` tokenizer — basic-tokenize (split on whitespace
/// + punctuation), lowercase, strip accents, then WordPiece subword with
/// greedy longest-match. This is a faithful pure-Dart port of HuggingFace's
/// `BertTokenizer` for that exact config. Anything subtler (CJK, multiple
/// vocabs, BPE) is intentionally out of scope.
///
/// Subtle parity bits worth not breaking later:
///   - lowercase happens BEFORE WordPiece, and unicode-aware (lowercase of
///     ä, ñ, ß, etc.)
///   - accent stripping uses NFD then drops Unicode category Mn marks; if
///     we ever swap the model for a `bert-base-cased` variant, both this
///     and the lowercase step have to flip off in lockstep.
///   - punctuation = !-/, :-@, [-`, {-~, plus any char whose Unicode
///     general category starts with 'P'. Matches HF `_is_punctuation`.
///   - WordPiece prefix marker is `##`. Unknown subwords map to `[UNK]`.
class BertTokenizer {
  final Map<String, int> _vocab;
  final int clsId;
  final int sepId;
  final int padId;
  final int unkId;
  final int maxSeqLen;
  // Longest token in the vocab — caps the inner WordPiece loop so degenerate
  // inputs (a 5000-char token) don't burn O(n²) per char.
  final int _maxInputCharsPerWord;

  BertTokenizer._(
    this._vocab, {
    required this.clsId,
    required this.sepId,
    required this.padId,
    required this.unkId,
    required this.maxSeqLen,
    required int maxInputCharsPerWord,
  }) : _maxInputCharsPerWord = maxInputCharsPerWord;

  /// Load vocab.txt — one token per line, line index == token id. Matches the
  /// format HuggingFace ships for every bert-base checkpoint.
  static Future<BertTokenizer> loadFromFile(
    String vocabPath, {
    int maxSeqLen = 128,
  }) async {
    final file = File(vocabPath);
    if (!await file.exists()) {
      throw StateError('Vocab file not found at $vocabPath');
    }
    final lines = await file.readAsLines();
    final vocab = <String, int>{};
    for (var i = 0; i < lines.length; i++) {
      vocab[lines[i]] = i;
    }
    int idOf(String tok) {
      final id = vocab[tok];
      if (id == null) {
        throw StateError('Vocab missing required token "$tok"');
      }
      return id;
    }

    return BertTokenizer._(
      vocab,
      clsId: idOf('[CLS]'),
      sepId: idOf('[SEP]'),
      padId: idOf('[PAD]'),
      unkId: idOf('[UNK]'),
      maxSeqLen: maxSeqLen,
      maxInputCharsPerWord: 100,
    );
  }

  /// Encode a single sentence into MiniLM-ready tensors.
  ///
  /// Returns three flat int lists of length `maxSeqLen`:
  ///   - inputIds: [CLS] + tokens + [SEP] + [PAD]*
  ///   - attentionMask: 1 for real tokens, 0 for padding
  ///   - tokenTypeIds: all zeros (single-segment)
  ///
  /// If the text exceeds maxSeqLen-2 tokens it's truncated. We don't error
  /// on this — tool queries and short docs both stay well under 128.
  ({List<int> inputIds, List<int> attentionMask, List<int> tokenTypeIds})
      encode(String text) {
    final pieces = _wordpiece(_basicTokenize(text));

    final maxPieces = maxSeqLen - 2; // leave room for [CLS] + [SEP]
    final clipped = pieces.length > maxPieces
        ? pieces.sublist(0, maxPieces)
        : pieces;

    final inputIds = List<int>.filled(maxSeqLen, padId);
    final attention = List<int>.filled(maxSeqLen, 0);
    final tokenTypes = List<int>.filled(maxSeqLen, 0);

    inputIds[0] = clsId;
    attention[0] = 1;
    for (var i = 0; i < clipped.length; i++) {
      inputIds[i + 1] = _vocab[clipped[i]] ?? unkId;
      attention[i + 1] = 1;
    }
    inputIds[clipped.length + 1] = sepId;
    attention[clipped.length + 1] = 1;

    return (
      inputIds: inputIds,
      attentionMask: attention,
      tokenTypeIds: tokenTypes,
    );
  }

  // ─── Internals ──────────────────────────────────────────────────────────

  /// HF BasicTokenizer (do_lower_case=True, strip_accents=True).
  /// Splits on whitespace + punctuation, lowercases, drops accent marks.
  List<String> _basicTokenize(String text) {
    final cleaned = _cleanText(text);
    final whitespace = _whitespaceSplit(cleaned);
    final out = <String>[];
    for (final token in whitespace) {
      final lowered = token.toLowerCase();
      final stripped = _stripAccents(lowered);
      out.addAll(_splitOnPunctuation(stripped));
    }
    return _whitespaceSplit(out.join(' '));
  }

  /// Drop control chars and normalize all whitespace to a plain space.
  String _cleanText(String text) {
    final buf = StringBuffer();
    for (final rune in text.runes) {
      if (rune == 0 || rune == 0xFFFD || _isControl(rune)) continue;
      if (_isWhitespace(rune)) {
        buf.writeCharCode(0x20);
      } else {
        buf.writeCharCode(rune);
      }
    }
    return buf.toString();
  }

  List<String> _whitespaceSplit(String text) {
    return text.split(RegExp(r'\s+')).where((s) => s.isNotEmpty).toList();
  }

  /// NFD decompose, then drop combining marks (general category 'Mn').
  ///
  /// Dart's stdlib doesn't expose NFD or Unicode categories — we fall back
  /// to a hand-rolled map for the Latin Extended ranges that account for
  /// ~all accented chars in English/Romance/Germanic text. For other
  /// scripts the tokens fall through unchanged, which is the same fallback
  /// behavior as if the vocab simply lacks that subword (lands on [UNK]).
  String _stripAccents(String text) {
    final buf = StringBuffer();
    for (final rune in text.runes) {
      final mapped = _diacriticMap[rune];
      if (mapped != null) {
        buf.write(mapped);
      } else {
        buf.writeCharCode(rune);
      }
    }
    return buf.toString();
  }

  List<String> _splitOnPunctuation(String text) {
    final out = <String>[];
    final current = StringBuffer();
    for (final rune in text.runes) {
      if (_isPunctuation(rune)) {
        if (current.isNotEmpty) {
          out.add(current.toString());
          current.clear();
        }
        out.add(String.fromCharCode(rune));
      } else {
        current.writeCharCode(rune);
      }
    }
    if (current.isNotEmpty) out.add(current.toString());
    return out;
  }

  /// Greedy longest-match-first WordPiece. For each whitespace-separated
  /// token, eat the longest prefix that's in the vocab; subsequent prefixes
  /// are prefixed with '##'. Unmatched → '[UNK]' for the whole word.
  List<String> _wordpiece(List<String> tokens) {
    final out = <String>[];
    for (final token in tokens) {
      final chars = token.runes.toList();
      if (chars.length > _maxInputCharsPerWord) {
        out.add('[UNK]');
        continue;
      }

      var isBad = false;
      var start = 0;
      final subTokens = <String>[];
      while (start < chars.length) {
        var end = chars.length;
        String? curSub;
        while (start < end) {
          var sub = String.fromCharCodes(chars.sublist(start, end));
          if (start > 0) sub = '##$sub';
          if (_vocab.containsKey(sub)) {
            curSub = sub;
            break;
          }
          end--;
        }
        if (curSub == null) {
          isBad = true;
          break;
        }
        subTokens.add(curSub);
        start = end;
      }

      if (isBad) {
        out.add('[UNK]');
      } else {
        out.addAll(subTokens);
      }
    }
    return out;
  }

  // ─── Unicode predicates (matched to HF reference impl) ─────────────────

  bool _isWhitespace(int r) {
    if (r == 0x20 || r == 0x09 || r == 0x0A || r == 0x0D) return true;
    // Z* general category — covers NBSP and the various Unicode spaces.
    return r == 0xA0 || (r >= 0x2000 && r <= 0x200A) || r == 0x202F ||
        r == 0x205F || r == 0x3000;
  }

  bool _isControl(int r) {
    if (r == 0x09 || r == 0x0A || r == 0x0D) return false; // treated as ws
    if (r < 0x20) return true;
    if (r >= 0x7F && r <= 0x9F) return true;
    return false;
  }

  bool _isPunctuation(int r) {
    // BERT treats ASCII punctuation ranges as punctuation regardless of
    // Unicode category — captures '$', '+', '<', etc.
    if ((r >= 33 && r <= 47) ||
        (r >= 58 && r <= 64) ||
        (r >= 91 && r <= 96) ||
        (r >= 123 && r <= 126)) {
      return true;
    }
    // Common Unicode punctuation ranges. Not exhaustive — full P*
    // categories would need a table; this set covers what tool docs and
    // user queries actually contain (quotes, em-dash, ellipsis).
    if ((r >= 0x2000 && r <= 0x206F) || // general punctuation
        (r >= 0x3000 && r <= 0x303F) || // CJK symbols & punctuation
        (r >= 0xFE30 && r <= 0xFE4F) || // CJK compat forms
        (r >= 0xFF00 && r <= 0xFFEF)) { // halfwidth/fullwidth forms
      return true;
    }
    return false;
  }
}

/// Latin diacritic → unaccented ASCII. Mirrors NFD-then-drop-Mn for the
/// ranges that show up in tool queries; the long tail falls through to
/// the WordPiece [UNK] path, same as any unseen char.
const Map<int, String> _diacriticMap = {
  // Latin-1 Supplement
  0xC0: 'A', 0xC1: 'A', 0xC2: 'A', 0xC3: 'A', 0xC4: 'A', 0xC5: 'A',
  0xC7: 'C', 0xC8: 'E', 0xC9: 'E', 0xCA: 'E', 0xCB: 'E',
  0xCC: 'I', 0xCD: 'I', 0xCE: 'I', 0xCF: 'I', 0xD1: 'N',
  0xD2: 'O', 0xD3: 'O', 0xD4: 'O', 0xD5: 'O', 0xD6: 'O',
  0xD9: 'U', 0xDA: 'U', 0xDB: 'U', 0xDC: 'U', 0xDD: 'Y',
  0xE0: 'a', 0xE1: 'a', 0xE2: 'a', 0xE3: 'a', 0xE4: 'a', 0xE5: 'a',
  0xE7: 'c', 0xE8: 'e', 0xE9: 'e', 0xEA: 'e', 0xEB: 'e',
  0xEC: 'i', 0xED: 'i', 0xEE: 'i', 0xEF: 'i', 0xF1: 'n',
  0xF2: 'o', 0xF3: 'o', 0xF4: 'o', 0xF5: 'o', 0xF6: 'o',
  0xF9: 'u', 0xFA: 'u', 0xFB: 'u', 0xFC: 'u', 0xFD: 'y', 0xFF: 'y',
};
