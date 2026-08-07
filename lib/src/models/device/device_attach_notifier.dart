abstract class DeviceAttachNotifier {
  Stream<DeviceAttachedEvent> get deviceAttached;
}

class DeviceAttachedEvent {
  final String? deviceId;
  final String? name;

  const DeviceAttachedEvent({this.deviceId, this.name});

  @override
  String toString() =>
      'DeviceAttachedEvent(${name ?? 'unnamed'}, ${deviceId ?? 'unknown id'})';
}
