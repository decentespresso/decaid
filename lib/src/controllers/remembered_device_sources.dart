import 'package:reaprime/src/models/device/device.dart';
import 'package:reaprime/src/models/device/remembered_device.dart';
import 'package:reaprime/src/models/errors.dart';

RememberedDevice? rememberedFromMachine(Device? machine) =>
    machine == null ? null : RememberedDevice.fromDevice(machine);

RememberedDevice? rememberedFromScaleState(
  ConnectionState state,
  Device Function() connectedScale,
) {
  if (state.name != 'connected') return null;
  try {
    return RememberedDevice.fromDevice(connectedScale());
  } on DeviceNotConnectedException {
    return null;
  }
}
