import 'dart:async';

import 'package:logging/logging.dart';
import 'package:reaprime/src/models/device/device.dart';
import 'package:reaprime/src/models/device/device_scanner.dart';
import 'package:reaprime/src/models/device/scale.dart';
import 'package:reaprime/src/models/device/watch_filter.dart';

/// Persistent background scale watch — the low-duty-cycle replacement
/// for ConnectionManager's preferred-scale backoff-burst reconnect loop.
///
/// While armed, a filtered OS-level scan runs continuously (via
/// [DeviceScanner.startScaleWatch]) and this collaborator listens on the
/// scanner's device stream; the moment the preferred scale appears it
/// stops the watch and connects. Modeled on `EarlyConnectWatcher` but
/// long-lived and re-armable.
///
/// The [shouldWatch] gate (ConnectionManager's
/// `_shouldRetryPreferredScale`) doubles as the connect-outcome probe:
/// `connectScale` (ConnectionManager.connectScale) swallows its own
/// errors, so success is observed as the gate flipping false (scale now
/// connected) and failure as it staying true — in which case the watch
/// scan restarts.
///
/// Eighth comms-layer collaborator (see CLAUDE.md → comms-layer patterns).
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

  /// Generation token (comms-harden idiom): bumped by [disarm] so an
  /// in-flight connect attempt completing afterwards cannot resurrect
  /// the watch.
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

  /// Arm the watch. Idempotent; no-op when the gate ([shouldWatch])
  /// doesn't hold.
  Future<void> arm() async {
    if (_armed) return;
    if (!_shouldWatch()) return;
    final id = _preferredScaleId();
    if (id == null) return;
    _armed = true;
    final gen = _generation;

    // A scale that is already discovered never re-advertises through the
    // watch (the scanner de-dups known devices) — connect it directly.
    // Also covers simulate mode, where MockScale never BLE-advertises.
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

  /// Disarm the watch and stop the underlying scan. Idempotent; safe
  /// to call before [arm].
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

  /// Start the watch scan. Deliberately unfiltered (no name prefix):
  /// remembered device names are friendly constants ("Felicita Arc")
  /// that rarely equal the advertised name the filter is matched
  /// against, and the universal_ble fork evaluates name filters
  /// plugin-side anyway — matching stays with the Dart DeviceMatcher
  /// path, same as burst scans. Returns false (and reports
  /// watch-unavailable so ConnectionManager can fall back to the legacy
  /// backoff loop) when the scanner refuses.
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
      // ConnectionManager.connectScale handles its own failures; anything
      // surfacing here is unexpected but must not kill the watch cycle.
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
