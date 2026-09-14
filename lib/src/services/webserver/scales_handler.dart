part of '../webserver_service.dart';

/// Every connected scale addressed by its own id, whether it is the primary one
/// the shot is weighed on or one a client is holding open beside it.
///
/// The singular `/api/v1/scale/...` and `/ws/v1/scale/snapshot` routes are
/// unchanged and still mean the primary scale: a client that only ever uses one
/// scale never has to learn this. What these add is the ability to say which
/// scale, which is the only thing a second one needs.
///
/// Snapshots here are the reading the device itself produces. The primary
/// scale's own route carries the brewing-enriched form on top of it -- smoothed
/// flow, connection generation -- because that is what a shot is scored on; a
/// scale being used for something else has no use for either.
class ScalesHandler {
  final ScaleController _primary;
  final AuxiliaryScaleRegistry _auxiliary;

  final Logger _log = Logger("Scales handler");

  ScalesHandler({
    required ScaleController primary,
    required AuxiliaryScaleRegistry auxiliary,
  }) : _primary = primary,
       _auxiliary = auxiliary;

  void addRoutes(RouterPlus app) {
    app.put('/api/v1/scales/<id>/<command>', (
      Request _,
      String id,
      String command,
    ) async {
      final String deviceId;
      try {
        deviceId = decodeOpaquePathComponent(id);
      } catch (_) {
        return jsonBadRequest({'error': 'Malformed scale id'});
      }
      if (command != 'tare') {
        return jsonNotFound({'error': 'Unknown command: $command'});
      }
      final scale = _resolve(deviceId);
      if (scale == null) {
        return jsonNotFound({'error': 'Scale not connected: $deviceId'});
      }
      try {
        await scale.tare();
      } catch (e) {
        _log.warning('tare failed for $deviceId', e);
        return jsonError({
          'error': e.toString(),
          if (e is ScaleOperationException) 'code': e.code,
        });
      }
      return jsonOk(null);
    });

    app.get('/ws/v1/scales/<id>/snapshot', (Request request, String id) {
      final String deviceId;
      try {
        deviceId = decodeOpaquePathComponent(id);
      } catch (_) {
        return jsonBadRequest({'error': 'Malformed scale id'});
      }
      return admittedWebSocketHandler(
        (socket, protocol) => _handleSnapshot(socket, deviceId),
      )(request);
    });
  }

  _AddressedScale? _resolve(String deviceId) {
    try {
      final primary = _primary.connectedScale();
      if (primary.deviceId == deviceId) return _AddressedScale.primary(primary);
    } on DeviceNotConnectedException {
      // no primary scale; an auxiliary one may still answer
    }
    final session = _auxiliary.session(deviceId);
    if (session == null) return null;
    return _AddressedScale.auxiliary(session);
  }

  Future<void> _handleSnapshot(WebSocketChannel socket, String deviceId) async {
    _log.fine("snapshot socket for $deviceId");

    StreamSubscription<ScaleSnapshot>? snapshotSub;
    StreamSubscription<ConnectionState>? connSub;

    void sendStatus(String status) {
      try {
        socket.sink.add(jsonEncode({'status': status}));
      } catch (_) {}
    }

    void send(ScaleSnapshot snapshot) {
      try {
        socket.sink.add(jsonEncode(snapshot.toJson()));
      } catch (e, st) {
        _log.severe('failed to send snapshot for $deviceId', e, st);
      }
    }

    final addressed = _resolve(deviceId);
    if (addressed == null) {
      sendStatus('disconnected');
      await socket.sink.close();
      return;
    }

    void attach() {
      snapshotSub?.cancel();
      snapshotSub = addressed.snapshots.listen(send);
    }

    connSub = addressed.connectionState.listen((state) {
      if (state == ConnectionState.connected) {
        sendStatus('connected');
        attach();
      } else {
        snapshotSub?.cancel();
        snapshotSub = null;
        sendStatus('disconnected');
      }
    });

    socket.stream.listen(
      (_) {},
      onDone: () {
        connSub?.cancel();
        snapshotSub?.cancel();
      },
      onError: (_, _) {
        connSub?.cancel();
        snapshotSub?.cancel();
      },
    );
  }
}

/// A scale reached by id, hiding which side of the primary/auxiliary line it
/// happens to sit on -- which is the whole point of addressing one by id.
class _AddressedScale {
  final Stream<ScaleSnapshot> snapshots;
  final Stream<ConnectionState> connectionState;
  final Future<void> Function() _tare;

  _AddressedScale._({
    required this.snapshots,
    required this.connectionState,
    required Future<void> Function() tare,
  }) : _tare = tare;

  factory _AddressedScale.primary(Scale scale) => _AddressedScale._(
    snapshots: scale.currentSnapshot,
    connectionState: scale.connectionState,
    tare: scale.tare,
  );

  factory _AddressedScale.auxiliary(AuxiliaryScaleSession session) =>
      _AddressedScale._(
        snapshots: session.snapshot,
        connectionState: session.connectionState,
        tare: session.tare,
      );

  Future<void> tare() => _tare();
}
