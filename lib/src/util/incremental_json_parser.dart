import 'dart:convert';

/// A complete JSON value emitted at a requested depth by
/// [IncrementalJsonParser].
class JsonValueEvent {
  /// Container depth of the value: 0 is the whole document, 1 is an element
  /// of the top-level array/object, etc.
  final int depth;

  /// Key path of the value (object keys of ancestor objects, outermost first).
  /// Array ancestors contribute nothing, so `keys.length <= depth`.
  final List<String> keys;

  /// The decoded value.
  final Object? value;

  const JsonValueEvent({
    required this.depth,
    required this.keys,
    required this.value,
  });
}

/// Thrown when a JSON stream is structurally malformed: truncated input,
/// bad escapes, invalid tokens, trailing garbage, oversize values, or
/// excessive nesting.
class JsonStreamFormatException implements Exception {
  final String message;
  const JsonStreamFormatException(this.message);

  @override
  String toString() => 'JsonStreamFormatException: $message';
}

int utf8CodePointByteLength(int codePoint) => codePoint < 0x80
    ? 1
    : codePoint < 0x800
    ? 2
    : codePoint < 0x10000
    ? 3
    : 4;

/// The top-level container kind of a JSON payload.
enum JsonContainerKind { array, object }

/// A real incremental JSON parser.
///
/// Consumes decoded text chunks and yields complete values at a configured
/// [eventDepth]: 0 yields the whole document, 1 yields top-level elements of
/// the document's array/object, 3 yields values nested three containers deep
/// (e.g. the `{"namespaces": {ns: {k: v}}}` KV payload).
///
/// Handles strings with escapes and `\uXXXX` (including surrogate pairs),
/// strict JSON numbers, nesting, and UTF-8 boundaries (chunks come from
/// `Utf8Decoder`, which rejects malformed input). Never splits on commas or
/// braces: a value is emitted only after its full span parses, and malformed
/// input always throws instead of yielding a prefix.
class IncrementalJsonParser {
  final int _maxValueBytes;
  final int _maxKeyBytes;
  final int _maxNestingDepth;
  final int _eventDepth;
  final void Function(
    int depth,
    List<String> keys,
    JsonContainerKind? containerKind,
  )?
  _onValueStart;

  final List<_Frame> _stack = [];
  bool _rootStarted = false;
  bool _documentDone = false;
  JsonContainerKind? _topKind;

  final StringBuffer _token = StringBuffer();
  bool _inString = false;
  bool _inEscape = false;
  bool _inUnicode = false;
  int _unicodeRemaining = 0;
  bool _tokenIsKey = false;
  bool _inScalar = false;
  int _tokenBytes = 0;

  final StringBuffer _span = StringBuffer();
  bool _spanOpen = false;
  int _spanBytes = 0;

  final List<JsonValueEvent> _pendingEvents = [];

  IncrementalJsonParser({
    required int eventDepth,
    int maxValueBytes = 64 * 1024 * 1024,
    int maxKeyBytes = 64 * 1024,
    int maxNestingDepth = 256,
    void Function(
      int depth,
      List<String> keys,
      JsonContainerKind? containerKind,
    )?
    onValueStart,
  }) : _eventDepth = eventDepth,
       _maxValueBytes = maxValueBytes,
       _maxKeyBytes = maxKeyBytes,
       _maxNestingDepth = maxNestingDepth,
       _onValueStart = onValueStart;

  static const _ws = {0x20, 0x09, 0x0A, 0x0D};
  static const _scalarChars = {
    0x30,
    0x31,
    0x32,
    0x33,
    0x34,
    0x35,
    0x36,
    0x37,
    0x38,
    0x39,
    0x2D,
    0x2B,
    0x2E,
    0x65,
    0x45,
    0x74,
    0x72,
    0x75,
    0x66,
    0x61,
    0x6C,
    0x73,
    0x6E,
  };

