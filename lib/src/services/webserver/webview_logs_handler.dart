part of '../webserver_service.dart';

class WebViewLogsHandler {
  final WebViewLogService _webViewLogService;

  WebViewLogsHandler({required WebViewLogService webViewLogService})
    : _webViewLogService = webViewLogService;

  void addRoutes(RouterPlus app) {
    app.get('/api/v1/webview/logs', _handleGetLogs);
    app.get('/ws/v1/webview/logs', _handleWebSocketLogs);
  }

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

  Future<Response> _handleWebSocketLogs(Request req) async {
    return admittedWebSocketHandler((
      WebSocketChannel socket,
      String? protocol,
    ) {
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
