import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/services/webserver/json_response.dart';
import 'package:shelf/shelf.dart';

Request _get({Map<String, String> headers = const {}}) {
  return Request('GET', Uri.parse('http://localhost/test'), headers: headers);
}

void main() {
  group('jsonOkConditional', () {
    test(
      'returns 200 with strong quoted ETag when If-None-Match is absent',
      () async {
        final response = jsonOkConditional(_get(), {'a': 1, 'b': 'x'});

        expect(response.statusCode, 200);
        expect(response.headers['content-type'], contains('application/json'));
        final etag = response.headers['etag'];
        expect(etag, isNotNull);
        expect(etag, startsWith('"'));
        expect(etag, endsWith('"'));
        expect(etag!.length, 18);
        expect(jsonDecode(await response.readAsString()), {'a': 1, 'b': 'x'});
      },
    );

    test('returns the same ETag for identical bodies', () {
      final r1 = jsonOkConditional(_get(), [1, 2, 3]);
      final r2 = jsonOkConditional(_get(), [1, 2, 3]);
      expect(r1.headers['etag'], equals(r2.headers['etag']));
    });

    test('returns different ETags for different bodies', () {
      final r1 = jsonOkConditional(_get(), [1, 2, 3]);
      final r2 = jsonOkConditional(_get(), [1, 2, 4]);
      expect(r1.headers['etag'], isNot(equals(r2.headers['etag'])));
    });

    test('returns 304 when If-None-Match matches the computed ETag', () async {
      final fresh = jsonOkConditional(_get(), {'k': 'v'});
      final etag = fresh.headers['etag']!;

      final conditional = jsonOkConditional(
        _get(headers: {'If-None-Match': etag}),
        {'k': 'v'},
      );

      expect(conditional.statusCode, 304);
      expect(conditional.headers['etag'], etag);
      expect(await conditional.readAsString(), isEmpty);
    });

    test('returns 200 + new ETag when If-None-Match does not match', () async {
      final r = jsonOkConditional(
        _get(headers: {'If-None-Match': '"deadbeef00000000"'}),
        {'k': 'v'},
      );

      expect(r.statusCode, 200);
      expect(r.headers['etag'], isNot('"deadbeef00000000"'));
      expect(jsonDecode(await r.readAsString()), {'k': 'v'});
    });

    test('treats If-None-Match: * as a wildcard match → 304', () async {
      final r = jsonOkConditional(_get(headers: {'If-None-Match': '*'}), {
        'whatever': true,
      });

      expect(r.statusCode, 304);
      expect(r.headers['etag'], isNotNull);
      expect(await r.readAsString(), isEmpty);
    });
  });
}
