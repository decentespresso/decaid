part of '../webserver_service.dart';

class UpdateHandler {
  final UpdateCheckService _service;
  final log = Logger("UpdateHandler");

  UpdateHandler({required UpdateCheckService service}) : _service = service;

  void addRoutes(RouterPlus app) {
    app.get('/api/v1/update', _getUpdate);
    app.get('/ws/v1/update', admittedWebSocketHandler(_handleSocket));
  }

  Response _getUpdate(Request request) {
    return jsonOk(_service.currentState.toJson());
  }

  void _handleSocket(WebSocketChannel socket, String? protocol) {
    log.fine("update websocket connected");

    final sub = _service.updateState.listen((state) {
      try {
        socket.sink.add(jsonEncode(state.toJson()));
      } catch (e, st) {
        log.warning("failed to send update state", e, st);
      }
    });

    socket.stream.listen(
      (message) {
        try {
          final data = jsonDecode(message.toString()) as Map<String, dynamic>;
          handleCommand(data, (obj) => socket.sink.add(jsonEncode(obj)));
        } catch (e) {
          socket.sink.add(jsonEncode({'error': 'Invalid JSON: $e'}));
        }
      },
      onDone: () {
        log.fine("update websocket disconnected");
        sub.cancel();
      },
      onError: (e, st) {
        log.warning("update websocket error", e, st);
        sub.cancel();
      },
    );
  }

  void handleCommand(
    Map<String, dynamic> data,
    void Function(Map<String, dynamic>) reply,
  ) {
    final command = data['command'] as String?;
    if (command == null) {
      reply({'error': 'Missing "command" field'});
      return;
    }

    switch (command) {
      case 'check':
        if (!_service.canCheck) {
          reply({
            'error': 'App update checks are not supported on this platform',
            'url': _service.currentState.releaseUrl,
          });
          return;
        }
        _service.requestCheck();

      case 'install':
        if (!_service.canInstall) {
          reply({
            'error': 'In-app install is not supported on this platform',
            'url': _service.currentState.releaseUrl,
          });
          return;
        }
        _service.downloadAndInstall();

      default:
        reply({'error': 'Unknown command: $command'});
    }
  }
}
