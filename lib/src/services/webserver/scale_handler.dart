part of '../webserver_service.dart';

class ScaleHandler {
  final ScaleController _controller;
  final De1Controller _de1Controller;
  final SettingsController _settingsController;

  final Logger _log = Logger("Scale handler");

  ScaleHandler({
    required ScaleController controller,
    required De1Controller de1Controller,
    required SettingsController settingsController,
  }) : _controller = controller,
       _de1Controller = de1Controller,
       _settingsController = settingsController;

  void addRoutes(RouterPlus app) {
    app.put('/api/v1/scale/<command>', (request, command) async {
      switch (command) {
        case 'tare':
          _log.fine("handling api tare command");
          final shotState = _de1Controller.currentShotState.state;
          final shotActive =
              shotState != ShotState.idle && shotState != ShotState.finished;
          final isFullGateway =
              _settingsController.gatewayMode == GatewayMode.full;
          if (_settingsController.blockTareDuringShot &&
              shotActive &&
              !isFullGateway) {
            _log.warning(
              "Blocking tare request because blockTareDuringShot is enabled and a shot is active ($shotState)",
            );
            return jsonBadRequest({
              'details': 'Tare blocked: a shot is in progress',
              'type': 'block_tare_during_shot',
            });
          }
          try {
            await _controller.tare();
          } catch (e) {
            return jsonError({'error': e.toString()});
          }
          return jsonOk(null);
        default:
          return jsonNotFound({'error': 'Unknown command: $command'});
      }
    });
    app.put('/api/v1/scale/timer/<command>', (request, command) async {
      try {
        final scale = _controller.connectedScale();
        switch (command) {
          case 'start':
            _log.fine("handling api timer start command");
            await scale.startTimer();
            return jsonOk(null);
          case 'stop':
            _log.fine("handling api timer stop command");
            await scale.stopTimer();
            return jsonOk(null);
          case 'reset':
            _log.fine("handling api timer reset command");
            await scale.resetTimer();
            return jsonOk(null);
          default:
            return jsonNotFound({'error': 'Unknown command: $command'});
        }
      } catch (e) {
        return jsonError({'error': e.toString()});
      }
    });
    app.get('/ws/v1/scale/snapshot', admittedWebSocketHandler(_handleSnapshot));
  }

  Future<void> _handleSnapshot(
    WebSocketChannel socket,
    String? protocol,
  ) async {
    _log.fine("handling websocket connection");

    StreamSubscription<WeightSnapshot>? snapshotSub;

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
        _log.warning('connected state reported but no scale: $e');
        return;
      }
      snapshotSub = _controller.weightSnapshot.listen((snapshot) {
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
      onError: (e, st) {
        connSub.cancel();
        snapshotSub?.cancel();
      },
    );
  }
}
