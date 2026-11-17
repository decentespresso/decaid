abstract class DeviceAttachNotifier {
  Stream<DeviceAttachedEvent> get deviceAttached;
}

class DeviceAttachedEvent {
  final String? deviceId;
  final String? name;
  final int? physicalDeviceId;

  const DeviceAttachedEvent({this.deviceId, this.name, this.physicalDeviceId});

  @override
  String toString() =>
      'DeviceAttachedEvent(${name ?? 'unnamed'}, ${deviceId ?? 'unknown id'}, physical=${physicalDeviceId ?? 'unknown'})';
}
