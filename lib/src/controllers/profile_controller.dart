import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:logging/logging.dart';
import 'package:reaprime/src/models/data/profile.dart';
import 'package:reaprime/src/models/data/profile_record.dart';
import 'package:reaprime/src/services/storage/profile_storage_service.dart';
import 'package:rxdart/rxdart.dart';

class ProfileController {
  final ProfileStorageService _storage;
  final Logger _log = Logger('ProfileController');

  final BehaviorSubject<int> _profileCountStream = BehaviorSubject.seeded(0);
  Stream<int> get profileCount => _profileCountStream.stream;

  ProfileController({required ProfileStorageService storage})
    : _storage = storage;

  Future<void> initialize() async {
    _log.info('Initializing ProfileController');
    await _storage.initialize();
    await _loadDefaultProfilesIfNeeded();
    await _updateProfileCount();
    _log.info('ProfileController initialized');
  }

  Future<void> _loadDefaultProfilesIfNeeded() async {
    try {
      final manifestData = await rootBundle.loadString(
        'assets/defaultProfiles/manifest.json',
      );
      final manifest = jsonDecode(manifestData) as Map<String, dynamic>;
      final profileFiles = manifest['profiles'] as List<dynamic>;

      int loaded = 0;
      int skipped = 0;
      int refreshed = 0;

      final currentFilenames = profileFiles.cast<String>().toSet();
      final currentIdByFilename = <String, String>{};

      for (final filename in profileFiles) {
        try {
          final profileData = await rootBundle.loadString(
            'assets/defaultProfiles/$filename',
          );
          final profileJson = jsonDecode(profileData) as Map<String, dynamic>;
          final profile = Profile.fromJson(profileJson);

          final record = ProfileRecord.create(
            profile: profile,
            isDefault: true,
            metadata: {'source': 'bundled', 'filename': filename},
          );
          currentIdByFilename[filename] = record.id;

          final existing = await _storage.get(record.id);
          if (existing != null) {
            final needsMetadataRefresh =
                existing.metadataHash != record.metadataHash;
            if (!existing.isDefault || needsMetadataRefresh) {
              await _storage.update(
                existing.copyWith(
                  profile: profile,
                  isDefault: true,
                  metadata: {'source': 'bundled', 'filename': filename},
                ),
              );
              if (needsMetadataRefresh) {
                refreshed++;
                _log.fine(
                  'Refreshed default profile metadata: ${record.id} (${profile.title})',
                );
              }
            }
            skipped++;
            continue;
          }

          await _storage.store(record);
          loaded++;
          _log.fine('Loaded default profile: ${record.id} (${profile.title})');
        } catch (e) {
          _log.warning('Failed to load default profile: $filename', e);
        }
      }

      await _retireStaleDefaults(currentFilenames, currentIdByFilename);

      _log.info(
        'Default profiles: $loaded new, $refreshed refreshed, '
        '$skipped existing (${profileFiles.length} total)',
      );
    } catch (e) {
      _log.warning(
        'Failed to load default profiles (this is okay if manifest doesn\'t exist yet)',
        e,
      );
    }
  }

  Future<void> _retireStaleDefaults(
    Set<String> currentFilenames,
    Map<String, String> currentIdByFilename,
  ) async {
    int retired = 0;
    for (final record in await _storage.getAll()) {
      if (!record.isDefault || record.visibility != Visibility.visible) {
        continue;
      }
      final filename = record.metadata?['filename'];
      if (filename is! String) continue;
      final removed = !currentFilenames.contains(filename);
      final staleVersion =
          !removed && currentIdByFilename[filename] != record.id;
      if (removed || staleVersion) {
        await _storage.update(record.copyWith(visibility: Visibility.hidden));
        retired++;
        _log.info(
          'Retired stale default: ${record.id} '
          '($filename / ${record.profile.title})',
        );
      }
    }
    if (retired > 0) _log.info('Retired $retired stale default profile(s)');
  }

