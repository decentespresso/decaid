import 'dart:async';

import 'package:logging/logging.dart';
import 'package:reaprime/src/models/device/device.dart';
import 'package:reaprime/src/models/device/device_scanner.dart';
import 'package:reaprime/src/models/device/scale.dart';
import 'package:reaprime/src/models/device/watch_filter.dart';

class ScaleWatch {
  static final _log = Logger('ScaleWatch');

  final DeviceScanner _scanner;
  final bool Function() _shouldWatch;
  final String? Function() _preferredScaleId;
  final Future<void> Function(Scale) _connectScale;
  final void Function() _onWatchUnavailable;

  StreamSubscription<List<Device>>? _sub;
  StreamSubscription<void>? _failureSub;
  bool _armed = false;
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

  Future<void> arm() async {
    if (_armed) return;
    if (!_shouldWatch()) return;
    final id = _preferredScaleId();
    if (id == null) return;
    _armed = true;
    final gen = _generation;

    final existing = _findPreferred(_scanner.devices, id);
    if (existing != null) {
      _log.fine('Preferred scale already discovered; connecting directly');
      await _tryConnect(existing, gen);
      return;
    }

    if (!await _startWatchScan()) return;
    _listen(gen);
    _log.info('Background scale watch armed');
  }

  Future<void> disarm() async {
    if (!_armed && _sub == null) return;
    _generation++;
    _armed = false;
    _cancelSubs();
    await _scanner.stopScaleWatch();
  }

  void _cancelSubs() {
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

  Future<bool> _startWatchScan() async {
    const filter = DeviceWatchFilter();
    try {
      await _scanner.startScaleWatch(filter);
      return true;
    } catch (e, st) {
      _log.warning('Failed to start background scale watch', e, st);
      _armed = false;
      _onWatchUnavailable();
      return false;
    }
  }

  void _listen(int gen) {
    _cancelSubs();
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
      _generation++;
      _armed = false;
      _cancelSubs();
      _onWatchUnavailable();
    });
  }

  Future<void> _onSighting(Scale scale, int gen) async {
    _connecting = true;
    try {
      _log.info(
        'Preferred scale ${scale.deviceId} sighted; '
        'stopping watch and connecting',
      );
      await _scanner.stopScaleWatch();
      if (gen != _generation) return;
      await _tryConnect(scale, gen);
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
      if (!await _startWatchScan()) return;
      _listen(gen);
    } else {
      await disarm();
    }
  }
}
