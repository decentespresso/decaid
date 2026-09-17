import 'device.dart';

enum GrinderState { idle, grinding, error, unknown }

enum GrinderCapability { startStop, grindSetting, rpmControl }

abstract class GrinderDevice extends Device {
  Set<GrinderCapability> get capabilities;
  Stream<GrinderSnapshot> get currentSnapshot;

  Future<void> start();
  Future<void> stop();
  Future<void> setGrindSetting(String setting);
  Future<void> setRpm(int rpm);
}

class GrinderSnapshot {
  final DateTime timestamp;
  final GrinderState state;
  final String? setting;
  final int? rpm;

  const GrinderSnapshot({
    required this.timestamp,
    required this.state,
    this.setting,
    this.rpm,
  });

  Map<String, dynamic> toJson() => {
    'timestamp': timestamp.toIso8601String(),
    'state': state.name,
    if (setting != null) 'setting': setting,
    if (rpm != null) 'rpm': rpm,
  };
}

class GrinderOperationException implements Exception {
  final String message;
  final String code;

  const GrinderOperationException(
    this.message, {
    this.code = 'grinder_operation_error',
  });

  @override
  String toString() => message;
}
