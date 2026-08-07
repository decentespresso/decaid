import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'package:reaprime/src/models/data/profile.dart';

/// Utilities for calculating content-based hashes for profiles
class ProfileHash {
  /// Calculate hash of execution-relevant fields
  ///
  /// This hash identifies the functional behavior of the profile.
  /// Fields included:
  /// - beverage_type
  /// - steps
  /// - tank_temperature
  /// - target_weight
  /// - target_volume
  /// - target_volume_count_start
  /// - legacy_profile_type
  /// - type
  /// - version
  static String calculateProfileHash(Profile profile) {
    final data = {
      'version': profile.version,
      'beverage_type': profile.beverageType.name,
      'steps': profile.steps.map((step) => step.toJson()).toList(),
      'tank_temperature': profile.tankTemperature,
      'target_weight': profile.targetWeight,
      'target_volume': profile.targetVolume,
      'target_volume_count_start': profile.targetVolumeCountStart,
      // legacy_profile_type and type don't exist in current Profile model
      // If they're added later, include them here
    };

    final jsonStr = _encodeJsonStable(data);

    final bytes = utf8.encode(jsonStr);
    final hash = sha256.convert(bytes);

    // Return first 20 characters prefixed with 'profile:'
    return 'profile:${hash.toString().substring(0, 20)}';
  }

  /// Calculate hash of metadata/presentation fields
  ///
  /// This hash identifies the human-readable aspects of the profile.
  /// Fields included:
  /// - title
  /// - author
  /// - notes
  static String calculateMetadataHash(Profile profile) {
    final data = {
      'title': profile.title,
      'author': profile.author,
      'notes': profile.notes,
    };

    final jsonStr = _encodeJsonStable(data);
    final bytes = utf8.encode(jsonStr);
    final hash = sha256.convert(bytes);

    return hash.toString();
  }

  /// Calculate compound hash (hash of profile hash + metadata hash)
  ///
  /// This detects any changes to the profile, whether functional or presentational.
  static String calculateCompoundHash(String profileHash, String metadataHash) {
    final combined = '$profileHash:$metadataHash';
    final bytes = utf8.encode(combined);
    final hash = sha256.convert(bytes);

    return hash.toString();
  }

  /// Calculate all three hashes at once
  static ProfileHashes calculateAll(Profile profile) {
    final profileHash = calculateProfileHash(profile);
    final metadataHash = calculateMetadataHash(profile);
    final compoundHash = calculateCompoundHash(profileHash, metadataHash);

    return ProfileHashes(
      profileHash: profileHash,
      metadataHash: metadataHash,
      compoundHash: compoundHash,
    );
  }

  /// Encode JSON with sorted keys for stable hashing
  static String _encodeJsonStable(Map<String, dynamic> data) {
    return jsonEncode(_sortMapKeys(data));
  }

  /// Recursively sort map keys for stable serialization
  static dynamic _sortMapKeys(dynamic value) {
    if (value is Map) {
      final sortedMap = <String, dynamic>{};
      final sortedKeys = value.keys.toList()..sort();
      for (final key in sortedKeys) {
        sortedMap[key.toString()] = _sortMapKeys(value[key]);
      }
      return sortedMap;
    } else if (value is List) {
      return value.map(_sortMapKeys).toList();
    }
    return value;
  }
}

/// Container for all three hash values
class ProfileHashes {
  final String profileHash;
  final String metadataHash;
  final String compoundHash;

  const ProfileHashes({
    required this.profileHash,
    required this.metadataHash,
    required this.compoundHash,
  });

  @override
  String toString() {
    return 'ProfileHashes(profile: $profileHash, metadata: $metadataHash, compound: $compoundHash)';
  }
}