  /// Feeds a decoded text chunk. Emitted events are collected and returned by
  /// [drain].
  void feed(String chunk) {
    for (final rune in chunk.runes) {
      _feedChar(rune);
    }
  }

  /// Returns events emitted since the last call to [drain].
  List<JsonValueEvent> drain() {
    final events = _pendingEvents.toList(growable: false);
    _pendingEvents.clear();
    return events;
  }

  /// The top-level container kind, valid after the document started.
  JsonContainerKind get topKind {
    final kind = _topKind;
    if (kind == null) {
      throw const JsonStreamFormatException('The JSON payload is empty.');
    }
    return kind;
  }

  /// Must be called after the final chunk. Throws if the stream ended in the
  /// middle of a value or if the payload is empty.
  void finish() {
    if (_inString) {
      throw const JsonStreamFormatException(
        'Unexpected end of input inside a string.',
      );
    }
    if (_inScalar) {
      _completeScalar();
    }
    if (_spanOpen) {
      throw const JsonStreamFormatException(
        'Unexpected end of input inside a value.',
      );
    }
    if (_stack.isNotEmpty) {
      throw const JsonStreamFormatException(
        'Unexpected end of input: unclosed JSON container.',
      );
    }
    if (!_rootStarted) {
      throw const JsonStreamFormatException('The JSON payload is empty.');
    }
  }

  void _feedChar(int c) {
    if (_documentDone) {
      if (!_ws.contains(c)) {
        throw const JsonStreamFormatException(
          'Unexpected trailing content after the top-level JSON value.',
        );
      }
      return;
    }
    if (_inString) {
      _stringChar(c);
      return;
    }
    if (_inScalar) {
      _scalarChar(c);
      return;
    }

    if (_ws.contains(c)) {
      if (_spanOpen) _spanWriteCharCode(c);
      return;
    }

    if (_spanOpen) _spanWriteCharCode(c);

    if (_stack.isEmpty) {
      _startValue(c);
      return;
    }

    final frame = _stack.last;
    switch (frame.state) {
      case _FrameState.wantKey:
        if (c == 0x7D) {
          if (frame.sawValue) {
            throw const JsonStreamFormatException(
              'Unexpected trailing comma in object.',
            );
          }
          _closeContainer();
          return;
        }
        if (c == 0x22) {
          _startString(isKey: true);
          return;
        }
        throw _unexpected(c);
      case _FrameState.expectColon:
        if (c == 0x3A) {
          frame.state = _FrameState.wantValue;
          return;
        }
        throw _unexpected(c);
      case _FrameState.wantValue:
        if (c == _closeChar(frame.isObject)) {
          if (frame.isObject) {
            throw const JsonStreamFormatException('Missing value after ":"');
          }
          if (frame.sawValue) {
            throw const JsonStreamFormatException(
              'Unexpected trailing comma in array.',
            );
          }
          _closeContainer();
          return;
        }
        _startValue(c);
        return;
      case _FrameState.expectCommaOrClose:
        if (c == 0x2C) {
          frame.state = frame.isObject
              ? _FrameState.wantKey
              : _FrameState.wantValue;
          return;
        }
        if (c == _closeChar(frame.isObject)) {
          _closeContainer();
          return;
        }
        throw _unexpected(c);
    }
  }

  void _startValue(int c) {
    if (!_rootStarted) {
      _rootStarted = true;
      _topKind = c == 0x7B
          ? JsonContainerKind.object
          : c == 0x5B
          ? JsonContainerKind.array
          : null;
      if (_topKind == null) {
        throw const JsonStreamFormatException(
          'The JSON payload must be an object or array.',
        );
      }
    }

    _onValueStart?.call(
      _stack.length,
      [
        for (final frame in _stack)
          if (frame.isObject && frame.pendingKey != null) frame.pendingKey!,
      ],
      c == 0x7B
          ? JsonContainerKind.object
          : c == 0x5B
          ? JsonContainerKind.array
          : null,
    );

    switch (c) {
      case 0x7B:
        final depth = _stack.length;
        _pushFrame(isObject: true);
        _openSpanIfEvent(c, depth);
        return;
      case 0x5B:
        final depth = _stack.length;
        _pushFrame(isObject: false);
        _openSpanIfEvent(c, depth);
        return;
      case 0x22:
        _startString(isKey: false);
        return;
      default:
        if (_scalarChars.contains(c)) {
          _startScalar(c);
          return;
        }
        throw _unexpected(c);
    }
  }

