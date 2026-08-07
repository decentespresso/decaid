import 'de1_interface.dart';
import 'device_attach_notifier.dart';

sealed class AttachProbeResult {
  const AttachProbeResult();
}

class AttachProbeConnected extends AttachProbeResult {
  const AttachProbeConnected(this.machine);

  final De1Interface machine;
}

class AttachProbeUnsupported extends AttachProbeResult {
  const AttachProbeUnsupported();
}

class AttachProbeUnavailable extends AttachProbeResult {
  const AttachProbeUnavailable();
}

class AttachProbeFailed extends AttachProbeResult {
  const AttachProbeFailed({this.deviceId, this.deviceName});

  final String? deviceId;
  final String? deviceName;
}

abstract class UsbAttachProbe {
  Future<AttachProbeResult> connectAttachedMachine(DeviceAttachedEvent event);
}
