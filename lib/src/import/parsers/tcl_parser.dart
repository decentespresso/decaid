/// A parser for TCL-like formats used by de1app:
/// - `.shot` files (shot history)
/// - `.tdb` files (grinder database)
///
/// Produces a `Map<String, dynamic>` where values are:
///   - `String` — simple or single-token braced values
///   - `List<String>` — braced values where all tokens are numbers
///   - `Map<String, dynamic>` — multi-line braced blocks or single-line
///     braced blocks that contain key-value pairs
class TclParser {
  /// Parse [input] and return the resulting map.
  static Map<String, dynamic> parse(String input) {
    final lines = input.split('\n');
    final _Parser parser = _Parser(lines);
    return parser.parseBlock(endMarker: null);
  }
}

class _Parser {
  final List<String> _lines;
  int _pos = 0;

  _Parser(this._lines);

  /// Parse lines until [endMarker] is found (or end of input).
  /// [endMarker] is the exact trimmed line that signals end (e.g., `}`).
  Map<String, dynamic> parseBlock({required String? endMarker}) {
    final result = <String, dynamic>{};

    while (_pos < _lines.length) {
      final raw = _lines[_pos];
      final trimmed = raw.trim();

      if (endMarker != null && trimmed == endMarker) {
        _pos++;
        break;
      }

      _pos++;

      if (trimmed.isEmpty) continue;

      final keyEnd = _findKeyEnd(trimmed);
      if (keyEnd < 0) continue;

      final rawKey = trimmed.substring(0, keyEnd);
      final key = _unescapeKey(rawKey);
      final rest = trimmed.substring(keyEnd + 1).trim();

      if (rest == '{') {
        final nested = parseBlock(endMarker: '}');
        result[key] = nested;
      } else if (rest.startsWith('{') && rest.endsWith('}')) {
        final inner = rest.substring(1, rest.length - 1);
        result[key] = _parseBracedValue(inner);
      } else {
        result[key] = rest;
      }
    }

    return result;
  }

  /// Find the index of the first unescaped space in [s].
  int _findKeyEnd(String s) {
    for (int i = 0; i < s.length; i++) {
      if (s[i] == ' ' && (i == 0 || s[i - 1] != r'\')) {
        return i;
      }
    }
    return -1;
  }

  /// Replace `\ ` (backslash-space) sequences with a plain space.
  String _unescapeKey(String key) => key.replaceAll(r'\ ', ' ');

  /// Parse the content inside `{ ... }` on a single line.
  ///
  /// Returns:
  ///   - `''` for empty content
  ///   - `List<String>` if all tokens are numbers (and more than one token)
  ///   - `Map<String, dynamic>` if the content looks like key-value pairs
  ///     (contains nested braces, or even number of plain tokens)
  ///   - `String` otherwise (single token or non-pair multi-word strings)
  dynamic _parseBracedValue(String inner) {
    if (inner.isEmpty) return '';

    final tokens = _tokenise(inner);

    if (tokens.isEmpty) return '';

    if (tokens.length == 1) {
      return tokens[0].value;
    }

    final allPlain = tokens.every((t) => !t.isBraced);
    if (allPlain) {
      final allNumeric = tokens.every((t) => double.tryParse(t.value) != null);
      if (allNumeric) {
        return tokens.map((t) => t.value).toList();
      }
    }

    final hasNestedBraces = tokens.any((t) => t.isBraced);
    final looksLikePairs =
        tokens.length.isEven &&
        (tokens.length >= 4 || hasNestedBraces) &&
        _indicesAre(tokens, isOdd: false, plain: true);

    if (looksLikePairs) {
      return _buildMapFromTokens(tokens);
    }

    return inner;
  }

  /// Build a map from an even-length list of alternating key/value tokens.
  Map<String, dynamic> _buildMapFromTokens(List<_Token> tokens) {
    final map = <String, dynamic>{};
    for (int i = 0; i < tokens.length; i += 2) {
      final key = tokens[i].value;
      final valToken = tokens[i + 1];
      if (valToken.isBraced) {
        map[key] = _parseBracedValue(valToken.value);
      } else {
        map[key] = valToken.value;
      }
    }
    return map;
  }

  /// Whether all tokens at even-indexed positions (0,2,4…) are plain.
  bool _indicesAre(
    List<_Token> tokens, {
    required bool isOdd,
    required bool plain,
  }) {
    for (int i = isOdd ? 1 : 0; i < tokens.length; i += 2) {
      if (plain && tokens[i].isBraced) return false;
    }
    return true;
  }

  /// Tokenise a string respecting nested `{...}` groups.
  /// Returns a list of tokens, each either a plain word or a braced group
  /// (with the braces stripped from the value).
  List<_Token> _tokenise(String s) {
    final tokens = <_Token>[];
    int i = 0;
    final buf = StringBuffer();

    while (i < s.length) {
      final c = s[i];

      if (c == ' ') {
        if (buf.isNotEmpty) {
          tokens.add(_Token(buf.toString(), isBraced: false));
          buf.clear();
        }
        i++;
      } else if (c == '{') {
        final end = _findClosingBrace(s, i);
        if (end < 0) {
          buf.write(s.substring(i));
          i = s.length;
        } else {
          final inner = s.substring(i + 1, end);
          tokens.add(_Token(inner, isBraced: true));
          i = end + 1;
          if (i < s.length && s[i] == ' ') i++;
        }
      } else {
        buf.write(c);
        i++;
      }
    }

    if (buf.isNotEmpty) {
      tokens.add(_Token(buf.toString(), isBraced: false));
    }

    return tokens;
  }

  /// Find the index of the closing `}` that matches the `{` at [openIdx].
  /// Returns -1 if not found.
  int _findClosingBrace(String s, int openIdx) {
    int depth = 0;
    for (int i = openIdx; i < s.length; i++) {
      if (s[i] == '{') depth++;
      if (s[i] == '}') {
        depth--;
        if (depth == 0) return i;
      }
    }
    return -1;
  }
}

class _Token {
  final String value;
  final bool isBraced;
  const _Token(this.value, {required this.isBraced});
}
