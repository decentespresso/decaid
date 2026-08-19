import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/services/webserver_service.dart';
import 'package:shelf_plus/shelf_plus.dart';

class _FakeConnectionInfo implements HttpConnectionInfo {
  final InternetAddress _remote;

  _FakeConnectionInfo(this._remote);

  @override
  InternetAddress get remoteAddress => _remote;

  @override
  int get remotePort => 0;

  @override
  int get localPort => 0;
}

void main() {
  group('clientIpFromRequest', () {
    test('returns - when no connection info is present', () {
      final request = Request('GET', Uri.parse('http://localhost/'));
      expect(clientIpFromRequest(request), '-');
    });

    test('returns the remote address from connection info', () {
      final request = Request(
        'GET',
        Uri.parse('http://localhost/'),
        context: {
          'shelf.io.connection_info': _FakeConnectionInfo(
            InternetAddress('192.168.1.50'),
          ),
        },
      );
      expect(clientIpFromRequest(request), '192.168.1.50');
    });
  });

  group('logRequestsWithClientIp', () {
    test('logs the client ip and status code', () async {
      final messages = <String>[];
      final handler = logRequestsWithClientIp(
        logger: (msg, isError) => messages.add(msg),
      )((Request request) async {
        return Response.ok('ok');
      });

      final request = Request(
        'GET',
        Uri.parse('http://localhost/api/v1/info'),
        context: {
          'shelf.io.connection_info': _FakeConnectionInfo(
            InternetAddress('10.0.0.7'),
          ),
        },
      );

      final response = await handler(request);

      expect(response.statusCode, 200);
      expect(messages, hasLength(1));
      expect(messages.single, contains('10.0.0.7'));
      expect(messages.single, contains('/api/v1/info'));
      expect(messages.single, contains('[200]'));
    });

    test('logs errors with the client ip', () async {
      final messages = <String>[];
      final handler = logRequestsWithClientIp(
        logger: (msg, isError) => messages.add('$isError:$msg'),
      )((Request request) async {
        throw StateError('boom');
      });

      final request = Request(
        'POST',
        Uri.parse('http://localhost/api/v1/scale/tare'),
        context: {
          'shelf.io.connection_info': _FakeConnectionInfo(
            InternetAddress('10.0.0.9'),
          ),
        },
      );

      await expectLater(handler(request), throwsStateError);

      expect(messages, hasLength(1));
      expect(messages.single, startsWith('true:'));
      expect(messages.single, contains('10.0.0.9'));
      expect(messages.single, contains('/api/v1/scale/tare'));
    });
  });
}
