import 'dart:convert';

import 'package:reaprime/src/models/data/shot_annotations.dart';
import 'package:reaprime/src/models/data/shot_snapshot.dart';
import 'package:reaprime/src/models/data/workflow.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

class ShotRecord {
  /// Keys in `annotations.extras` reserved for plugin sync state. Writes
  /// confined to these keys do not count as content changes.
  static const bookkeepingExtrasKeys = {
    'uploaded_to_decent',
    'decent_upload_rejected',
    'visualizerId',
  };

  final String id;
  final DateTime timestamp;
  final DateTime? createdAt;
  final DateTime? updatedAt;
  final List<ShotSnapshot> measurements;
  final Workflow workflow;
  final ShotAnnotations? annotations;

  final String? stopReason;

  final String? _shotNotes;
  final Map<String, dynamic>? _metadata;

  ShotRecord({
    required this.id,
    required this.timestamp,
    required this.measurements,
    required this.workflow,
    this.createdAt,
    this.updatedAt,
    this.annotations,
    this.stopReason,
    String? shotNotes,
    Map<String, dynamic>? metadata,
  }) : _shotNotes = annotations != null ? annotations.espressoNotes : shotNotes,
       _metadata = annotations != null ? annotations.extras : metadata;

  @Deprecated('Use annotations?.espressoNotes instead')
  String? get shotNotes => _shotNotes;

  @Deprecated('Use annotations?.extras instead')
  Map<String, dynamic>? get metadata => _metadata;

  Map<String, dynamic> toJson() {
    return {
      "id": id,
      "timestamp": timestamp.toIso8601String(),
      "createdAt": createdAt?.toUtc().toIso8601String(),
      "updatedAt": updatedAt?.toUtc().toIso8601String(),
      "measurements": measurements.map((e) => e.toJson()).toList(),
      "workflow": workflow.toJson(),
      if (annotations != null) "annotations": annotations!.toJson(),
      if (stopReason != null) "stopReason": stopReason,
      if (_shotNotes != null) "shotNotes": _shotNotes,
      if (_metadata != null) "metadata": _metadata,
    };
  }

  Map<String, dynamic> toJsonWithoutMeasurements() {
    return {
      "id": id,
      "timestamp": timestamp.toIso8601String(),
      "createdAt": createdAt?.toUtc().toIso8601String(),
      "updatedAt": updatedAt?.toUtc().toIso8601String(),
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

    final legacyTime = DateTime.parse(json["timestamp"]);
    final parsedCreatedAt = json["createdAt"] != null
        ? DateTime.parse(json["createdAt"] as String).toUtc()
        : null;
    final parsedUpdatedAt = json["updatedAt"] != null
        ? DateTime.parse(json["updatedAt"] as String).toUtc()
        : null;

    return ShotRecord(
      id: json["id"],
      timestamp: legacyTime,
      createdAt: parsedCreatedAt ?? legacyTime.toUtc(),
      updatedAt: parsedUpdatedAt ?? parsedCreatedAt ?? legacyTime.toUtc(),
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

  /// Canonical JSON of the user-meaningful content, used to decide whether a
  /// write is a real content change. Excludes the system-managed timestamps
  /// and the deprecated `metadata` mirror; bookkeeping extras are dropped, and
  /// an `extras` map emptied by that exclusion compares equal to no `extras`
  /// (likewise for `annotations`). Measurements are excluded unless
  /// [includeMeasurements] is set, matching callers that can edit them.
  Map<String, dynamic> contentSignature({bool includeMeasurements = false}) {
    final json = (includeMeasurements ? toJson() : toJsonWithoutMeasurements())
      ..remove('createdAt')
      ..remove('updatedAt')
      ..remove('metadata');
    final annotations = json['annotations'];
    if (annotations is Map<String, dynamic>) {
      final normalized = Map<String, dynamic>.from(annotations);
      final extras = normalized['extras'];
      if (extras is Map<String, dynamic>) {
        final cleaned = Map<String, dynamic>.from(extras)
          ..removeWhere(
            (key, _) => ShotRecord.bookkeepingExtrasKeys.contains(key),
          );
        if (cleaned.isEmpty) {
          normalized.remove('extras');
        } else {
          normalized['extras'] = cleaned;
        }
      }
      if (normalized.isEmpty) {
        json.remove('annotations');
      } else {
        json['annotations'] = normalized;
      }
    }
    return json;
  }

  /// True when both records carry identical user-meaningful content, ignoring
  /// system-managed timestamps and bookkeeping extras. Measurements count as
  /// content only when [includeMeasurements] is set.
  bool sameContent(ShotRecord other, {bool includeMeasurements = false}) =>
      jsonEncode(contentSignature(includeMeasurements: includeMeasurements)) ==
      jsonEncode(
        other.contentSignature(includeMeasurements: includeMeasurements),
      );

  String shotTime() {
    final dateFormat = DateFormat.yMd();
    final timeFormat = DateFormat('jm');
    return "${dateFormat.format(timestamp)}, ${timeFormat.format(timestamp)}";
  }

  ShotRecord copyWith({
    String? id,
    DateTime? timestamp,
    DateTime? createdAt,
    DateTime? updatedAt,
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
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
      measurements: measurements ?? this.measurements,
      workflow: workflow ?? this.workflow,
      annotations: annotations ?? this.annotations,
      stopReason: stopReason ?? this.stopReason,
      shotNotes: shotNotes ?? _shotNotes,
      metadata: metadata ?? _metadata,
    );
  }
}
