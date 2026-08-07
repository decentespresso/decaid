import 'package:reaprime/src/models/device/watch_filter.dart';

abstract class DeviceWatchCapable {
  bool get supportsDeviceWatch;

  Future<void> startDeviceWatch(DeviceWatchFilter filter);

  Future<void> stopDeviceWatch();

  Stream<void> get deviceWatchFailures;
}
