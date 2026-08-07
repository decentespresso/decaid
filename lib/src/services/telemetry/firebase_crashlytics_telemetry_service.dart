import 'package:flutter/foundation.dart';
import 'package:firebase_crashlytics/firebase_crashlytics.dart';
import 'package:firebase_analytics/firebase_analytics.dart';
import 'package:firebase_performance/firebase_performance.dart';
import 'package:reaprime/src/services/telemetry/crashlytics_error_filter.dart';
import 'package:reaprime/src/services/telemetry/telemetry_service.dart';
import 'package:reaprime/src/services/telemetry/log_buffer.dart';
import 'package:reaprime/src/services/telemetry/telemetry_report_queue.dart';

/// Firebase Crashlytics implementation of TelemetryService
///
/// Wraps Firebase Crashlytics SDK with privacy-first defaults:
/// - Telemetry collection disabled by default (requires explicit consent)
/// - Rolling log buffer attached to all error reports for context
/// - Custom keys for session and device metadata
/// - Bounded async report queue to prevent blocking UI thread
class FirebaseCrashlyticsTelemetryService implements TelemetryService {
  final LogBuffer _logBuffer;
  late final TelemetryReportQueue _queue;

  /// Create a new Firebase Crashlytics telemetry service
  ///
  /// [logBuffer] - Rolling log buffer for attaching context to error reports
  FirebaseCrashlyticsTelemetryService(this._logBuffer) {
    _queue = TelemetryReportQueue(_sendReport);
  }

  @override
  Future<void> initialize() async {
    await FirebaseCrashlytics.instance.setCrashlyticsCollectionEnabled(false);
    await FirebaseAnalytics.instance.setAnalyticsCollectionEnabled(false);
    // Firebase Performance has no macOS/Linux implementation — skip to avoid
    // broken platform channel state that causes black screen in release mode
    if (!kIsWeb &&
        (defaultTargetPlatform == TargetPlatform.android ||
            defaultTargetPlatform == TargetPlatform.iOS)) {
      await FirebasePerformance.instance.setPerformanceCollectionEnabled(false);
    }

    // TELE-04: Set up global error handlers to route through TelemetryService.
    // Filter known-benign exceptions (DeviceNotConnectedException and typed
    // UniversalBleException disconnect/cancellation errors) from fire-and-forget
    // contexts (Timer callbacks, unawaited Futures). These are handled by upper
    // layers but can reach the framework error handler without being caught —
    // recording them as FATAL creates false crash signals in Crashlytics
    // (see fa51312d, eeea9be0). This is the safety net; device implementations
    // should still catch at their write level for graceful recovery.
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

  /// Internal method to actually send a report to Firebase
  ///
  /// This is called by the queue's async drain loop and performs the actual
  /// platform channel IPC to Firebase Crashlytics.
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
    // Enqueue the report for async processing
    // This returns quickly without blocking on platform channel calls
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
    // Firebase Performance has no macOS/Linux implementation — same guard as
    // initialize(). Collection is consent-gated, so traces are dropped client
    // side until the user consents.
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
