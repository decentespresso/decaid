part of '../webserver_service.dart';

/// HTTP relay for Derek, the Decent RAG assistant.
///
/// Forwards `POST /api/v1/derek/answers/stream` to Derek's public answer
/// endpoint and pipes the Server-Sent Events response straight back to the
/// caller, unbuffered, so a browser skin can render the answer as it streams.
///
/// Why a relay instead of calling Derek from the browser: Derek's endpoint is
/// auth-less and its server does not answer CORS preflight, so a `POST` with a
/// JSON body (a non-simple request) fails the browser's `OPTIONS` preflight.
/// Routing through Reaprime makes it a same-API call that the existing
/// `corsHeaders` middleware already handles.
///
/// Derek is public knowledge-base data, so this route stays on the API's
/// LAN-trust model — no bearer token — and the request/response are relayed
/// verbatim. Derek owns request validation, rate limiting, and error shapes.
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
    final body = await request.read().fold<List<int>>(
      <int>[],
      (buffer, chunk) => buffer..addAll(chunk),
    );

    final upstreamRequest = http.Request('POST', _upstream)
      ..bodyBytes = body
      ..headers['content-type'] =
          request.headers['content-type'] ?? 'application/json';

    final upstream = await _client.send(upstreamRequest);

    // Pipe the upstream byte stream directly into the response body. Do NOT
    // collect it first — each SSE event must flush as it arrives, or the
    // browser sees nothing until the whole answer is done.
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
