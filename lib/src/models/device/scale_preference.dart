import 'package:reaprime/src/models/device/device.dart';
import 'package:reaprime/src/models/device/device_identity.dart';
import 'package:reaprime/src/models/device/device_implementation.dart';
import 'package:reaprime/src/models/device/transport/data_transport.dart';

const usbHdsScalePreference = 'usb-hds:any';

bool _isSeriallessUsbHds(Device device) =>
    device.type == DeviceType.scale &&
    device.implementation == DeviceImplementation.hdsSerial &&
    device.transportType == TransportType.serial &&
    isEphemeralDeviceIdentity(device.deviceId);

String scalePreferenceId(Device device) =>
    _isSeriallessUsbHds(device) ? usbHdsScalePreference : device.deviceId;

bool matchesScalePreference(Device device, String? preferredId) =>
    preferredId == usbHdsScalePreference
    ? _isSeriallessUsbHds(device)
    : preferredId != null && device.deviceId == preferredId;
