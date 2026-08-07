import 'package:flutter/foundation.dart';
import 'package:firebase_crashlytics/firebase_crashlytics.dart';
import 'package:firebase_analytics/firebase_analytics.dart';
import 'package:firebase_performance/firebase_performance.dart';
import 'package:reaprime/src/services/telemetry/crashlytics_error_filter.dart';
import 'package:reaprime/src/services/telemetry/telemetry_service.dart';
import 'package:reaprime/src/services/telemetry/log_buffer.dart';
import 'package:reaprime/src/services/telemetry/telemetry_report_queue.dart';

class FirebaseCrashlyticsTelemetryService implements TelemetryService {
  final LogBuffer _logBuffer;
  late final TelemetryReportQueue _queue;

  FirebaseCrashlyticsTelemetryService(this._logBuffer) {
    _queue = TelemetryReportQueue(_sendReport);
  }

  @override
  Future<void> initialize() async {
    await FirebaseCrashlytics.instance.setCrashlyticsCollectionEnabled(false);
    await FirebaseAnalytics.instance.setAnalyticsCollectionEnabled(false);
    if (!kIsWeb &&
        (defaultTargetPlatform == TargetPlatform.android ||
            defaultTargetPlatform == TargetPlatform.iOS)) {
      await FirebasePerformance.instance.setPerformanceCollectionEnabled(false);
    }

    FlutterError.onError = (details) {
      if (isBenignFrameworkError(details.exception)) return;
      FirebaseCrashlytics.instance.recordFlutterFatalError(details);
    };

    PlatformDispatcher.instance.onError = (error, stack) {
      if (isBenignFrameworkError(error)) return true;
      FirebaseCrashlytics.instance.recordError(error, stack, fatal: true);
      return true;
    };
  }

  Future<void> _sendReport(
    Object error,
    StackTrace? stackTrace, {
    bool fatal = false,
  }) async {
    await FirebaseCrashlytics.instance.setCustomKey(
      'log_buffer',
      _logBuffer.getContents(),
    );

    await FirebaseCrashlytics.instance.recordError(
      error,
      stackTrace,
      fatal: fatal,
    );
  }

  @override
  Future<void> recordError(
    Object error,
    StackTrace? stackTrace, {
    bool fatal = false,
  }) async {
    _queue.enqueue(error, stackTrace, fatal: fatal);
  }

  @override
  Future<void> log(String message) async {
    await FirebaseCrashlytics.instance.log(message);
    _logBuffer.append(message);
  }

  @override
  Future<void> setCustomKey(String key, Object value) async {
    await FirebaseCrashlytics.instance.setCustomKey(key, value);
  }

  @override
  Future<void> recordTrace(String name, Map<String, int> metrics) async {
    if (kIsWeb ||
        !(defaultTargetPlatform == TargetPlatform.android ||
            defaultTargetPlatform == TargetPlatform.iOS)) {
      return;
    }
    final trace = FirebasePerformance.instance.newTrace(name);
    await trace.start();
    metrics.forEach(trace.setMetric);
    await trace.stop();
  }

  @override
  Future<void> setConsentEnabled(bool enabled) async {
    await FirebaseCrashlytics.instance.setCrashlyticsCollectionEnabled(enabled);
    await FirebaseAnalytics.instance.setAnalyticsCollectionEnabled(enabled);
    if (!kIsWeb &&
        (defaultTargetPlatform == TargetPlatform.android ||
            defaultTargetPlatform == TargetPlatform.iOS)) {
      await FirebasePerformance.instance.setPerformanceCollectionEnabled(
        enabled,
      );
    }
  }

  @override
  String getLogBuffer() {
    return _logBuffer.getContents();
  }
}
