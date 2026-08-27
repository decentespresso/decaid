part of '../webserver_service.dart';

class AccountProxyHandler {
  final DecentProxyService _proxy;
  final bool enableWrites;

  AccountProxyHandler({
    required DecentProxyService proxy,
    this.enableWrites = false,
  }) : _proxy = proxy;

  void addRoutes(RouterPlus app) {
    app.get('/api/v1/account/proxy/<rest|.*>', _handleGet);
    if (enableWrites) {
      app.post('/api/v1/account/proxy/<rest|.*>', _handlePost);
      app.put('/api/v1/account/proxy/<rest|.*>', _handlePut);
    }
  }

  Future<Response> _handleGet(Request request) async {
    final rest = request.params['rest'] ?? '';
    final callerId = proxyCallerOf(request)?.id ?? 'unknown';

    try {
      final result = await _proxy.proxyGet(
        callerId: callerId,
        path: rest,
        rawQuery: request.requestedUri.query,
      );
      return Response(
        result.statusCode,
        body: result.bodyBytes,
        headers: result.headers,
      );
    } on DecentAccountNotLinkedException {
      return jsonUnauthorized({'error': 'Decent account not linked'});
    } on DecentProxyForbiddenPathException {
      return jsonForbidden({'error': 'Path not allowed'});
    } on DecentProxyConsentDeniedException {
      return jsonForbidden({'error': 'Account access was not granted'});
    }
  }

  Future<Response> _handlePost(Request request) {
    return _handleWrite(request, method: 'POST');
  }

  Future<Response> _handlePut(Request request) {
    return _handleWrite(request, method: 'PUT');
  }

  Future<Response> _handleWrite(
    Request request, {
    required String method,
  }) async {
    final rest = request.params['rest'] ?? '';
    final callerId = proxyCallerOf(request)?.id ?? 'unknown';
    final bodyBytes = await readBoundedRequestBody(
      request,
      maxBytes: largeRequestBodyBytes,
      timeout: largeRequestBodyTimeout,
    );
    final contentType = request.headers['content-type'];

    try {
      final result = await _proxy.proxy(
        callerId: callerId,
        method: method,
        path: rest,
        rawQuery: request.requestedUri.query,
        bodyBytes: bodyBytes,
        contentType: contentType,
      );
      return Response(
        result.statusCode,
        body: result.bodyBytes,
        headers: result.headers,
      );
    } on DecentAccountNotLinkedException {
      return jsonUnauthorized({'error': 'Decent account not linked'});
    } on DecentProxyForbiddenPathException {
      return jsonForbidden({'error': 'Path not allowed'});
    } on DecentProxyConsentDeniedException {
      return jsonForbidden({'error': 'Account access was not granted'});
    }
  }
}
