import 'device.dart';

abstract class Scale extends Device {
  Stream<ScaleSnapshot> get currentSnapshot;

  Future<void> tare();

  Future<void> sleepDisplay();

  Future<void> wakeDisplay();

  Future<void> startTimer() async {}
  Future<void> stopTimer() async {}
  Future<void> resetTimer() async {}
}

abstract interface class TransportHandoffScale {
  Future<void> disconnectForHandoff();
}

class ScaleSnapshot {
  final DateTime timestamp;
  final double weight;
  final int batteryLevel;
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
