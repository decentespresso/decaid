import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/util/incremental_json_parser.dart';

List<JsonValueEvent> parse(String doc, int depth, {int chunkSize = 5}) {
  final parser = IncrementalJsonParser(eventDepth: depth);
  for (var i = 0; i < doc.length; i += chunkSize) {
    final end = (i + chunkSize).clamp(0, doc.length);
    parser.feed(doc.substring(i, end));
  }
  parser.finish();
  return parser.drain();
}

void main() {
  group('IncrementalJsonParser', () {
    test('yields top-level array elements at depth 1', () {
      final events = parse('[1, 2.5, -3e2, true, false, null, "hi"]', 1);
      expect(events, hasLength(7));
      expect(events[0].value, 1);
      expect(events[1].value, 2.5);
      expect(events[2].value, -300.0);
      expect(events[3].value, true);
      expect(events[5].value, isNull);
      expect(events[6].value, 'hi');
      expect(events.every((e) => e.depth == 1), isTrue);
    });

    test('yields whole document at depth 0', () {
      final events = parse('{"a": [1,2], "b": "x"}', 0);
      expect(events, hasLength(1));
      expect((events[0].value as Map)['a'], isA<List>());
      expect((events[0].value as Map)['b'], 'x');
    });

    test('yields nested object values with key paths at depth 3', () {
      final events = parse(
        '{"namespaces": {"ns1": {"k1": 1, "k2": {"x": 1}}, "ns2": {}}}',
        3,
      );
      expect(events, hasLength(2));
      expect(events[0].keys, ['namespaces', 'ns1', 'k1']);
      expect(events[0].value, 1);
      expect(events[1].keys, ['namespaces', 'ns1', 'k2']);
      expect((events[1].value as Map)['x'], 1);
    });

    test('handles strings, escapes, and unicode', () {
      final events = parse(r'["a\"b", "\u0041\u00e9", "\\"]', 1);
      expect(events[0].value, 'a"b');
      expect(events[1].value, 'Aé');
      expect(events[2].value, r'\');
    });

    test('handles chunk boundaries inside tokens and utf-8 chars', () {
      final events = parse('[1234567890123456789, "héllo"]', 1, chunkSize: 2);
      expect(events[0].value, 1234567890123456789);
      expect(events[1].value, 'héllo');
    });

    test('handles empty containers and nested arrays', () {
      final events = parse('[[], {}, [1]]', 1);
      expect((events[0].value as List), isEmpty);
      expect((events[1].value as Map), isEmpty);
      expect(events[2].value, isA<List>());
      expect((events[2].value as List)[0], 1);
    });

    test('yields object values at depth 1 with keys', () {
      final events = parse('{"a": 1, "b": 2}', 1);
      expect(events, hasLength(2));
      expect(events[0].keys, ['a']);
      expect(events[1].keys, ['b']);
    });

    test('topKind reports the container kind', () {
      final parser = IncrementalJsonParser(eventDepth: 1);
      parser.feed('  [');
      expect(parser.topKind, JsonContainerKind.array);
    });

    test('rejects truncated input', () {
      expect(
        () => parse('[1, 2', 1),
        throwsA(isA<JsonStreamFormatException>()),
      );
      expect(
        () => parse('["abc', 1),
        throwsA(isA<JsonStreamFormatException>()),
      );
    });

    test('rejects trailing garbage', () {
      expect(
        () => parse('[1] x', 1),
        throwsA(isA<JsonStreamFormatException>()),
      );
      expect(
        () => parse('42 43', 0),
        throwsA(isA<JsonStreamFormatException>()),
      );
    });

    test('rejects trailing commas and missing values', () {
      expect(() => parse('[1,]', 1), throwsA(isA<JsonStreamFormatException>()));
      expect(
        () => parse('{"a":1,}', 1),
        throwsA(isA<JsonStreamFormatException>()),
      );
      expect(
        () => parse('{"a":}', 1),
        throwsA(isA<JsonStreamFormatException>()),
      );
    });

    test('rejects malformed tokens', () {
      expect(() => parse('[01]', 1), throwsA(isA<JsonStreamFormatException>()));
      expect(() => parse('[1.]', 1), throwsA(isA<JsonStreamFormatException>()));
      expect(
        () => parse('[NaN]', 1),
        throwsA(isA<JsonStreamFormatException>()),
      );
      expect(
        () => parse('[truthy]', 1),
        throwsA(isA<JsonStreamFormatException>()),
      );
      expect(
        () => parse('[1 2]', 1),
        throwsA(isA<JsonStreamFormatException>()),
      );
      expect(
        () => parse('{"namespaces": tru}', 3),
        throwsA(isA<JsonStreamFormatException>()),
      );
    });

    test('rejects invalid escapes and unicode', () {
      expect(
        () => parse(r'["\q"]', 1),
        throwsA(isA<JsonStreamFormatException>()),
      );
      expect(
        () => parse(r'["\u12g4"]', 1),
        throwsA(isA<JsonStreamFormatException>()),
      );
    });

    test('rejects empty input and scalar roots', () {
      expect(() => parse('   ', 0), throwsA(isA<JsonStreamFormatException>()));
      expect(() => parse('42', 1), throwsA(isA<JsonStreamFormatException>()));
    });

    test('rejects excessive nesting', () {
      final deep = '[' * 300 + ']' * 300;
      expect(() => parse(deep, 1), throwsA(isA<JsonStreamFormatException>()));
    });

    test('enforces max value and key sizes', () {
      final parser = IncrementalJsonParser(
        eventDepth: 1,
        maxValueBytes: 10,
        maxKeyBytes: 5,
      );
      expect(
        () => parser.feed('[12345678901234567890]'),
        throwsA(isA<JsonStreamFormatException>()),
      );
    });

    test('caps container values while they are constructed', () {
      // Many small keys/values whose sum exceeds maxValueBytes: the object
      // span must trip the limit even though no single token does.
      final parser = IncrementalJsonParser(eventDepth: 1, maxValueBytes: 64);
      final doc =
          '[{"a":1,"b":2,"c":3,"d":4,"e":5,"f":6,"g":7,"h":8,"i":9,"j":10,"k":11,"l":12}]';
      expect(() => parser.feed(doc), throwsA(isA<JsonStreamFormatException>()));
    });

    test('caps the whole document at eventDepth 0', () {
      // Depth 0 events (settings/workflow singletons) cover the whole
      // document; many small elements must trip the cap.
      final parser = IncrementalJsonParser(eventDepth: 0, maxValueBytes: 64);
      final doc = '[${List.generate(30, (i) => '$i').join(',')}]';
      expect(() => parser.feed(doc), throwsA(isA<JsonStreamFormatException>()));
    });

    test('measures limits in UTF-8 bytes, not UTF-16 code units', () {
      final ok = IncrementalJsonParser(eventDepth: 1, maxValueBytes: 20);
      final events = <JsonValueEvent>[];
      ok.feed('["${'\u00E9' * 9}"]');
      ok.finish();
      events.addAll(ok.drain());
      expect(events, hasLength(1));

      final tooBig = IncrementalJsonParser(eventDepth: 1, maxValueBytes: 20);
      expect(
        () => tooBig.feed('["${'\u00E9' * 10}"]'),
        throwsA(isA<JsonStreamFormatException>()),
      );
    });

    test('never yields a valid prefix of malformed JSON', () {
      final parser = IncrementalJsonParser(eventDepth: 1);
      final events = <JsonValueEvent>[];
      parser.feed('[1, {"a": ');
      events.addAll(parser.drain());
      expect(events, hasLength(1));
      expect(() => parser.finish(), throwsA(isA<JsonStreamFormatException>()));
      // A consumer that ignores the error must not receive the second,
      // partial element.
      expect(events.map((e) => e.value), [1]);
    });
  });
}
