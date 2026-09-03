import 'dart:async';

import 'package:logging/logging.dart';
import 'package:reaprime/src/models/device/device.dart';
import 'package:reaprime/src/models/device/device_scanner.dart';
import 'package:reaprime/src/models/device/scale.dart';
import 'package:reaprime/src/models/device/watch_filter.dart';
import 'package:reaprime/src/models/device/watch_state.dart';

class ScaleWatch {
  static final _log = Logger('ScaleWatch');

  final DeviceScanner _scanner;
  final bool Function() _shouldWatch;
  final String? Function() _preferredScaleId;
  final Future<void> Function(Scale) _connectScale;
  final void Function() _onWatchUnavailable;

  StreamSubscription<List<Device>>? _sub;
  StreamSubscription<void>? _failureSub;
  StreamSubscription<DeviceWatchState>? _stateSub;
  bool _armed = false;
  bool _requested = false;
  bool _lowerWatchRequested = false;
  bool _connecting = false;

  int _generation = 0;

  ScaleWatch({
    required DeviceScanner scanner,
    required bool Function() shouldWatch,
    required String? Function() preferredScaleId,
    required Future<void> Function(Scale) connectScale,
    required void Function() onWatchUnavailable,
  }) : _scanner = scanner,
       _shouldWatch = shouldWatch,
       _preferredScaleId = preferredScaleId,
       _connectScale = connectScale,
       _onWatchUnavailable = onWatchUnavailable;

  bool get armed => _armed;
  bool get hasPendingRequest =>
      _requested || _armed || _lowerWatchRequested || _sub != null;

  Map<String, Object?> get diagnostics => {
    'armed': _armed,
    'requested': _requested,
    'lowerWatchRequested': _lowerWatchRequested,
    'generation': _generation,
    'connecting': _connecting,
    'deviceSubscriptionInstalled': _sub != null,
    'failureSubscriptionInstalled': _failureSub != null,
    'stateSubscriptionInstalled': _stateSub != null,
  };

  Future<void> arm() async {
    if (_requested || _armed) return;
    if (!_shouldWatch()) return;
    final id = _preferredScaleId();
    if (id == null) return;

    _requested = true;
    final gen = _generation;
    if (_scanner.isScanning) {
      _listenForStart(gen);
      unawaited(_startAfterScan(gen));
      return;
    }
    final existing = _findPreferred(_scanner.devices, id);
    if (existing != null) {
      _armed = true;
      await _tryConnect(existing, gen);
      return;
    }

    _listenForStart(gen);

    final result = await _startWatchScan(gen);
    if (result == null || gen != _generation || !_requested) return;
    if (!_shouldWatch()) {
      await disarm();
      return;
    }
    if (result == DeviceWatchStartResult.active) {
      _activate(gen);
    } else if (result == DeviceWatchStartResult.failed) {
      _fail(gen);
    }
  }

  Future<void> disarm() async {
    if (!_requested && !_armed && !_lowerWatchRequested && _sub == null) {
      return;
    }
    _generation++;
    _requested = false;
    _armed = false;
    final lowerRequested = _lowerWatchRequested;
    _lowerWatchRequested = false;
    _cancelSubs();
    if (lowerRequested) {
      await _scanner.stopScaleWatch();
    }
  }

  void _cancelSubs() {
    final stateSub = _stateSub;
    _stateSub = null;
    unawaited(stateSub?.cancel());
    final sub = _sub;
    _sub = null;
    unawaited(sub?.cancel());
    final failureSub = _failureSub;
    _failureSub = null;
    unawaited(failureSub?.cancel());
  }

  Future<void> dispose() => disarm();

  Scale? _findPreferred(List<Device> devices, String id) =>
      devices.whereType<Scale>().where((s) => s.deviceId == id).firstOrNull;

  Future<void> _startAfterScan(int gen) async {
    try {
      await _scanner.scanningStream.firstWhere((scanning) => !scanning);
      if (gen != _generation || !_requested || !_shouldWatch()) return;
      _listenForStart(gen);
      final result = await _startWatchScan(gen);
      if (gen != _generation || !_requested || !_shouldWatch()) return;
      if (result == DeviceWatchStartResult.active) _activate(gen);
      if (result == DeviceWatchStartResult.failed) _fail(gen);
    } catch (e, st) {
      if (gen == _generation) {
        _log.warning('Failed to start background watch after scan', e, st);
        _fail(gen);
      }
    }
  }