  Future<List<Map<String, dynamic>>> listDefaults() async {
    try {
      final manifestData = await rootBundle.loadString(
        'assets/defaultProfiles/manifest.json',
      );
      final manifest = jsonDecode(manifestData) as Map<String, dynamic>;
      final profileFiles = manifest['profiles'] as List<dynamic>;

      final defaults = <Map<String, dynamic>>[];
      for (final filename in profileFiles) {
        try {
          final profileData = await rootBundle.loadString(
            'assets/defaultProfiles/$filename',
          );
          final profileJson = jsonDecode(profileData) as Map<String, dynamic>;
          final profile = Profile.fromJson(profileJson);
          defaults.add({
            'filename': filename,
            'title': profile.title,
            'author': profile.author,
            'notes': profile.notes,
            'beverageType': profile.beverageType.name,
          });
        } catch (e) {
          _log.warning('Failed to parse default profile: $filename', e);
        }
      }
      return defaults;
    } catch (e) {
      _log.warning('Failed to load default profiles manifest', e);
      return [];
    }
  }

  Future<void> _updateProfileCount() async {
    final count = await _storage.count(visibility: Visibility.visible);
    _profileCountStream.add(count);
  }

  Future<List<ProfileRecord>> getAll({
    Visibility? visibility,
    bool includeHidden = false,
  }) async {
    if (includeHidden) {
      return await _storage.getAll();
    }
    return await _storage.getAll(visibility: visibility ?? Visibility.visible);
  }

  Future<ProfileRecord?> get(String id) async {
    return await _storage.get(id);
  }

  Future<ProfileRecord> create({
    required Profile profile,
    String? parentId,
    Map<String, dynamic>? metadata,
  }) async {
    if (parentId != null) {
      final parent = await _storage.get(parentId);
      if (parent == null) {
        throw ArgumentError('Parent profile not found: $parentId');
      }
    }

    final record = ProfileRecord.create(
      profile: profile,
      parentId: parentId,
      metadata: metadata,
    );

    final existing = await _storage.get(record.id);
    if (existing != null) {
      _log.info(
        'Profile with hash ${record.id} already exists (${profile.title})',
      );
      return existing;
    }

    await _storage.store(record);
    await _updateProfileCount();
    _log.info('Created profile: ${record.id} (${profile.title})');

    return record;
  }

  Future<ProfileRecord> update(
    String id, {
    Profile? profile,
    Map<String, dynamic>? metadata,
  }) async {
    final existing = await _storage.get(id);
    if (existing == null) {
      throw ArgumentError('Profile not found: $id');
    }

    if (existing.isDefault && profile != null) {
      throw ArgumentError('Cannot modify default profile content');
    }

    final updated = existing.copyWith(profile: profile, metadata: metadata);

    if (updated.id != existing.id) {
      _log.warning(
        'Profile hash changed from ${existing.id} to ${updated.id}. '
        'This creates a new profile. Consider using parentId for versioning.',
      );

      await _storage.replace(existing.id, updated);
    } else {
      await _storage.update(updated);
    }

    _log.info('Updated profile: ${updated.id}');
    return updated;
  }

  Future<void> delete(String id) async {
    final existing = await _storage.get(id);
    if (existing == null) {
      throw ArgumentError('Profile not found: $id');
    }

    if (existing.isDefault) {
      final hidden = existing.copyWith(visibility: Visibility.hidden);
      await _storage.update(hidden);
      _log.info('Hid default profile: $id');
    } else {
      final deleted = existing.copyWith(visibility: Visibility.deleted);
      await _storage.update(deleted);
      _log.info('Soft-deleted user profile: $id');
    }

    await _updateProfileCount();
  }

  Future<void> purge(String id) async {
    final existing = await _storage.get(id);
    if (existing == null) {
      throw ArgumentError('Profile not found: $id');
    }

    if (existing.isDefault) {
      throw ArgumentError('Cannot purge default profiles');
    }

    await _storage.delete(id);
    await _updateProfileCount();
    _log.info('Purged profile: $id');
  }

