import 'dart:async';
import 'package:logging/logging.dart';
import 'package:reaprime/src/services/telemetry/telemetry_service.dart';

class BootTiming {
  static final Stopwatch _sw = Stopwatch();
  static final Logger _log = Logger('BootTiming');
  static final Map<String, int> _marks = {};
  static int _lastMs = 0;
  static bool _completed = false;

  static TelemetryService? telemetry;

  static void start() {
    _sw
      ..reset()
      ..start();
    _lastMs = 0;
    _marks.clear();
    _completed = false;
  }

  static void mark(String label) {
    if (!_sw.isRunning) return;
    final now = _sw.elapsedMilliseconds;
    _log.info('[BOOT] $label: ${now}ms (Δ${now - _lastMs}ms)');
    _marks[_metricKey(label)] = now;
    _lastMs = now;
  }

  static void complete() {
    if (_completed || !_sw.isRunning) return;
    _completed = true;
    final total = _sw.elapsedMilliseconds;
    _sw.stop();
    _log.info('[BOOT] complete: total ${total}ms');
    final metrics = Map<String, int>.from(_marks)..['total_ms'] = total;
    final t = telemetry;
    if (t != null) {
      unawaited(
        t
            .recordTrace('cold_boot', metrics)
            .catchError((Object e) => _log.warning('boot trace failed: $e')),
      );
    }
  }

  static String _metricKey(String label) {
    var k = label.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]+'), '_');
    k = k.replaceAll(RegExp(r'^_+|_+$'), '');
    if (!k.endsWith('_ms')) k = '${k}_ms';
    if (k.length > 32) k = k.substring(0, 32);
    return k;
  }
}
