import 'package:reaprime/src/models/device/machine.dart';

class SteamSnapshot {
  final MachineSnapshot machine;
  final double? milkTemperature;

  SteamSnapshot({required this.machine, this.milkTemperature});

  SteamSnapshot copyWith({MachineSnapshot? machine, double? milkTemperature}) {
    return SteamSnapshot(
      machine: machine ?? this.machine,
      milkTemperature: milkTemperature ?? this.milkTemperature,
    );
  }

  Map<String, Object?> toJson() {
    return {'machine': machine.toJson(), 'milkTemperature': milkTemperature};
  }

  factory SteamSnapshot.fromJson(Map<String, dynamic> json) {
    return SteamSnapshot(
      machine: MachineSnapshot.fromJson(json['machine']),
      milkTemperature: (json['milkTemperature'] as num?)?.toDouble(),
    );
  }
}
