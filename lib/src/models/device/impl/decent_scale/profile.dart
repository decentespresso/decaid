library;

enum DecentScaleIdentity { unknown, originalDecentScale, halfDecentScale }

const _originalFirmwareVersions = <int, String>{
  0xFE: '1.0',
  0x02: '1.1',
  0x03: '1.2',
};

class DecentScaleCapabilities {
  final bool supportsSoftSleep;
  final bool supportsPowerOff;
  final bool unreliableCommandBuffer;
  final bool usesTimestampedWeightFrames;
  final bool supportsHdsExtendedCommands;

  const DecentScaleCapabilities({
    required this.supportsSoftSleep,
    required this.supportsPowerOff,
    required this.unreliableCommandBuffer,
    required this.usesTimestampedWeightFrames,
    required this.supportsHdsExtendedCommands,
  });

  static const DecentScaleCapabilities conservative = DecentScaleCapabilities(
    supportsSoftSleep: false,
    supportsPowerOff: false,
    unreliableCommandBuffer: true,
    usesTimestampedWeightFrames: false,
    supportsHdsExtendedCommands: false,
  );

  static const DecentScaleCapabilities originalTimestamped =
      DecentScaleCapabilities(
        supportsSoftSleep: false,
        supportsPowerOff: true,
        unreliableCommandBuffer: false,
        usesTimestampedWeightFrames: true,
        supportsHdsExtendedCommands: false,
      );

  static const DecentScaleCapabilities originalReliable =
      DecentScaleCapabilities(
        supportsSoftSleep: false,
        supportsPowerOff: false,
        unreliableCommandBuffer: false,
        usesTimestampedWeightFrames: false,
        supportsHdsExtendedCommands: false,
      );

  static const DecentScaleCapabilities originalPowerOff =
      DecentScaleCapabilities(
        supportsSoftSleep: false,
        supportsPowerOff: true,
        unreliableCommandBuffer: false,
        usesTimestampedWeightFrames: false,
        supportsHdsExtendedCommands: false,
      );

  static const DecentScaleCapabilities hdsExtended = DecentScaleCapabilities(
    supportsSoftSleep: false,
    supportsPowerOff: true,
    unreliableCommandBuffer: false,
    usesTimestampedWeightFrames: false,
    supportsHdsExtendedCommands: true,
  );

  static const DecentScaleCapabilities halfDecent = DecentScaleCapabilities(
    supportsSoftSleep: true,
    supportsPowerOff: true,
    unreliableCommandBuffer: false,
    usesTimestampedWeightFrames: false,
    supportsHdsExtendedCommands: true,
  );

  List<String> get labels {
    final enabled = <String>[];
    if (supportsSoftSleep) enabled.add('softSleep');
    if (supportsPowerOff) enabled.add('powerOff');
    if (unreliableCommandBuffer) enabled.add('unreliableCommandBuffer');
    if (usesTimestampedWeightFrames) enabled.add('timestampedWeightFrames');
    if (supportsHdsExtendedCommands) enabled.add('hdsExtendedCommands');
    enabled.sort();
    return enabled;
  }
}

class DecentHdsFirmwareVersion {
  final int major;
  final int minor;
  final int patch;

  const DecentHdsFirmwareVersion({
    required this.major,
    required this.minor,
    required this.patch,
  });

  static DecentHdsFirmwareVersion? fromBcd(int high, int low) {
    if (high < 0 || high > 0xFF || low < 0 || low > 0xFF) return null;
    final majorTens = high >> 4;
    final majorUnits = high & 0x0F;
    final minor = low >> 4;
    final patch = low & 0x0F;
    if (majorTens > 9 || majorUnits > 9) return null;
    final major = majorTens * 10 + majorUnits;
    if (major > 30) return null;
    return DecentHdsFirmwareVersion(major: major, minor: minor, patch: patch);
  }

  @override
  String toString() => '$major.$minor.$patch';
}

class DecentScaleProfile {
  final DecentScaleIdentity identity;
  final DecentScaleCapabilities capabilities;
  final int? originalFirmwareMarker;
  final String? originalFirmwareVersion;
  final DecentHdsFirmwareVersion? hdsFirmwareVersion;
  final bool sawTimestampedWeightFrame;
  final bool voltageProbeAccepted;

  const DecentScaleProfile({
    required this.identity,
    required this.capabilities,
    required this.originalFirmwareMarker,
    required this.originalFirmwareVersion,
    required this.hdsFirmwareVersion,
    required this.sawTimestampedWeightFrame,
    required this.voltageProbeAccepted,
  });

  static const DecentScaleProfile conservative = DecentScaleProfile(
    identity: DecentScaleIdentity.unknown,
    capabilities: DecentScaleCapabilities.conservative,
    originalFirmwareMarker: null,
    originalFirmwareVersion: null,
    hdsFirmwareVersion: null,
    sawTimestampedWeightFrame: false,
    voltageProbeAccepted: false,
  );

