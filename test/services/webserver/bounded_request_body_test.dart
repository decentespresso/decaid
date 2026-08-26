import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/services/webserver/bounded_request_body.dart';
import 'package:shelf/shelf.dart';

void main() {
  group('readBoundedRequestBody', () {
    test('rejects a declared oversized body before reading', () async {
      final request = Request(
        'POST',
        Uri.parse('http://localhost/test'),
        headers: {'content-length': '5'},
        body: 'small',
      );

      await expectLater(
        readBoundedRequestBody(request, maxBytes: 4),
        throwsA(
          isA<RequestBodyReadException>().having(
            (error) => error.statusCode,
            'statusCode',
            413,
          ),
        ),
      );
    });

    test('rejects a chunked body after it exceeds the limit', () async {
      final request = Request(
        'POST',
        Uri.parse('http://localhost/test'),
        body: Stream<List<int>>.fromIterable([
          [1, 2],
          [3, 4],
        ]),
      );

      await expectLater(
        readBoundedRequestBody(request, maxBytes: 3),
        throwsA(
          isA<RequestBodyReadException>().having(
            (error) => error.statusCode,
            'statusCode',
            413,
          ),
        ),
      );
    });

    test('rejects a body that misses its deadline without sleeping', () async {
      final request = Request(
        'POST',
        Uri.parse('http://localhost/test'),
        body: StreamController<List<int>>().stream,
      );

      await expectLater(
        readBoundedRequestBody(request, maxBytes: 4, timeout: Duration.zero),
        throwsA(
          isA<RequestBodyReadException>().having(
            (error) => error.statusCode,
            'statusCode',
            408,
          ),
        ),
      );
    });

    test('decodes an accepted UTF-8 body', () async {
      final request = Request(
        'POST',
        Uri.parse('http://localhost/test'),
        body: Stream<List<int>>.fromIterable([
          [0x66, 0x6f],
          [0x6f],
        ]),
      );

      expect(await readBoundedRequestBodyString(request, maxBytes: 3), 'foo');
    });
  });

  group('requestBodyReadMiddleware', () {
    test('maps an oversized control body to 413', () async {
      final handler = requestBodyReadMiddleware()((request) async {
        await readBoundedRequestBodyString(
          request,
          maxBytes: smallRequestBodyBytes,
          timeout: smallRequestBodyTimeout,
        );
        return Response.ok('accepted');
      });

      final response = await handler(
        Request(
          'POST',
          Uri.parse('http://localhost/test'),
          body: 'x' * (smallRequestBodyBytes + 1),
        ),
      );

      expect(response.statusCode, 413);
    });

    test('accepts a profile-sized body under the record limit', () async {
      final handler = requestBodyReadMiddleware()((request) async {
        await readBoundedRequestBodyString(
          request,
          maxBytes: recordRequestBodyBytes,
          timeout: recordRequestBodyTimeout,
        );
        return Response.ok('accepted');
      });

      final response = await handler(
        Request(
          'POST',
          Uri.parse('http://localhost/test'),
          body: 'x' * (smallRequestBodyBytes + 1),
        ),
      );

      expect(response.statusCode, 200);
    });

    test('maps a missed body deadline to 408 without sleeping', () async {
      final handler = requestBodyReadMiddleware()((request) async {
        await readBoundedRequestBody(
          request,
          maxBytes: smallRequestBodyBytes,
          timeout: Duration.zero,
        );
        return Response.ok('accepted');
      });

      final response = await handler(
        Request(
          'POST',
          Uri.parse('http://localhost/test'),
          body: StreamController<List<int>>().stream,
        ),
      );

      expect(response.statusCode, 408);
    });
  });
}
