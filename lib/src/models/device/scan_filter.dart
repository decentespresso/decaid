import 'package:reaprime/src/models/device/device.dart';

class ScanFilter {
  final String? preferredDeviceId;

  final Set<DeviceType>? deviceTypes;

  const ScanFilter({this.preferredDeviceId, this.deviceTypes});

  bool get isFiltered =>
      preferredDeviceId != null ||
      (deviceTypes != null && deviceTypes!.isNotEmpty);
}
