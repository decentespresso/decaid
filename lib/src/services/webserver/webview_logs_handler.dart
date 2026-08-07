part of '../webserver_service.dart';

/// REST and WebSocket handler for WebView console logs.
///
/// Provides access to the dedicated webview_console.log file via REST
/// and live streaming via WebSocket. Fully isolated from the existing
/// /api/v1/logs and ws/v1/logs endpoints which serve app logs.
class WebViewLogsHandler {
  final WebViewLogService _webViewLogService;

  WebViewLogsHandler({required WebViewLogService webViewLogService})
    : _webViewLogService = webViewLogService;

  void addRoutes(RouterPlus app) {
    app.get('/api/v1/webview/logs', _handleGetLogs);
    // WebSocket: live stream
    app.get('/ws/v1/webview/logs', _handleWebSocketLogs);
  }

  /// GET /api/v1/webview/logs
  /// Returns the current webview_console.log contents as plain text,
  /// newest entries first by default. Pass `order=asc` for the original
  /// chronological order (`order=desc` is the explicit default).
  /// Mirrors the existing LogsHandler pattern for app logs.
  Future<Response> _handleGetLogs(Request request) async {
    final order = _parseLogOrder(request);
    if (order == null) {
      return Response.badRequest(body: "order must be 'asc' or 'desc'");
    }
    final contents = _webViewLogService.getContents();
    return Response.ok(
      _orderLogLines(contents, order),
      headers: {'content-type': 'text/plain'},
    );
  }

  /// ws/v1/webview/logs
  /// Streams live WebView console entries to connected WebSocket clients.
  /// Each message is the raw formatted log line.
  /// Mirrors the existing ws/v1/logs pattern from SettingsHandler.
  Future<Response> _handleWebSocketLogs(Request req) async {
    return sws.webSocketHandler((WebSocketChannel socket, String? protocol) {
      StreamSubscription? sub;
      sub = _webViewLogService.stream.listen((entry) {
        socket.sink.add(entry);
      });
      socket.stream.listen(
        (msg) {},
        onDone: () {
          sub?.cancel();
        },
        onError: (e, _) {
          sub?.cancel();
        },
      );
    })(req);
  }
}
