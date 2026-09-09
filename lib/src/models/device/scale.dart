import 'device.dart';

abstract class Scale extends Device {
  ScaleInfo? get scaleInfo => null;
  Stream<ScaleSnapshot> get currentSnapshot;

  Future<void> tare();

  Future<void> sleepDisplay();

  Future<void> wakeDisplay();

  Future<void> startTimer() async {}
  Future<void> stopTimer() async {}
  Future<void> resetTimer() async {}
}

class ScaleInfo {
  final String? firmwareVersion;

  const ScaleInfo({this.firmwareVersion});

  Map<String, dynamic> toJson() => {
    if (firmwareVersion != null) 'firmwareVersion': firmwareVersion,
  };
}

abstract interface class TransportHandoffScale {
  Future<void> disconnectForHandoff();
}

abstract interface class ScaleSnapshotHandoff {
  void activateSnapshots();
}

class ScaleSnapshot {
  final DateTime timestamp;
  final double weight;
  final int? batteryLevel;
  final Duration? timerValue;
  final double? flow;

  ScaleSnapshot({
    required this.timestamp,
    required this.weight,
    required this.batteryLevel,
    this.timerValue,
    this.flow,
  });

  Map<String, dynamic> toJson() {
    return {
      'timestamp': timestamp.toIso8601String(),
      'weight': weight,
      'batteryLevel': batteryLevel,
      'timerValue': timerValue?.inMilliseconds,
      'flow': flow,
    };
  }
}
