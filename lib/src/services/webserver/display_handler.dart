part of '../webserver_service.dart';

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

  Future<Response> _getState(Request request) async {
    try {
      return jsonOk(_displayController.currentState.toJson());
    } catch (e, st) {
      log.severe('Error in getState handler', e, st);
      return jsonError({'error': e.toString()});
    }
  }

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

  Future<Response> _requestWakeLock(Request request) async {
    try {
      await _displayController.requestWakeLock();
      return jsonOk(_displayController.currentState.toJson());
    } catch (e, st) {
      log.severe('Error in requestWakeLock handler', e, st);
      return jsonError({'error': e.toString()});
    }
  }

  Future<Response> _releaseWakeLock(Request request) async {
    try {
      await _displayController.releaseWakeLock();
      return jsonOk(_displayController.currentState.toJson());
    } catch (e, st) {
      log.severe('Error in releaseWakeLock handler', e, st);
      return jsonError({'error': e.toString()});
    }
  }

  Future<Response> _handleWebSocket(Request req) async {
    return admittedWebSocketHandler((
      WebSocketChannel socket,
      String? protocol,
    ) {
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
