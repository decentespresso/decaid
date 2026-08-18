import 'package:equatable/equatable.dart';
import 'package:flutter/widgets.dart';
import 'package:reaprime/src/models/data/profile.dart';
import 'package:reaprime/src/models/data/profile_hash.dart';

enum Visibility { visible, hidden, deleted }

extension VisibilityExtension on Visibility {
  String get name {
    switch (this) {
      case Visibility.visible:
        return 'visible';
      case Visibility.hidden:
        return 'hidden';
      case Visibility.deleted:
        return 'deleted';
    }
  }

  static Visibility fromString(String value) {
    switch (value.toLowerCase()) {
      case 'visible':
        return Visibility.visible;
      case 'hidden':
        return Visibility.hidden;
      case 'deleted':
        return Visibility.deleted;
      default:
        throw ArgumentError('Invalid visibility value: $value');
    }
  }
}

@immutable
class ProfileRecord extends Equatable {
  final String id;

  final Profile profile;

  final String metadataHash;

  final String compoundHash;

  final String? parentId;

  final Visibility visibility;

  final bool isDefault;

  final DateTime createdAt;

  final DateTime updatedAt;

  final Map<String, dynamic>? metadata;

  const ProfileRecord({
    required this.id,
    required this.profile,
    required this.metadataHash,
    required this.compoundHash,
    this.parentId,
    this.visibility = Visibility.visible,
    this.isDefault = false,
    required this.createdAt,
    required this.updatedAt,
    this.metadata,
  });

  factory ProfileRecord.create({
    required Profile profile,
    String? parentId,
    bool isDefault = false,
    Map<String, dynamic>? metadata,
  }) {
    final now = DateTime.now();
    final hashes = ProfileHash.calculateAll(profile);

    return ProfileRecord(
      id: hashes.profileHash,
      profile: profile,
      metadataHash: hashes.metadataHash,
      compoundHash: hashes.compoundHash,
      parentId: parentId,
      visibility: Visibility.visible,
      isDefault: isDefault,
      createdAt: now,
      updatedAt: now,
      metadata: metadata,
    );
  }

  ProfileRecord copyWith({
    String? id,
    Profile? profile,
    String? metadataHash,
    String? compoundHash,
    String? parentId,
    Visibility? visibility,
    bool? isDefault,
    DateTime? createdAt,
    DateTime? updatedAt,
    Map<String, dynamic>? metadata,
    bool clearMetadata = false,
  }) {
    final newProfile = profile ?? this.profile;
    final hashes = ProfileHash.calculateAll(newProfile);

    return ProfileRecord(
      id: id ?? hashes.profileHash,
      profile: newProfile,
      metadataHash: metadataHash ?? hashes.metadataHash,
      compoundHash: compoundHash ?? hashes.compoundHash,
      parentId: parentId ?? this.parentId,
      visibility: visibility ?? this.visibility,
      isDefault: isDefault ?? this.isDefault,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? DateTime.now(),
      metadata: clearMetadata ? null : metadata ?? this.metadata,
    );
  }

  @override
  List<Object?> get props => [
    id,
    profile,
    metadataHash,
    compoundHash,
    parentId,
    visibility,
    isDefault,
    createdAt,
    updatedAt,
    metadata,
  ];

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'profile': profile.toJson(),
      'metadataHash': metadataHash,
      'compoundHash': compoundHash,
      'parentId': parentId,
      'visibility': visibility.name,
      'isDefault': isDefault,
      'createdAt': createdAt.toIso8601String(),
      'updatedAt': updatedAt.toIso8601String(),
      'metadata': metadata,
    };
  }

  factory ProfileRecord.fromJson(Map<String, dynamic> json) {
    return ProfileRecord(
      id: json['id'] as String,
      profile: Profile.fromJson(json['profile'] as Map<String, dynamic>),
      metadataHash: json['metadataHash'] as String,
      compoundHash: json['compoundHash'] as String,
      parentId: json['parentId'] as String?,
      visibility: VisibilityExtension.fromString(json['visibility'] as String),
      isDefault: json['isDefault'] as bool,
      createdAt: DateTime.parse(json['createdAt'] as String),
      updatedAt: DateTime.parse(json['updatedAt'] as String),
      metadata: json['metadata'] as Map<String, dynamic>?,
    );
  }
}
