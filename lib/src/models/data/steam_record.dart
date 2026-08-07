import 'package:reaprime/src/models/data/shot_annotations.dart';
import 'package:reaprime/src/models/data/steam_snapshot.dart';
import 'package:reaprime/src/models/data/workflow.dart';

class SteamRecord {
  final String id;
  final DateTime timestamp;
  final List<SteamSnapshot> measurements;
  final Workflow workflow;
  final ShotAnnotations? annotations;

  SteamRecord({
    required this.id,
    required this.timestamp,
    required this.measurements,
    required this.workflow,
    this.annotations,
  });

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'timestamp': timestamp.toIso8601String(),
      'measurements': measurements.map((e) => e.toJson()).toList(),
      'workflow': workflow.toJson(),
      if (annotations != null) 'annotations': annotations!.toJson(),
    };
  }

  Map<String, dynamic> toJsonWithoutMeasurements() {
    return {
      'id': id,
      'timestamp': timestamp.toIso8601String(),
      'workflow': workflow.toJson(),
      if (annotations != null) 'annotations': annotations!.toJson(),
    };
  }

  factory SteamRecord.fromJson(Map<String, dynamic> json) {
    return SteamRecord(
      id: json['id'] as String,
      timestamp: DateTime.parse(json['timestamp'] as String),
      measurements: (json['measurements'] as List? ?? const [])
          .map((e) => SteamSnapshot.fromJson(e as Map<String, dynamic>))
          .toList(),
      workflow: Workflow.fromJson(json['workflow'] as Map<String, dynamic>),
      annotations: json['annotations'] != null
          ? ShotAnnotations.fromJson(
              json['annotations'] as Map<String, dynamic>,
            )
          : null,
    );
  }

  SteamRecord copyWith({
    String? id,
    DateTime? timestamp,
    List<SteamSnapshot>? measurements,
    Workflow? workflow,
    ShotAnnotations? annotations,
  }) {
    return SteamRecord(
      id: id ?? this.id,
      timestamp: timestamp ?? this.timestamp,
      measurements: measurements ?? this.measurements,
      workflow: workflow ?? this.workflow,
      annotations: annotations ?? this.annotations,
    );
  }
}
