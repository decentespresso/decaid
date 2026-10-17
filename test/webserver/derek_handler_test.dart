import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart' as http_testing;
import 'package:reaprime/src/services/webserver_service.dart';
import 'package:shelf_plus/shelf_plus.dart';

void main() {
  late http.Request? upstream;

  Handler buildHandler(Future<http.Response> Function(http.Request) respond) {
    final app = Router().plus;
    DerekHandler(
      client: http_testing.MockClient((request) async {
        upstream = request;
        return respond(request);
      }),
    ).addRoutes(app);
    return const Pipeline().addHandler(app.call);
  }

  Future<Response> post(Handler handler, String body) async {
    return handler(
      Request(
        'POST',
        Uri.parse('http://localhost/api/v1/derek/answers/stream'),
        headers: {'content-type': 'application/json'},
        body: body,
      ),
    );
  }

  setUp(() => upstream = null);

  test('connection failure returns a friendly server error', () async {
    final handler = buildHandler(
      (_) async => throw const SocketException('private host lookup'),
    );
    final response = await post(handler, '{"query":"hello"}');
    expect(response.statusCode, 500);
    final body = jsonDecode(await response.readAsString());
    expect(
      body['error'],
      "Couldn't reach Derek. Check your internet connection and try again.",
    );
  });

  test('forwards the POST body to Derek verbatim', () async {
    final handler = buildHandler(
      (_) async => http.Response('event: queue\ndata: {}\n\n', 200),
    );

    await post(handler, '{"query":"hello"}');

    expect(upstream, isNotNull);
    expect(upstream!.method, 'POST');
    expect(upstream!.body, '{"query":"hello"}');
    expect(upstream!.headers['content-type'], 'application/json');
    expect(
      upstream!.url.toString(),
      'https://derek.decentespresso.com/api/answers/stream',
    );
  });

  test('relays the SSE body and marks the response unbuffered', () async {
    const sse =
        'event: phase\ndata: {"phase":"answering"}\n\n'
        'event: result\ndata: {"mode":"answer","answer_text":"Hi. [1]"}\n\n';
    final handler = buildHandler(
      (_) async => http.Response(
        sse,
        200,
        headers: {'content-type': 'text/event-stream'},
      ),
    );

    final response = await post(handler, '{"query":"hi"}');

    expect(response.statusCode, 200);
    expect(response.headers['content-type'], 'text/event-stream');
    expect(response.headers['cache-control'], 'no-cache');
    expect(response.headers['x-accel-buffering'], 'no');
    expect(await response.readAsString(), sse);
  });

  test('relays upstream error status and body verbatim', () async {
    final handler = buildHandler(
      (_) async => http.Response(
        '{"detail":{"code":"query_empty","message":"query must not be empty"}}',
        400,
        headers: {'content-type': 'application/json'},
      ),
    );

    final response = await post(handler, '{"query":""}');

    expect(response.statusCode, 400);
    final body = jsonDecode(await response.readAsString());
    expect(body['detail']['code'], 'query_empty');
  });

  test(
    'defaults content-type to text/event-stream when upstream omits it',
    () async {
      final handler = buildHandler(
        (_) async => http.Response('event: queue\ndata: {}\n\n', 200),
      );

      final response = await post(handler, '{"query":"hi"}');

      expect(response.headers['content-type'], 'text/event-stream');
    },
  );
}
