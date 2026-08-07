import 'package:collection/collection.dart';

enum GatewayMode { full, tracking, disabled }

extension GatewayModeFromString on GatewayMode {
  static GatewayMode? fromString(String mode) {
    return GatewayMode.values.firstWhereOrNull((t) => t.name == mode);
  }
}
