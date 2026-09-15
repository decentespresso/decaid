import 'package:reaprime/src/controllers/connection_manager.dart';
import 'package:reaprime/src/controllers/device_controller.dart';
import 'package:reaprime/src/models/device/device.dart';
import 'package:reaprime/src/settings/settings_controller.dart';
import 'package:reaprime/src/services/webserver/json_response.dart';
import 'package:shelf_plus/shelf_plus.dart';

final Stopwatch _bleDiagnosticsClock = Stopwatch()..start();

class BleDiagnosticsHandler {
  static const Duration _deviceStateProbeTimeout = Duration(milliseconds: 250);

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
    final services = await deviceController.bleDiagnostics();
    final peers = await _deviceSnapshots();
    final sampledAt = DateTime.now().toUtc();

    return jsonOk({
      'diagnosticsVersion': 2,
      'timestamp': sampledAt.toIso8601String(),
      'monotonicMs': _bleDiagnosticsClock.elapsedMicroseconds ~/ 1000,
      'ble': {
        'adapterState': deviceController.currentAdapterState.name,
        'services': services,
      },
      'connection': {
        'phase': status.phase.name,
        'intent': status.intent.name,
        'pendingAmbiguity': status.pendingAmbiguity?.name,
        'activeTargetTransport': status.activeTargetTransport?.name,
        'preferredMachineId': settingsController.preferredMachineId,
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
        if (status.error != null) 'error': status.error!.toJson(),
        'conditions': [
          for (final condition in status.conditions)
            {
              'transport': condition.transportType.name,
              'affectedDeviceTypes': condition.affectedDeviceTypes
                  .map((type) => type.name)
                  .toList(growable: false),
              'error': condition.connectionError.toJson(),
            },
        ],
        'peers': peers,
      },
    });
  }

  Future<List<Map<String, Object?>>> _deviceSnapshots() async {
    final devices = deviceController.devices.toList(growable: false);
    return Future.wait(
      devices.map((device) async {
        ConnectionState? state;
        try {
          state = await device.connectionState
              .timeout(_deviceStateProbeTimeout)
              .first;
        } catch (_) {
          // Diagnostics must stay read-only and bounded even if a device's
          // state stream is currently silent or has failed.
        }

        final information = device is DeviceInformationCapable
            ? (device as DeviceInformationCapable).currentDeviceInformation
            : null;

        return <String, Object?>{
          'deviceId': device.deviceId,
          'name': device.name,
          'type': device.type.name,
          'transport': device.transportType.name,
          'instanceId': identityHashCode(device),
          'state': state?.name,
          if (information != null && !information.isEmpty)
            'information': information.toJson(),
        };
      }),
    );
  }
}
