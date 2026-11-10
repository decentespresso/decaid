import 'package:reaprime/src/models/device/device.dart';

bool isEphemeralDeviceIdentity(String deviceId) {
  if (deviceId.startsWith('usb-session-')) return true;
  return RegExp(
    r'^usb-[0-9a-fA-F]+-[0-9a-fA-F]+-unknown(?:-if[0-9a-fA-F]+)?(?:-[0-9]+)?$',
  ).hasMatch(deviceId.trim());
}

abstract interface class CanonicalDeviceIdentity {
  String? get canonicalDeviceId;
}

bool matchesDeviceIdentity(Device device, String? id) =>
    id != null &&
    (device.deviceId == id ||
        (device is CanonicalDeviceIdentity &&
            (device as CanonicalDeviceIdentity).canonicalDeviceId == id));