  void _pushFrame({required bool isObject}) {
    if (_stack.length >= _maxNestingDepth) {
      throw const JsonStreamFormatException('JSON nesting is too deep.');
    }
    _stack.add(
      _Frame(
        isObject: isObject,
        state: isObject ? _FrameState.wantKey : _FrameState.wantValue,
      ),
    );
  }

  void _openSpanIfEvent(int c, int valueDepth) {
    if (!_spanOpen && valueDepth == _eventDepth) {
      _openSpan();
      _spanWriteCharCode(c);
    }
  }

  /// Opens a fresh event span (raw text of the value at [_eventDepth]).
  void _openSpan() {
    _span.clear();
    _spanBytes = 0;
    _spanOpen = true;
  }

  /// Appends one character to the open event span, tracking its UTF-8 byte
  /// length so an oversized container is rejected while it is constructed.
  void _spanWriteCharCode(int c) {
    _span.writeCharCode(c);
    _spanBytes += utf8CodePointByteLength(c);
    if (_spanBytes > _maxValueBytes) {
      throw const JsonStreamFormatException('JSON value is too large.');
    }
  }

  void _startScalar(int c) {
    _token.clear();
    _tokenBytes = 0;
    _tokenIsKey = false;
    _inScalar = true;
    _appendToken(c);
    if (!_spanOpen && _stack.length == _eventDepth) {
      _openSpan();
      _spanWriteCharCode(c);
    }
  }

  void _scalarChar(int c) {
    if (_scalarChars.contains(c)) {
      _appendToken(c);
      if (_spanOpen) _spanWriteCharCode(c);
      return;
    }
    if (_ws.contains(c) || c == 0x2C || c == 0x7D || c == 0x5D) {
      _completeScalar();
      _feedChar(c);
      return;
    }
    throw _unexpected(c);
  }

  void _completeScalar() {
    _inScalar = false;
    final token = _token.toString();
    _token.clear();
    _completeValue(token);
  }

  void _startString({required bool isKey}) {
    _token.clear();
    _tokenBytes = 0;
    _tokenIsKey = isKey;
    _inString = true;
    _inEscape = false;
    _inUnicode = false;
    _appendToken(0x22);
    if (!isKey && !_spanOpen && _stack.length == _eventDepth) {
      _openSpan();
      _spanWriteCharCode(0x22);
    }
  }

  void _stringChar(int c) {
    if (_inEscape) {
      _inEscape = false;
      _appendToken(c);
      if (_spanOpen) _spanWriteCharCode(c);
      if (c == 0x75) {
        _inUnicode = true;
        _unicodeRemaining = 4;
      } else if (!const {
        0x22,
        0x5C,
        0x2F,
        0x62,
        0x66,
        0x6E,
        0x72,
        0x74,
      }.contains(c)) {
        throw const JsonStreamFormatException('Invalid string escape.');
      }
      return;
    }
    if (_inUnicode) {
      _appendToken(c);
      if (_spanOpen) _spanWriteCharCode(c);
      if (!_isHex(c)) {
        throw const JsonStreamFormatException('Invalid \\u escape sequence.');
      }
      _unicodeRemaining--;
      if (_unicodeRemaining == 0) _inUnicode = false;
      return;
    }
    if (c == 0x5C) {
      _inEscape = true;
      _appendToken(c);
      if (_spanOpen) _spanWriteCharCode(c);
      return;
    }
    if (c == 0x22) {
      _appendToken(c);
      if (_spanOpen) _spanWriteCharCode(c);
      _inString = false;
      _completeString();
      return;
    }
    _appendToken(c);
    if (_spanOpen) _spanWriteCharCode(c);
  }