  Future<DeviceWatchStartResult?> _startWatchScan(int gen) async {
    if (gen != _generation || !_requested) return null;
    _lowerWatchRequested = true;
    try {
      final result = await _scanner.startScaleWatch(const DeviceWatchFilter());
      if (result == DeviceWatchStartResult.failed) {
        _lowerWatchRequested = false;
      }
      return result;
    } catch (e, st) {
      _lowerWatchRequested = false;
      _log.warning('Failed to start background scale watch', e, st);
      _fail(gen);
      return null;
    }
  }

  void _listenForStart(int gen) {
    _cancelStateSub();
    _stateSub = _scanner.scaleWatchState.listen((state) {
      if (gen != _generation || !_requested) return;
      switch (state) {
        case DeviceWatchState.active:
          _activate(gen);
        case DeviceWatchState.faulted:
          _fail(gen);
        case DeviceWatchState.inactive || DeviceWatchState.queued:
          break;
      }
    });
  }

  void _activate(int gen) {
    if (gen != _generation || !_requested || !_shouldWatch()) return;
    if (_armed) return;
    _armed = true;
    _cancelStateSub();
    _listen(gen);
    _log.info('Background scale watch armed');
  }

  void _cancelStateSub() {
    final stateSub = _stateSub;
    _stateSub = null;
    unawaited(stateSub?.cancel());
  }

  void _fail(int gen) {
    if (gen != _generation || (!_requested && !_armed)) return;
    _generation++;
    _requested = false;
    _armed = false;
    _lowerWatchRequested = false;
    _cancelSubs();
    _onWatchUnavailable();
  }

  void _listen(int gen) {
    _cancelDataSubs();
    _sub = _scanner.deviceStream.skip(1).listen((devices) {
      if (gen != _generation || _connecting) return;
      final id = _preferredScaleId();
      if (id == null) return;
      final match = _findPreferred(devices, id);
      if (match == null) return;
      unawaited(_onSighting(match, gen));
    });
    _failureSub = _scanner.scaleWatchFailures.listen((_) {
      if (gen != _generation) return;
      _log.warning(
        'Background watch died and could not restart; '
        'falling back to legacy scale reconnect',
      );
      _fail(gen);
    });
  }

  void _cancelDataSubs() {
    final sub = _sub;
    _sub = null;
    unawaited(sub?.cancel());
    final failureSub = _failureSub;
    _failureSub = null;
    unawaited(failureSub?.cancel());
  }

  Future<void> _onSighting(Scale scale, int gen) async {
    if (gen != _generation || !_armed) return;
    _connecting = true;
    try {
      _log.info(
        'Preferred scale ${scale.deviceId} sighted; '
        'stopping watch and connecting',
      );
      await _scanner.stopScaleWatch();
      _lowerWatchRequested = false;
      if (gen != _generation || !_armed || !_shouldWatch()) return;
      _cancelDataSubs();
      _armed = false;
      await _tryConnect(scale, gen);
    } catch (e, st) {
      if (gen == _generation) {
        _log.warning('Failed to stop background watch before connect', e, st);
        _fail(gen);
      }
    } finally {
      _connecting = false;
    }
  }

  Future<void> _tryConnect(Scale scale, int gen) async {
    try {
      await _connectScale(scale);
    } catch (e, st) {
      _log.warning('Watch-driven scale connect threw', e, st);
    }
    if (gen != _generation) return;
    if (_shouldWatch()) {
      _log.fine('Scale still missing after connect attempt; watch continues');
      _listenForStart(gen);
      final result = await _startWatchScan(gen);
      if (gen != _generation || !_requested || !_armed || !_shouldWatch()) {
        if (_lowerWatchRequested) {
          try {
            await _scanner.stopScaleWatch();
          } catch (e, st) {
            _log.warning('Failed to cancel stale scale watch restart', e, st);
          }
          _lowerWatchRequested = false;
        }
        return;
      }
      if (result == DeviceWatchStartResult.active) _activate(gen);
      if (result == DeviceWatchStartResult.failed) _fail(gen);
    } else {
      try {
        await disarm();
      } catch (e, st) {
        _log.warning('Failed to stop background watch after connect', e, st);
      }
    }
  }
}
