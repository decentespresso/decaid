import 'package:reaprime/src/models/device/watch_filter.dart';
import 'package:reaprime/src/models/device/watch_state.dart';

abstract class DeviceWatchCapable {
  bool get supportsDeviceWatch;

  Stream<DeviceWatchState> get deviceWatchState;

  Future<DeviceWatchStartResult> startDeviceWatch(DeviceWatchFilter filter);

  Future<void> stopDeviceWatch();

  Stream<void> get deviceWatchFailures;
}
