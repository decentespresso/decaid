part of '../webserver_service.dart';

/// The scale that weighs the dose. Its own routes, beside the brewing scale's
/// rather than sharing them: every skin already sends `PUT /api/v1/scale/tare`
/// and none of them should have to learn a parameter for a scale they do not
/// use.
class DosingScaleHandler {
  final DosingScaleController _controller;

  final Logger _log = Logger("Dosing scale handler");

  DosingScaleHandler({required DosingScaleController controller})
    : _controller = controller;

  void addRoutes(RouterPlus app) {
    app.put('/api/v1/scale/dosing/<command>', (request, command) async {
      switch (command) {
        case 'tare':
          _log.fine("handling dosing tare command");
          try {
            await _controller.tare();
          } catch (e) {
            _log.warning('dosing tare command failed', e);
            return jsonError({
              'error': e.toString(),
              if (e is ScaleOperationException) 'code': e.code,
            });
          }
          return jsonOk(null);
        default:
          return jsonNotFound({'error': 'Unknown command: $command'});
      }
    });
    app.get(
      '/ws/v1/scale/dosing/snapshot',
      admittedWebSocketHandler(_handleSnapshot),
    );
  }

  Future<void> _handleSnapshot(
    WebSocketChannel socket,
    String? protocol,
  ) async {
    _log.fine("handling dosing websocket connection");

    StreamSubscription<ScaleSnapshot>? snapshotSub;

    void sendStatus(String status) {
      try {
        socket.sink.add(jsonEncode({'status': status}));
      } catch (_) {}
    }

    void attachSnapshots() {
      snapshotSub?.cancel();
      snapshotSub = null;
      try {
        _controller.connectedScale();
      } catch (e) {
        _log.warning('connected state reported but no dosing scale: $e');
        return;
      }
      snapshotSub = _controller.snapshot.listen((snapshot) {
        try {
          socket.sink.add(jsonEncode(snapshot.toJson()));
        } catch (e, st) {
          _log.severe("failed to send: ", e, st);
        }
      });
    }

    final connSub = _controller.connectionState.listen((state) {
      if (state == ConnectionState.connected) {
        sendStatus('connected');
        attachSnapshots();
      } else {
        snapshotSub?.cancel();
        snapshotSub = null;
        sendStatus('disconnected');
      }
    });

    socket.stream.listen(
      (e) {},
      onDone: () {
        connSub.cancel();
        snapshotSub?.cancel();
      },
      onError: (e) {
        connSub.cancel();
        snapshotSub?.cancel();
      },
    );
  }
}
