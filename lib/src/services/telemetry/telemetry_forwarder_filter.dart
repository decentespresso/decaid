import 'dart:async';
import 'dart:io';

import 'package:logging/logging.dart';
import 'package:reaprime/src/models/errors.dart';
import 'package:reaprime/src/services/telemetry/crashlytics_error_filter.dart';

const _webUiStorageLoggerName = 'WebUIStorage';
const _skinAlreadyExistsPrefix = 'Skin already exists';
const _benignNetworkErrorPrefixes = [
  'Exception: Failed to fetch GitHub release:',
  'Exception: Failed to download:',
];

/// Loggers whose `WARNING+` records describe HTTP fetches we know can
/// transiently fail in the field (DNS, offline, GitHub rate-limit). When
/// the attached `error` is a transient network exception, the record is
/// dropped from telemetry forwarding regardless of message.
///
/// Intentionally narrow — adding a logger here also opts it in to
/// `_isTransientNetworkError` matching, so do not add loggers that should
/// surface their own SocketExceptions (e.g. BLE transports).
const _httpFetcherLoggers = <String>{_webUiStorageLoggerName, 'AndroidUpdater'};

/// Returns `false` for log records that should not be forwarded to Crashlytics
/// — either below the SEVERE forwarding threshold or matching a known
/// telemetry-noise pattern.
///
/// Only `SEVERE+` records are forwarded. WARNING records are still captured in
/// the local log buffer (for crash context) by the caller, but on their own
/// they are field noise — ~100+ benign WARNING events/week — so they never
/// reach Crashlytics. The caller still gates on `record.level >= Level.WARNING`
/// for buffer capture; this predicate independently enforces the SEVERE floor
/// for forwarding.
bool shouldForwardToTelemetry(LogRecord record) {
  // Only SEVERE and above are crash signals. WARNING is informational field
  // noise and is dropped from forwarding regardless of source or content.
  if (record.level < Level.SEVERE) return false;

  if (record.error is DeviceNotConnectedException) return false;
  if (record.error is MmrTimeoutException) return false;
  if (record.error case final error? when isBenignFrameworkError(error)) {
    return false;
  }

  if (record.loggerName == _webUiStorageLoggerName &&
      record.message.startsWith(_skinAlreadyExistsPrefix)) {
    return false;
  }

  if (_httpFetcherLoggers.contains(record.loggerName) &&
      _isTransientNetworkError(record.error)) {
    return false;
  }

  return true;
}

bool _isTransientNetworkError(Object? error) {
  if (error == null) return false;
  if (error is SocketException) return true;
  if (error is TimeoutException) return true;
  if (error is HttpException) return true;
  if (error.runtimeType.toString() == 'ClientException') return true;
  final asString = error.toString();
  for (final prefix in _benignNetworkErrorPrefixes) {
    if (asString.startsWith(prefix)) return true;
  }
  return false;
}
