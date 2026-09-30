import 'package:reaprime/src/controllers/scale_controller.dart';
import 'package:reaprime/src/models/device/machine.dart';

class ShotSnapshot {
  final MachineSnapshot machine;
  final WeightSnapshot? scale;
  final double? volume;

  /// Latest frame from each attached sensor at this sample, keyed by sensor
  /// deviceId (e.g. `<machine>-puckestimator`), holding that sensor's own
  /// channel map.
  ///
  /// Sensor output is deliberately NOT on [MachineSnapshot] -- observer and
  /// probe data are not machine telemetry -- but a shot record still has to
  /// carry it, or the estimator becomes live-only and history silently loses a
  /// channel it used to have. Absent (not empty) when no sensor was attached,
  /// so old records and sensor-less machines round-trip unchanged.
  final Map<String, Map<String, dynamic>>? sensors;

  ShotSnapshot({required this.machine, this.scale, this.volume, this.sensors});

  ShotSnapshot copyWith({
    MachineSnapshot? machine,
    WeightSnapshot? scale,
    double? volume,
    Map<String, Map<String, dynamic>>? sensors,
  }) {
    return ShotSnapshot(
      machine: machine ?? this.machine,
      scale: scale ?? this.scale,
      volume: volume ?? this.volume,
      sensors: sensors ?? this.sensors,
    );
  }

  Map<String, Object?> toJson() {
    return {
      "machine": machine.toJson(),
      "scale": scale?.toJson(),
      "volume": volume,
      // Omitted entirely when there was no sensor, rather than written as an
      // empty map: shot records are persisted per sample, and an empty object
      // on every one of them is pure weight.
      if (sensors != null && sensors!.isNotEmpty) "sensors": sensors,
    };
  }

  factory ShotSnapshot.fromJson(Map<String, dynamic> json) {
    final rawSensors = json['sensors'];
    return ShotSnapshot(
      machine: MachineSnapshot.fromJson(json["machine"]),
      scale: json['scale'] != null
          ? WeightSnapshot.fromJson(json["scale"])
          : null,
      volume: json['volume'] as double?,
      sensors: rawSensors is Map
          ? {
              for (final entry in rawSensors.entries)
                if (entry.value is Map)
                  entry.key as String: Map<String, dynamic>.from(
                    entry.value as Map,
                  ),
            }
          : null,
    );
  }
}
