import 'package:reaprime/src/models/device/device_implementation.dart';
import 'package:reaprime/src/models/device/transport/data_transport.dart';

import 'test_scale.dart';

class TestUsbHds extends TestScale {
  TestUsbHds({
    super.deviceId = 'usb-1a86-7522-unknown-1004',
    super.name = 'Half Decent Scale (USB)',
  });

  @override
  DeviceImplementation get implementation => DeviceImplementation.hdsSerial;

  @override
  TransportType get transportType => TransportType.serial;
}
