import 'package:reaprime/src/controllers/connection_manager.dart';
import 'package:reaprime/src/controllers/device_controller.dart';
import 'package:reaprime/src/settings/settings_controller.dart';
import 'package:reaprime/src/services/webserver/json_response.dart';
import 'package:shelf_plus/shelf_plus.dart';

class BleDiagnosticsHandler {
  final DeviceController deviceController;
  final ConnectionManager connectionManager;
  final SettingsController settingsController;

  const BleDiagnosticsHandler({
    required this.deviceController,
    required this.connectionManager,
    required this.settingsController,
  });

  void addRoutes(RouterPlus app) {
    app.get('/api/v1/diagnostics/ble', _handleGet);
  }

  Future<Response> _handleGet(Request request) async {
    final status = connectionManager.currentStatus;
    return jsonOk({
      'timestamp': DateTime.now().toUtc().toIso8601String(),
      'ble': {
        'adapterState': deviceController.currentAdapterState.name,
        'services': await deviceController.bleDiagnostics(),
      },
      'connection': {
        'phase': status.phase.name,
        'intent': status.intent.name,
        'pendingAmbiguity': status.pendingAmbiguity?.name,
        'activeTargetTransport': status.activeTargetTransport?.name,
        'preferredScaleId': settingsController.preferredScaleId,
        'scalePowerMode': settingsController.scalePowerMode.name,
        'shouldRetryPreferredScale':
            connectionManager.shouldRetryPreferredScale,
        'scaleReconnectBlockedByPowerMode':
            connectionManager.scaleReconnectBlockedByPowerMode,
        'scaleReconnectFailures': connectionManager.scaleReconnectFailures,
        'scaleReconnectScheduled': connectionManager.scaleReconnectScheduled,
        'scaleWatch': connectionManager.scaleWatchDiagnostics,
        'stateWatchdogActive': connectionManager.stateWatchdogActive,
        'snapshotStalenessReconnects':
            connectionManager.diagnosticSnapshotStalenessReconnects,
      },
    });
  }
}
