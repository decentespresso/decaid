import 'package:flutter/material.dart';
import 'package:reaprime/src/controllers/connection_error.dart';
import 'package:reaprime/src/controllers/connection_manager.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

class ConnectionErrorBanner extends StatelessWidget {
  final ConnectionManager connectionManager;

  const ConnectionErrorBanner({super.key, required this.connectionManager});

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<ConnectionStatus>(
      stream: connectionManager.status,
      initialData: connectionManager.currentStatus,
      builder: (context, snapshot) {
        final err = snapshot.data?.error;
        if (err == null) return const SizedBox.shrink();

        final showRetry = _shouldOfferRetry(err.kind);

        return Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              ShadAlert.destructive(
                icon: Icon(_icon(err)),
                title: Text(_title(err)),
                description: Text(_body(err)),
              ),
              if (showRetry) ...[
                const SizedBox(height: 8),
                Align(
                  alignment: Alignment.centerRight,
                  child: ShadButton.outline(
                    onPressed: () => _retry(err.kind),
                    child: const Text('Retry'),
                  ),
                ),
              ],
            ],
          ),
        );
      },
    );
  }

  void _retry(String kind) {
    if (kind == ConnectionErrorKind.machineDisconnected ||
        kind == ConnectionErrorKind.scaleDisconnected) {
      connectionManager.connect();
    } else {
      connectionManager.scanAndConnect();
    }
  }

  bool _shouldOfferRetry(String kind) {
    return kind == ConnectionErrorKind.scaleConnectFailed ||
        kind == ConnectionErrorKind.machineConnectFailed ||
        kind == ConnectionErrorKind.scaleDisconnected ||
        kind == ConnectionErrorKind.machineDisconnected;
  }

  String _title(ConnectionError err) {
    final name = err.deviceName;
    switch (err.kind) {
      case ConnectionErrorKind.scaleConnectFailed:
      case ConnectionErrorKind.machineConnectFailed:
        return name != null ? 'Failed to connect $name' : 'Connect failed';
      case ConnectionErrorKind.scaleDisconnected:
      case ConnectionErrorKind.machineDisconnected:
        return name != null ? '$name disconnected' : 'Device disconnected';
      case ConnectionErrorKind.adapterOff:
        return 'Bluetooth is off';
      case ConnectionErrorKind.bluetoothPermissionDenied:
        return 'Bluetooth permission required';
      case ConnectionErrorKind.scanFailed:
        return 'Scan failed';
      default:
        return 'Connection problem';
    }
  }

  String _body(ConnectionError err) {
    final sug = err.suggestion;
    return sug != null ? '${err.message}\n$sug' : err.message;
  }

  IconData _icon(ConnectionError err) {
    switch (err.kind) {
      case ConnectionErrorKind.adapterOff:
        return Icons.bluetooth_disabled;
      case ConnectionErrorKind.bluetoothPermissionDenied:
        return Icons.lock_outline;
      default:
        return Icons.warning_amber_outlined;
    }
  }
}
