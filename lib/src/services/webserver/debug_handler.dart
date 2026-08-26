import 'dart:convert';

import 'package:logging/logging.dart';
import 'package:reaprime/src/controllers/de1_controller.dart';
import 'package:reaprime/src/controllers/scale_controller.dart';
import 'package:reaprime/src/models/device/impl/mock_de1/mock_de1.dart';
import 'package:reaprime/src/models/device/impl/mock_scale/mock_scale.dart';
import 'package:reaprime/src/models/device/impl/replay/mock_replay_de1.dart';
import 'package:reaprime/src/services/update_check_service.dart';
import 'package:reaprime/src/services/webserver/bounded_request_body.dart';
import 'package:reaprime/src/services/webserver/json_response.dart';
import 'package:shelf_plus/shelf_plus.dart';

class DebugHandler {
  final ScaleController _scaleController;
  final De1Controller _de1Controller;
  final UpdateCheckService? _updateCheckService;
  final Logger _log = Logger('DebugHandler');

  DebugHandler({
    required ScaleController scaleController,
    required De1Controller de1Controller,
    UpdateCheckService? updateCheckService,
  }) : _scaleController = scaleController,
       _de1Controller = de1Controller,
       _updateCheckService = updateCheckService;

  Map<String, int> get _flowSmoothing => {
    'windowMs': _scaleController.flowSmoothingWindowMs,
    'movingAverageSamples': _scaleController.flowSmoothingSamples,
  };

  void addRoutes(RouterPlus app) {
    app.post('/api/v1/debug/update/force', (request) {
      final svc = _updateCheckService;
      if (svc == null) {
        return jsonBadRequest({'error': 'UpdateCheckService unavailable'});
      }
      final version = request.url.queryParameters['version'] ?? '99.0.0';
      final downloadUrl = request.url.queryParameters['downloadUrl'];
      svc.debugForceUpdate(version: version, downloadUrl: downloadUrl);
      _log.info('Forced update available: $version');
      return jsonOk(svc.currentState.toJson());
    });

    app.get('/api/v1/debug/flow-smoothing', (request) {
      return jsonOk(_flowSmoothing);
    });

    app.post('/api/v1/debug/flow-smoothing', (request) async {
      try {
        final body = jsonDecode(
          await readBoundedRequestBodyString(
            request,
            maxBytes: smallRequestBodyBytes,
            timeout: smallRequestBodyTimeout,
          ),
        );
        if (body is! Map<String, dynamic> ||
            body['windowMs'] is! int ||
            body['movingAverageSamples'] is! int) {
          return jsonBadRequest({
            'error': 'Expected integer windowMs and movingAverageSamples',
          });
        }
        _scaleController.setFlowSmoothing(
          windowMs: body['windowMs'],
          movingAverageSamples: body['movingAverageSamples'],
        );
        return jsonOk(_flowSmoothing);
      } on FormatException {
        return jsonBadRequest({'error': 'Invalid JSON'});
      } on RangeError catch (e) {
        return jsonBadRequest({'error': e.message});
      }
    });

    app.post('/api/v1/debug/scale/<command>', (request, command) async {
      final MockScale mock;
      try {
        final scale = _scaleController.connectedScale();
        if (scale is! MockScale) {
          return jsonBadRequest({
            'error': 'Connected scale is not a MockScale',
          });
        }
        mock = scale;
      } catch (e) {
        return jsonBadRequest({'error': 'No scale connected'});
      }

      switch (command) {
        case 'stall':
          _log.info('Simulating data stall on MockScale');
          mock.simulateDataStall();
          return jsonOk({'status': 'stalled'});
        case 'resume':
          _log.info('Resuming MockScale data emission');
          mock.simulateResume();
          return jsonOk({'status': 'resumed'});
        case 'disconnect':
          _log.info('Simulating MockScale disconnect');
          mock.simulateDisconnect();
          return jsonOk({'status': 'disconnected'});
        default:
          return jsonNotFound({'error': 'Unknown command: $command'});
      }
    });

    app.post('/api/v1/debug/machine/<command>', (request, command) async {
      if (command != 'disconnect') {
        return jsonNotFound({'error': 'Unknown command: $command'});
      }
      final de1 = _de1Controller.connectedDe1OrNull;
      if (de1 is! MockDe1) {
        return jsonBadRequest({'error': 'Connected machine is not a MockDe1'});
      }
      _log.info('Simulating MockDe1 disconnect');
      de1.simulateDisconnect();
      return jsonOk({'status': 'disconnected'});
    });

    // Selection override is session-only; the machine-state API starts/stops.
    app.get('/api/v1/debug/replay/shots', (request) {
      final replay = _de1Controller.connectedDe1OrNull;
      if (replay is! MockReplayDe1) {
        return jsonBadRequest({
          'error': 'Connected machine is not a replay simulator',
        });
      }
      return jsonOk({
        'selected': replay.selectedShotId,
        'shots': [
          for (final shot in replay.availableShots)
            {'id': shot.id, 'profileTitle': shot.profileTitle},
        ],
      });
    });

    app.post('/api/v1/debug/replay/shot/<id>', (request, String id) {
      final replay = _de1Controller.connectedDe1OrNull;
      if (replay is! MockReplayDe1) {
        return jsonBadRequest({
          'error': 'Connected machine is not a replay simulator',
        });
      }
      if (!replay.selectShot(id)) {
        return jsonNotFound({'error': 'Unknown recording id: $id'});
      }
      _log.info('Replay recording forced: $id');
      return jsonOk({'selected': id});
    });

    app.delete('/api/v1/debug/replay/shot', (request) {
      final replay = _de1Controller.connectedDe1OrNull;
      if (replay is! MockReplayDe1) {
        return jsonBadRequest({
          'error': 'Connected machine is not a replay simulator',
        });
      }
      replay.clearSelectedShot();
      _log.info('Replay recording override cleared');
      return jsonOk({'selected': null});
    });
  }
}
