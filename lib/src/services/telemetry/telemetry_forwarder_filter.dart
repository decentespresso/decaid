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

const _httpFetcherLoggers = <String>{_webUiStorageLoggerName, 'AndroidUpdater'};

bool shouldForwardToTelemetry(LogRecord record) {
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