  factory DecentScaleProfile.fromEvidence({
    required bool statusResponseSeen,
    required bool sawTimestampedWeightFrame,
    required bool voltageProbeAccepted,
    int? originalFirmwareMarker,
    DecentHdsFirmwareVersion? hdsFirmwareVersion,
  }) {
    if (voltageProbeAccepted) {
      final capabilities =
          hdsFirmwareVersion != null && hdsFirmwareVersion.major >= 3
          ? DecentScaleCapabilities.halfDecent
          : DecentScaleCapabilities.hdsExtended;
      return DecentScaleProfile(
        identity: DecentScaleIdentity.halfDecentScale,
        capabilities: capabilities,
        originalFirmwareMarker: originalFirmwareMarker,
        originalFirmwareVersion: null,
        hdsFirmwareVersion: hdsFirmwareVersion,
        sawTimestampedWeightFrame: sawTimestampedWeightFrame,
        voltageProbeAccepted: true,
      );
    }
    if (statusResponseSeen || sawTimestampedWeightFrame) {
      final originalFirmwareVersion = sawTimestampedWeightFrame
          ? '1.2'
          : _originalFirmwareVersions[originalFirmwareMarker];
      final capabilities = sawTimestampedWeightFrame
          ? DecentScaleCapabilities.originalTimestamped
          : switch (originalFirmwareMarker) {
              0x02 => DecentScaleCapabilities.originalReliable,
              0x03 => DecentScaleCapabilities.originalPowerOff,
              _ => DecentScaleCapabilities.conservative,
            };
      return DecentScaleProfile(
        identity: DecentScaleIdentity.originalDecentScale,
        capabilities: capabilities,
        originalFirmwareMarker: originalFirmwareMarker,
        originalFirmwareVersion: originalFirmwareVersion,
        hdsFirmwareVersion: hdsFirmwareVersion,
        sawTimestampedWeightFrame: sawTimestampedWeightFrame,
        voltageProbeAccepted: false,
      );
    }
    return DecentScaleProfile(
      identity: DecentScaleIdentity.unknown,
      capabilities: DecentScaleCapabilities.conservative,
      originalFirmwareMarker: originalFirmwareMarker,
      originalFirmwareVersion: null,
      hdsFirmwareVersion: hdsFirmwareVersion,
      sawTimestampedWeightFrame: false,
      voltageProbeAccepted: false,
    );
  }

  bool get isHds => identity == DecentScaleIdentity.halfDecentScale;

  List<String> get capabilityLabels => capabilities.labels;

  @override
  String toString() =>
      'DecentScaleProfile(identity: $identity, capabilities: ${capabilities.labels}, '
      'originalFirmwareMarker: $originalFirmwareMarker, '
      'originalFirmwareVersion: $originalFirmwareVersion, '
      'hdsFirmwareVersion: $hdsFirmwareVersion, '
      'sawTimestampedWeightFrame: $sawTimestampedWeightFrame, '
      'voltageProbeAccepted: $voltageProbeAccepted)';
}

class DecentStatusFrame {
  final int batteryByte;
  final int batteryLevel;
  final bool charging;
  final int originalFirmwareMarker;
  final DecentHdsFirmwareVersion? hdsFirmwareVersion;

  const DecentStatusFrame({
    required this.batteryByte,
    required this.batteryLevel,
    required this.charging,
    required this.originalFirmwareMarker,
    required this.hdsFirmwareVersion,
  });
}

class DecentWeightFrame {
  final double weight;
  final bool timestamped;
  final int? timestampMillis;

  const DecentWeightFrame({
    required this.weight,
    required this.timestamped,
    required this.timestampMillis,
  });
}

class DecentVoltageFrame {
  final double voltage;

  const DecentVoltageFrame({required this.voltage});
}

DecentStatusFrame? parseDecentStatusFrame(List<int> data) {
  if (data.length != 7 || !_hasHeader(data, 0x0A)) return null;
  final batteryByte = data[4];
  return DecentStatusFrame(
    batteryByte: batteryByte,
    batteryLevel: batteryByte == 0xFF
        ? 100
        : (batteryByte > 100 ? 100 : batteryByte),
    charging: batteryByte == 0xFF,
    originalFirmwareMarker: data[5],
    hdsFirmwareVersion: DecentHdsFirmwareVersion.fromBcd(data[5], data[6]),
  );
}

DecentWeightFrame? parseDecentWeightFrame(List<int> data) {
  if ((data.length != 7 && data.length != 10) ||
      !_hasHeader(data, 0xCE, alternateOpcode: 0xCA)) {
    return null;
  }
  final timestamped = data.length == 10;
  if (timestamped && !_hasValidXorChecksum(data)) return null;
  var raw = (data[2] << 8) | data[3];
  if ((raw & 0x8000) != 0) raw -= 0x10000;
  return DecentWeightFrame(
    weight: raw / 10,
    timestamped: timestamped,
    timestampMillis: timestamped
        ? (data[4] * 600 + data[5] * 10 + data[6]) * 100
        : null,
  );
}

DecentVoltageFrame? parseDecentVoltageFrame(List<int> data) {
  if (data.length != 7 ||
      !_hasHeader(data, 0x22) ||
      !_hasValidXorChecksum(data)) {
    return null;
  }
  var raw = (data[2] << 8) | data[3];
  if ((raw & 0x8000) != 0) raw -= 0x10000;
  return DecentVoltageFrame(voltage: raw / 10);
}

bool _hasHeader(List<int> data, int opcode, {int? alternateOpcode}) {
  if (data.any((byte) => byte < 0 || byte > 0xFF) || data[0] != 0x03) {
    return false;
  }
  return data[1] == opcode || data[1] == alternateOpcode;
}

bool _hasValidXorChecksum(List<int> data) {
  final checksum = data
      .take(data.length - 1)
      .fold<int>(0, (value, byte) => value ^ byte);
  return checksum == data.last;
}