  void _completeString() {
    final token = _token.toString();
    _token.clear();
    _tokenBytes = 0;
    if (_tokenIsKey) {
      final frame = _stack.isEmpty ? null : _stack.last;
      if (frame == null ||
          !frame.isObject ||
          frame.state != _FrameState.wantKey) {
        throw const JsonStreamFormatException('Unexpected string key.');
      }
      frame.pendingKey = _decodeFragment(token) as String;
      frame.state = _FrameState.expectColon;
      return;
    }
    _completeValue(token);
  }

  /// Completes a value whose raw text is [token]. For containers the caller
  /// passes the accumulated span; for strings/scalars the token buffer. Size
  /// limits were already enforced while the text was constructed.
  void _completeValue(String token) {
    final isEvent = _stack.length == _eventDepth;
    if (isEvent) {
      if (!_spanOpen) {
        throw const JsonStreamFormatException('Internal parser error.');
      }
      _spanOpen = false;
      _emitEvent(token);
    } else {
      _decodeFragment(token);
    }

    if (_stack.isNotEmpty) {
      final parent = _stack.last;
      parent.state = _FrameState.expectCommaOrClose;
      parent.pendingKey = null;
      parent.sawValue = true;
    } else {
      _documentDone = true;
    }
  }

  void _emitEvent(String raw) {
    final keys = <String>[
      for (final frame in _stack)
        if (frame.isObject && frame.pendingKey != null) frame.pendingKey!,
    ];
    final value = _decodeFragment(raw);
    _pendingEvents.add(
      JsonValueEvent(depth: _stack.length, keys: keys, value: value),
    );
  }

  Object? _decodeFragment(String raw) {
    try {
      return jsonDecode(raw);
    } on FormatException catch (e) {
      throw JsonStreamFormatException('Malformed JSON value: ${e.message}');
    }
  }

  void _closeContainer() {
    _stack.removeLast();
    final closedDepth = _stack.length;
    if (closedDepth == _eventDepth) {
      if (!_spanOpen) {
        throw const JsonStreamFormatException('Internal parser error.');
      }
      _spanOpen = false;
      _emitEvent(_span.toString());
      _span.clear();
      _completeParentState();
    } else {
      _completeParentState();
    }
  }

  void _completeParentState() {
    if (_stack.isNotEmpty) {
      final parent = _stack.last;
      parent.state = _FrameState.expectCommaOrClose;
      parent.pendingKey = null;
      parent.sawValue = true;
    } else {
      _documentDone = true;
    }
  }

  void _appendToken(int c) {
    _tokenBytes += utf8CodePointByteLength(c);
    if (_tokenIsKey) {
      if (_tokenBytes > _maxKeyBytes) {
        throw const JsonStreamFormatException('JSON key is too large.');
      }
    } else if (_tokenBytes > _maxValueBytes) {
      throw const JsonStreamFormatException('JSON value is too large.');
    }
    _token.writeCharCode(c);
  }

  static int _closeChar(bool isObject) => isObject ? 0x7D : 0x5D;

  static bool _isHex(int c) =>
      (c >= 0x30 && c <= 0x39) ||
      (c >= 0x41 && c <= 0x46) ||
      (c >= 0x61 && c <= 0x66);

  JsonStreamFormatException _unexpected(int c) => JsonStreamFormatException(
    'Unexpected character "${String.fromCharCode(c)}".',
  );
}

enum _FrameState { wantKey, expectColon, wantValue, expectCommaOrClose }

class _Frame {
  final bool isObject;
  _FrameState state;
  String? pendingKey;
  bool sawValue = false;

  _Frame({required this.isObject, required this.state});
}