  Future<ProfileRecord> setVisibility(String id, Visibility visibility) async {
    final existing = await _storage.get(id);
    if (existing == null) {
      throw ArgumentError('Profile not found: $id');
    }

    if (existing.isDefault && visibility == Visibility.deleted) {
      throw ArgumentError('Cannot delete default profiles, only hide them');
    }

    final updated = existing.copyWith(visibility: visibility);
    await _storage.update(updated);
    await _updateProfileCount();
    _log.info('Changed visibility of profile $id to ${visibility.name}');

    return updated;
  }

  Future<List<ProfileRecord>> getLineage(String id) async {
    final profile = await _storage.get(id);
    if (profile == null) {
      throw ArgumentError('Profile not found: $id');
    }

    final lineage = <ProfileRecord>[];

    var current = profile;
    lineage.add(current);
    while (current.parentId != null) {
      final parent = await _storage.get(current.parentId!);
      if (parent == null) break;
      lineage.insert(0, parent);
      current = parent;
    }

    Future<void> addChildren(String parentId) async {
      final children = await _storage.getByParentId(parentId);
      for (final child in children) {
        lineage.add(child);
        await addChildren(child.id);
      }
    }

    await addChildren(id);

    return lineage;
  }

  Future<List<String>> getAllIds() => _storage.getAllIds();

  Future<Map<String, dynamic>> importProfiles(
    List<Map<String, dynamic>> profilesJson,
  ) async {
    int imported = 0;
    int skipped = 0;
    int failed = 0;
    final errors = <String>[];

    for (final json in profilesJson) {
      try {
        final record = ProfileRecord.fromJson(json);

        final existing = await _storage.get(record.id);
        if (existing != null) {
          skipped++;
          continue;
        }

        await _storage.store(record);
        imported++;
      } catch (e) {
        failed++;
        errors.add('Failed to import profile: $e');
      }
    }

    await _updateProfileCount();
    _log.info(
      'Import complete: $imported imported, $skipped skipped, $failed failed',
    );

    return {
      'imported': imported,
      'skipped': skipped,
      'failed': failed,
      'errors': errors,
    };
  }

  Future<List<Map<String, dynamic>>> exportProfiles({
    bool includeHidden = false,
    bool includeDeleted = false,
  }) async {
    List<ProfileRecord> profiles;

    if (includeDeleted) {
      profiles = await _storage.getAll();
    } else if (includeHidden) {
      profiles = await _storage.getAll();
      profiles = profiles
          .where((p) => p.visibility != Visibility.deleted)
          .toList();
    } else {
      profiles = await _storage.getAll(visibility: Visibility.visible);
    }

    return profiles.map((p) => p.toJson()).toList();
  }

  Future<ProfileRecord> restoreDefault(String filename) async {
    try {
      final profileData = await rootBundle.loadString(
        'assets/defaultProfiles/$filename',
      );
      final profileJson = jsonDecode(profileData) as Map<String, dynamic>;
      final profile = Profile.fromJson(profileJson);

      final record = ProfileRecord.create(
        profile: profile,
        isDefault: true,
        metadata: {'source': 'bundled', 'filename': filename},
      );

      final existing = await _storage.get(record.id);
      if (existing != null) {
        final restored = existing.copyWith(visibility: Visibility.visible);
        await _storage.update(restored);
        _log.info('Restored visibility of default profile: ${record.id}');
        return restored;
      }

      await _storage.store(record);
      await _updateProfileCount();
      _log.info('Restored default profile from assets: ${record.id}');

      return record;
    } catch (e) {
      _log.severe('Failed to restore default profile: $filename', e);
      throw ArgumentError('Failed to restore default profile: $filename');
    }
  }

  void dispose() {
    _profileCountStream.close();
  }
}
