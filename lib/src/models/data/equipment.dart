import 'package:reaprime/src/models/data/utils.dart';
import 'package:uuid/uuid.dart';

enum EquipmentType {
  basket,
  portafilter,
  dripper,
  other;

  static EquipmentType fromString(String s) {
    return EquipmentType.values.firstWhere(
      (e) => e.name == s,
      orElse: () => EquipmentType.other,
    );
  }
}

class Equipment {
  final String id;
  final EquipmentType type;
  final String name;
  final String? style;
  final double? diameterMm;
  final String? notes;
  final bool archived;
  final List<String>? tools;

  final DateTime createdAt;
  final DateTime updatedAt;
  final Map<String, dynamic>? extras;

  const Equipment({
    required this.id,
    required this.type,
    required this.name,
    this.style,
    this.diameterMm,
    this.notes,
    this.archived = false,
    this.tools,
    required this.createdAt,
    required this.updatedAt,
    this.extras,
  });

  factory Equipment.create({
    required EquipmentType type,
    required String name,
    String? style,
    double? diameterMm,
    String? notes,
    List<String>? tools,
    Map<String, dynamic>? extras,
  }) {
    final now = DateTime.now();
    return Equipment(
      id: const Uuid().v4(),
      type: type,
      name: name,
      style: style,
      diameterMm: diameterMm,
      notes: notes,
      tools: tools,
      createdAt: now,
      updatedAt: now,
      extras: extras,
    );
  }

  factory Equipment.fromJson(Map<String, dynamic> json) {
    return Equipment(
      id: json['id'] as String,
      type: json['type'] != null
          ? EquipmentType.fromString(json['type'] as String)
          : EquipmentType.other,
      name: json['name'] as String,
      style: json['style'] as String?,
      diameterMm: parseOptionalDouble(json['diameterMm']),
      notes: json['notes'] as String?,
      archived: json['archived'] as bool? ?? false,
      tools: (json['tools'] as List?)?.cast<String>(),
      createdAt: DateTime.parse(json['createdAt'] as String),
      updatedAt: DateTime.parse(json['updatedAt'] as String),
      extras: json['extras'] as Map<String, dynamic>?,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'type': type.name,
      'name': name,
      if (style != null) 'style': style,
      if (diameterMm != null) 'diameterMm': diameterMm,
      if (notes != null) 'notes': notes,
      'archived': archived,
      if (tools != null) 'tools': tools,
      'createdAt': createdAt.toIso8601String(),
      'updatedAt': updatedAt.toIso8601String(),
      if (extras != null) 'extras': extras,
    };
  }

  Equipment copyWith({
    EquipmentType? type,
    String? name,
    String? style,
    double? diameterMm,
    String? notes,
    bool? archived,
    List<String>? tools,
    Map<String, dynamic>? extras,
  }) {
    return Equipment(
      id: id,
      type: type ?? this.type,
      name: name ?? this.name,
      style: style ?? this.style,
      diameterMm: diameterMm ?? this.diameterMm,
      notes: notes ?? this.notes,
      archived: archived ?? this.archived,
      tools: tools ?? this.tools,
      createdAt: createdAt,
      updatedAt: DateTime.now(),
      extras: extras ?? this.extras,
    );
  }

  @override
  String toString() => 'Equipment(${type.name}, $name, id: $id)';
}
