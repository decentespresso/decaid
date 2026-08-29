import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/services/telemetry/log_buffer.dart';
import 'package:reaprime/src/services/telemetry/noop_telemetry_service.dart';
import 'package:reaprime/src/services/telemetry/telemetry_service.dart';

void main() {
  test('personal builds always use no-op telemetry', () {
    final service = TelemetryService.create(
      logBuffer: LogBuffer(),
      personalBuild: true,
    );

    expect(service, isA<NoOpTelemetryService>());
  });
}
