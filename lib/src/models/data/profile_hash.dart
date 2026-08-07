import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'package:reaprime/src/models/data/profile.dart';

class ProfileHash {
  static String calculateProfileHash(Profile profile) {
    final data = {
      'version': profile.version,
      'beverage_type': profile.beverageType.name,
      'steps': profile.steps.map((step) => step.toJson()).toList(),
      'tank_temperature': profile.tankTemperature,
      'target_weight': profile.targetWeight,
      'target_volume': profile.targetVolume,
      'target_volume_count_start': profile.targetVolumeCountStart,
    };

    final jsonStr = _encodeJsonStable(data);

    final bytes = utf8.encode(jsonStr);
    final hash = sha256.convert(bytes);

    return 'profile:${hash.toString().substring(0, 20)}';
  }

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

  static String calculateCompoundHash(String profileHash, String metadataHash) {
    final combined = '$profileHash:$metadataHash';
    final bytes = utf8.encode(combined);
    final hash = sha256.convert(bytes);

    return hash.toString();
  }

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

  static String _encodeJsonStable(Map<String, dynamic> data) {
    return jsonEncode(_sortMapKeys(data));
  }

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
