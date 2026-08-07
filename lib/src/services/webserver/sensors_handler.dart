part of '../webserver_service.dart';

final class SensorsHandler {
  final SensorController _controller;
  final Logger _log = Logger("Sensor handler");

  SensorsHandler({required SensorController controller})
    : _controller = controller;

  void addRoutes(RouterPlus app) {
    app.get('/api/v1/sensors', (Request req) {
      final list = _controller.sensors.values.map((s) {
        final info = s.info;
        return {'id': s.deviceId, 'info': info.toJson()};
      }).toList();
      return jsonOk(list);
    });

    app.get('/api/v1/sensors/<id>', (Request req, String id) async {
      final sensor = _controller.sensors[id];
      if (sensor == null) {
        return jsonNotFound({'error': 'Sensor not found: $id'});
      }
      return jsonOk(sensor.info.toJson());
    });

    app.get('/ws/v1/sensors/<id>/snapshot', _handleSensorSnapshot);

    app.post('/api/v1/sensors/<id>/execute', (Request req, String id) async {
      final sensor = _controller.sensors[id];
      if (sensor == null) {
        return jsonNotFound({'error': 'Sensor not found: $id'});
      }

      final body = await req.readAsString();
      final jsonBody = jsonDecode(body);
      final cmdId = jsonBody['commandId'] as String;
      final params = jsonBody['params'] as Map<String, dynamic>?;
      try {
        final res = await sensor.execute(cmdId, params);
        return jsonOk({'status': 'ok', 'result': res});
      } catch (e) {
        return jsonError({'status': 'error', 'message': e.toString()});
      }
    });
  }

  FutureOr<Response> _handleSensorSnapshot(Request req) {
    _log.info("Handling: $req");
    final id = req.params['id'];
    _log.info("got id: $id");
    return sws.webSocketHandler((socket, protocol) {
      _log.info("upgraded to socket");
      final sensor = _controller.sensors[id];
      if (sensor == null) {
        socket.sink.add(jsonEncode({'error': 'not found'}));
        socket.sink.close();
        return;
      }

      final sub = sensor.data.listen((snapshot) {
        _log.finest("received snapshot: $snapshot");
        socket.sink.add(jsonEncode(snapshot));
      }, onError: (e, st) => log.severe('send error', e, st));

      socket.stream.listen(
        (msg) {},
        onDone: sub.cancel,
        onError: (_, _) => sub.cancel(),
      );
    })(req);
  }
}
