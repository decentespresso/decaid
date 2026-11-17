part of '../webserver_service.dart';

class DerekHandler {
  final http.Client _client;
  final Uri _upstream;

  DerekHandler({
    http.Client? client,
    String baseUrl = 'https://derek.decentespresso.com',
  }) : _client = client ?? http.Client(),
       _upstream = Uri.parse('$baseUrl/api/answers/stream');

  void addRoutes(RouterPlus app) {
    app.post('/api/v1/derek/answers/stream', _handle);
  }

  Future<Response> _handle(Request request) async {
    final body = await readBoundedRequestBody(
      request,
      maxBytes: largeRequestBodyBytes,
    );

    final upstreamRequest = http.Request('POST', _upstream)
      ..bodyBytes = body
      ..headers['content-type'] =
          request.headers['content-type'] ?? 'application/json';

    final http.StreamedResponse upstream;
    try {
      upstream = await _client.send(upstreamRequest);
    } catch (e, st) {
      log.warning('Derek connection failed', e, st);
      return jsonError({'error': remoteErrorMessage(e, action: 'reach Derek')});
    }

    return Response(
      upstream.statusCode,
      body: upstream.stream,
      headers: {
        'Content-Type': upstream.headers['content-type'] ?? 'text/event-stream',
        'Cache-Control': 'no-cache',
        'X-Accel-Buffering': 'no',
      },
    );
  }
}
