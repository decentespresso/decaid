part of '../webserver_service.dart';

/// REST and WebSocket handler for screen display management.
class DisplayHandler {
  final DisplayController _displayController;
  final log = Logger('DisplayHandler');

  DisplayHandler({required DisplayController displayController})
    : _displayController = displayController;

  void addRoutes(RouterPlus app) {
    app.get('/api/v1/display', _getState);
    app.put('/api/v1/display/brightness', _setBrightness);
    app.post('/api/v1/display/wakelock', _requestWakeLock);
    app.delete('/api/v1/display/wakelock', _releaseWakeLock);
    app.get('/ws/v1/display', _handleWebSocket);
  }

  /// GET /api/v1/display
  Future<Response> _getState(Request request) async {
    try {
      return jsonOk(_displayController.currentState.toJson());
    } catch (e, st) {
      log.severe('Error in getState handler', e, st);
      return jsonError({'error': e.toString()});
    }
  }

  /// PUT /api/v1/display/brightness
  Future<Response> _setBrightness(Request request) async {
    try {
      final body = await request.readAsString();
      final json = jsonDecode(body) as Map<String, dynamic>;
      final brightness = json['brightness'];
      if (brightness == null ||
          brightness is! int ||
          brightness < 0 ||
          brightness > 100) {
        return Response.badRequest(
          body: jsonEncode({'error': 'brightness must be an integer 0-100'}),
          headers: {'Content-Type': 'application/json'},
        );
      }
      await _displayController.setBrightness(brightness);
      return jsonOk(_displayController.currentState.toJson());
    } catch (e, st) {
      log.severe('Error in setBrightness handler', e, st);
      return jsonError({'error': e.toString()});
    }
  }

  /// POST /api/v1/display/wakelock
  Future<Response> _requestWakeLock(Request request) async {
    try {
      await _displayController.requestWakeLock();
      return jsonOk(_displayController.currentState.toJson());
    } catch (e, st) {
      log.severe('Error in requestWakeLock handler', e, st);
      return jsonError({'error': e.toString()});
    }
  }

  /// DELETE /api/v1/display/wakelock
  Future<Response> _releaseWakeLock(Request request) async {
    try {
      await _displayController.releaseWakeLock();
      return jsonOk(_displayController.currentState.toJson());
    } catch (e, st) {
      log.severe('Error in releaseWakeLock handler', e, st);
      return jsonError({'error': e.toString()});
    }
  }

  /// ws/v1/display
  /// Streams DisplayState changes to connected WebSocket clients.
  /// Auto-releases wake-lock override when the client disconnects.
  ///
  /// Note: wake-lock override is not reference-counted across multiple
  /// WebSocket clients. If multiple clients request an override, the first
  /// disconnect will release it for all. This is acceptable for the typical
  /// use case of one skin = one active WebSocket connection.
  Future<Response> _handleWebSocket(Request req) async {
    return sws.webSocketHandler((WebSocketChannel socket, String? protocol) {
      bool overrideRequested = false;
      StreamSubscription? sub;

      sub = _displayController.state.listen((state) {
        try {
          socket.sink.add(jsonEncode(state.toJson()));
        } catch (e, st) {
          log.severe('Failed to send display state', e, st);
        }
      });

      socket.stream.listen(
        (msg) {
          try {
            final data = jsonDecode(msg as String) as Map<String, dynamic>;
            final command = data['command'] as String?;
            switch (command) {
              case 'setBrightness':
                final brightness = data['brightness'];
                if (brightness is int && brightness >= 0 && brightness <= 100) {
                  _displayController.setBrightness(brightness);
                } else {
                  log.warning('Invalid setBrightness value: $brightness');
                }
                break;
              case 'requestWakeLock':
                overrideRequested = true;
                _displayController.requestWakeLock();
                break;
              case 'releaseWakeLock':
                overrideRequested = false;
                _displayController.releaseWakeLock();
                break;
            }
          } catch (e) {
            log.warning('Invalid WebSocket message: $e');
          }
        },
        onDone: () {
          sub?.cancel();
          // Auto-release wake-lock override when client disconnects
          if (overrideRequested) {
            log.info(
              'WebSocket client disconnected, releasing wake-lock override',
            );
            _displayController.releaseWakeLock();
          }
        },
        onError: (e, _) {
          sub?.cancel();
          if (overrideRequested) {
            _displayController.releaseWakeLock();
          }
        },
      );
    })(req);
  }
}
