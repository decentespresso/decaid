import 'package:logging/logging.dart';
import 'package:reaprime/src/services/telemetry/telemetry_service.dart';

class NoOpTelemetryService implements TelemetryService {
  static final _logger = Logger('NoOpTelemetryService');

  @override
  Future<void> initialize() async {
    _logger.info('Telemetry disabled (NoOp mode)');
  }

  @override
  Future<void> recordError(
    Object error,
    StackTrace? stackTrace, {
    bool fatal = false,
  }) async {}

  @override
  Future<void> log(String message) async {}

  @override
  Future<void> setCustomKey(String key, Object value) async {}

  @override
  Future<void> recordTrace(String name, Map<String, int> metrics) async {}

  @override
  Future<void> setConsentEnabled(bool enabled) async {}

  @override
  String getLogBuffer() {
    return '';
  }
}
