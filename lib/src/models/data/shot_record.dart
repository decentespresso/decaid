import 'package:reaprime/src/models/data/shot_annotations.dart';
import 'package:reaprime/src/models/data/shot_snapshot.dart';
import 'package:reaprime/src/models/data/workflow.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

class ShotRecord {
  final String id;
  final DateTime timestamp;
  final List<ShotSnapshot> measurements;
  final Workflow workflow;
  final ShotAnnotations? annotations;

  /// Why the shot ended, as decided by the ShotSequencer
  /// (`ShotDecisionReason.name`, e.g. `targetWeight`, `machineEnded`).
  /// Machine-derived and immutable — deliberately NOT part of
  /// [ShotAnnotations], which holds user-entered tasting metadata. Stored as
  /// an open string: newer builds may persist reasons this build doesn't
  /// know, and they must survive round-trips. Null for legacy shots and for
  /// shots the app didn't sequence (e.g. full gateway mode, backgrounded).
  final String? stopReason;

  final String? _shotNotes;
  final Map<String, dynamic>? _metadata;

  ShotRecord({
    required this.id,
    required this.timestamp,
    required this.measurements,
    required this.workflow,
    this.annotations,
    this.stopReason,
    String? shotNotes,
    Map<String, dynamic>? metadata,
  }) : _shotNotes = annotations != null ? annotations.espressoNotes : shotNotes,
       _metadata = annotations != null ? annotations.extras : metadata;

  /// Synthesized from annotations when available, otherwise from legacy field.
  @Deprecated('Use annotations?.espressoNotes instead')
  String? get shotNotes => _shotNotes;

  @Deprecated('Use annotations?.extras instead')
  Map<String, dynamic>? get metadata => _metadata;

  Map<String, dynamic> toJson() {
    return {
      "id": id,
      "timestamp": timestamp.toIso8601String(),
      "measurements": measurements.map((e) => e.toJson()).toList(),
      "workflow": workflow.toJson(),
      if (annotations != null) "annotations": annotations!.toJson(),
      if (stopReason != null) "stopReason": stopReason,
      if (_shotNotes != null) "shotNotes": _shotNotes,
      if (_metadata != null) "metadata": _metadata,
    };
  }

  /// JSON without measurements — used for paginated list responses.
  Map<String, dynamic> toJsonWithoutMeasurements() {
    return {
      "id": id,
      "timestamp": timestamp.toIso8601String(),
      "workflow": workflow.toJson(),
      if (annotations != null) "annotations": annotations!.toJson(),
      if (stopReason != null) "stopReason": stopReason,
      if (_shotNotes != null) "shotNotes": _shotNotes,
      if (_metadata != null) "metadata": _metadata,
    };
  }

  factory ShotRecord.fromJson(Map<String, dynamic> json) {
    ShotAnnotations? ann;
    if (json.containsKey('annotations')) {
      final annotations = json['annotations'];
      if (annotations != null) {
        ann = ShotAnnotations.fromJson(annotations as Map<String, dynamic>);
      }
    } else if (json.containsKey('shotNotes') || json.containsKey('metadata')) {
      ann = ShotAnnotations.fromLegacyJson(json);
    }

    return ShotRecord(
      id: json["id"],
      timestamp: DateTime.parse(json["timestamp"]),
      measurements: (json["measurements"] as List)
          .map((e) => ShotSnapshot.fromJson(e))
          .toList(),
      workflow: Workflow.fromJson(json["workflow"]),
      annotations: ann,
      stopReason: json["stopReason"] as String?,
      shotNotes: json.containsKey('annotations')
          ? null
          : json["shotNotes"] as String?,
      metadata: json.containsKey('annotations')
          ? null
          : json["metadata"] as Map<String, dynamic>?,
    );
  }

  String shotTime() {
    final dateFormat = DateFormat.yMd();
    final timeFormat = DateFormat('jm');
    return "${dateFormat.format(timestamp)}, ${timeFormat.format(timestamp)}";
  }

  ShotRecord copyWith({
    String? id,
    DateTime? timestamp,
    List<ShotSnapshot>? measurements,
    Workflow? workflow,
    ShotAnnotations? annotations,
    String? stopReason,
    String? shotNotes,
    Map<String, dynamic>? metadata,
  }) {
    return ShotRecord(
      id: id ?? this.id,
      timestamp: timestamp ?? this.timestamp,
      measurements: measurements ?? this.measurements,
      workflow: workflow ?? this.workflow,
      annotations: annotations ?? this.annotations,
      stopReason: stopReason ?? this.stopReason,
      shotNotes: shotNotes ?? _shotNotes,
      metadata: metadata ?? _metadata,
    );
  }
}
