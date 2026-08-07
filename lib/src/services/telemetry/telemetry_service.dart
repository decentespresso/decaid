import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:reaprime/src/services/telemetry/firebase_crashlytics_telemetry_service.dart';
import 'package:reaprime/src/services/telemetry/noop_telemetry_service.dart';
import 'package:reaprime/src/services/telemetry/log_buffer.dart';

/// Abstract interface for telemetry services
///
/// Provides error reporting, logging, and contextual metadata collection.
/// Implementations may use Firebase Crashlytics, Sentry, or other backends.
/// A no-op implementation is provided for platforms without telemetry support.
abstract class TelemetryService {
  /// Initialize the telemetry service
  ///
  /// Must be called before any other methods. May perform platform-specific
  /// setup such as configuring crash handlers or setting default consent state.
  Future<void> initialize();

  /// Record an error with optional stack trace
  ///
  /// [error] - The error object to report
  /// [stackTrace] - Optional stack trace for the error
  /// [fatal] - Whether this error is fatal (caused app termination)
  Future<void> recordError(
    Object error,
    StackTrace? stackTrace, {
    bool fatal = false,
  });

  /// Log a message to the telemetry service
  ///
  /// Messages are typically buffered and attached to error reports for context.
  /// May also be sent to remote logging services depending on implementation.
  Future<void> log(String message);

  /// Set a custom key-value pair for contextual metadata
  ///
  /// These key-value pairs are attached to all subsequent error reports.
  /// Useful for tracking app state, user configuration, or session info.
  Future<void> setCustomKey(String key, Object value);

  /// Record a one-shot performance trace carrying named integer metrics (ms).
  ///
  /// Used for boot/startup timing. No-op when Performance Monitoring is
  /// unavailable (consent off, non-Android/iOS, or NoOp backend).
  Future<void> recordTrace(String name, Map<String, int> metrics);

  /// Enable or disable telemetry collection
  ///
  /// When disabled, no data should be sent to remote servers.
  /// Implementations should respect this setting immediately.
  Future<void> setConsentEnabled(bool enabled);

  /// Retrieve the current log buffer contents
  ///
  /// Returns a string containing recent log messages with timestamps.
  /// Useful for attaching to error reports or manual bug submissions.
  String getLogBuffer();

  /// Factory method to create the appropriate telemetry service for the platform
  ///
  /// [logBuffer] - Rolling log buffer for attaching context to error reports
  ///
  /// Returns [FirebaseCrashlyticsTelemetryService] on Android, iOS, and macOS.
  /// Returns [NoOpTelemetryService] on Linux/Windows, or when in debug mode or simulation mode.
  static TelemetryService create({required LogBuffer logBuffer}) {
    final isDebugMode = kDebugMode;
    final isSimulateMode = const bool.hasEnvironment('simulate');
    final isLinuxOrWindows = Platform.isLinux || Platform.isWindows;

    if (isDebugMode || isSimulateMode || isLinuxOrWindows) {
      return NoOpTelemetryService();
    }

    return FirebaseCrashlyticsTelemetryService(logBuffer);
  }
}
