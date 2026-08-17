import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/models/data/profile.dart';
import 'package:reaprime/src/models/data/profile_hash.dart';
import 'package:reaprime/src/models/data/profile_record.dart';
import 'package:reaprime/src/services/storage/profile_storage_service.dart';
import 'package:hive_ce/hive.dart';

class MockProfileStorage implements ProfileStorageService {
  final Map<String, ProfileRecord> _storage = {};

  @override
  Future<void> initialize() async {}

  @override
  Future<void> store(ProfileRecord record) async {
    _storage[record.id] = record;
  }

  @override
  Future<ProfileRecord?> get(String id) async {
    return _storage[id];
  }

  @override
  Future<List<ProfileRecord>> getAll({Visibility? visibility}) async {
    if (visibility == null) {
      return _storage.values.toList();
    }
    return _storage.values
        .where((record) => record.visibility == visibility)
        .toList();
  }

  @override
  Future<void> update(ProfileRecord record) async {
    if (!_storage.containsKey(record.id)) {
      throw Exception('Profile not found');
    }
    _storage[record.id] = record;
  }

  @override
  Future<void> replace(String oldId, ProfileRecord replacement) async {
    _storage[replacement.id] = replacement;
    _storage.remove(oldId);
  }

  @override
  Future<void> delete(String id) async {
    _storage.remove(id);
  }

  @override
  Future<bool> exists(String id) async {
    return _storage.containsKey(id);
  }

  @override
  Future<List<String>> getAllIds() async {
    return _storage.keys.toList();
  }

  @override
  Future<List<ProfileRecord>> getByParentId(String parentId) async {
    return _storage.values
        .where((record) => record.parentId == parentId)
        .toList();
  }

  @override
  Future<void> storeAll(List<ProfileRecord> records) async {
    for (final record in records) {
      _storage[record.id] = record;
    }
  }

  @override
  Future<void> clear() async {
    _storage.clear();
  }

  @override
  Future<int> count({Visibility? visibility}) async {
    if (visibility == null) {
      return _storage.length;
    }
    return _storage.values
        .where((record) => record.visibility == visibility)
        .length;
  }

  void reset() {
    _storage.clear();
  }
}

ProfileStep _sampleStep() => ProfileStepPressure(
  name: 'pour',
  transition: TransitionType.fast,
  volume: 100,
  seconds: 30,
  temperature: 93,
  sensor: TemperatureSensor.coffee,
  pressure: 9,
);

void main() {
  setUpAll(() async {
    Hive.init(null);
  });

  group('ProfileHash', () {
    test('calculates consistent profile hash from execution fields', () {
      final profile1 = Profile(
        version: '2',
        title: 'Test Profile',
        author: 'Author 1',
        notes: 'Some notes',
        beverageType: BeverageType.espresso,
        steps: [],
        tankTemperature: 93.0,
        targetWeight: 36.0,
        targetVolumeCountStart: 0,
      );

      final profile2 = Profile(
        version: '2',
        title: 'Different Title',
        author: 'Author 2',
        notes: 'Different notes',
        beverageType: BeverageType.espresso,
        steps: [],
        tankTemperature: 93.0,
        targetWeight: 36.0,
        targetVolumeCountStart: 0,
      );

      final hash1 = ProfileHash.calculateProfileHash(profile1);
      final hash2 = ProfileHash.calculateProfileHash(profile2);

      expect(hash1, equals(hash2));
      expect(hash1.startsWith('profile:'), isTrue);
      expect(hash1.length, equals(28));
    });

    test('different execution fields produce different profile hashes', () {
      final profile1 = Profile(
        version: '2',
        title: 'Test',
        author: 'Test',
        notes: '',
        beverageType: BeverageType.espresso,
        steps: [],
        tankTemperature: 93.0,
        targetVolumeCountStart: 0,
      );

      final profile2 = Profile(
        version: '2',
        title: 'Test',
        author: 'Test',
        notes: '',
        beverageType: BeverageType.espresso,
        steps: [],
        tankTemperature: 94.0,
        targetVolumeCountStart: 0,
      );

      final hash1 = ProfileHash.calculateProfileHash(profile1);
      final hash2 = ProfileHash.calculateProfileHash(profile2);

      expect(hash1, isNot(equals(hash2)));
    });

    test('calculates different metadata hashes for different metadata', () {
      final profile1 = Profile(
        version: '2',
        title: 'Title 1',
        author: 'Author 1',
        notes: 'Notes 1',
        beverageType: BeverageType.espresso,
        steps: [],
        tankTemperature: 93.0,
        targetVolumeCountStart: 0,
      );

      final profile2 = Profile(
        version: '2',
        title: 'Title 2',
        author: 'Author 2',
        notes: 'Notes 2',
        beverageType: BeverageType.espresso,
        steps: [],
        tankTemperature: 93.0,
        targetVolumeCountStart: 0,
      );

      final hash1 = ProfileHash.calculateMetadataHash(profile1);
      final hash2 = ProfileHash.calculateMetadataHash(profile2);

      expect(hash1, isNot(equals(hash2)));
    });

    test('calculateAll returns all three hashes', () {
      final profile = Profile(
        version: '2',
        title: 'Test Profile',
        author: 'Test Author',
        notes: 'Test notes',
        beverageType: BeverageType.espresso,
        steps: [],
        tankTemperature: 93.0,
        targetVolumeCountStart: 0,
      );

      final hashes = ProfileHash.calculateAll(profile);

      expect(hashes.profileHash.startsWith('profile:'), isTrue);
      expect(hashes.metadataHash, isNotEmpty);
      expect(hashes.compoundHash, isNotEmpty);
      expect(hashes.profileHash.length, equals(28));
      expect(hashes.metadataHash.length, equals(64));
      expect(hashes.compoundHash.length, equals(64));
    });
  });

  group('ProfileRecord with Hashes', () {
    test('creates ProfileRecord with hash-based ID', () {
      final profile = Profile(
        version: '2',
        title: 'Test Profile',
        author: 'Test Author',
        notes: 'Test notes',
        beverageType: BeverageType.espresso,
        steps: [],
        tankTemperature: 93.0,
        targetWeight: 36.0,
        targetVolumeCountStart: 0,
      );

      final record = ProfileRecord.create(profile: profile, isDefault: false);

      expect(record.id.startsWith('profile:'), isTrue);
      expect(record.id.length, equals(28));
      expect(record.metadataHash, isNotEmpty);
      expect(record.compoundHash, isNotEmpty);
      expect(record.profile, equals(profile));
      expect(record.parentId, isNull);
      expect(record.visibility, equals(Visibility.visible));
      expect(record.isDefault, isFalse);
    });

    test('identical profiles produce identical IDs', () {
      final profile1 = Profile(
        version: '2',
        title: 'Test',
        author: 'Author',
        notes: 'Notes',
        beverageType: BeverageType.espresso,
        steps: [],
        tankTemperature: 93.0,
        targetVolumeCountStart: 0,
      );

      final profile2 = Profile(
        version: '2',
        title: 'Test',
        author: 'Author',
        notes: 'Notes',
        beverageType: BeverageType.espresso,
        steps: [],
        tankTemperature: 93.0,
        targetVolumeCountStart: 0,
      );

      final record1 = ProfileRecord.create(profile: profile1, isDefault: false);
      final record2 = ProfileRecord.create(profile: profile2, isDefault: false);

      expect(record1.id, equals(record2.id));
      expect(record1.metadataHash, equals(record2.metadataHash));
      expect(record1.compoundHash, equals(record2.compoundHash));
    });

    test('same execution different metadata produces same profile ID', () {
      final profile1 = Profile(
        version: '2',
        title: 'Original Title',
        author: 'Author 1',
        notes: 'Notes 1',
        beverageType: BeverageType.espresso,
        steps: [],
        tankTemperature: 93.0,
        targetVolumeCountStart: 0,
      );

      final profile2 = Profile(
        version: '2',
        title: 'Changed Title',
        author: 'Author 2',
        notes: 'Notes 2',
        beverageType: BeverageType.espresso,
        steps: [],
        tankTemperature: 93.0,
        targetVolumeCountStart: 0,
      );

      final record1 = ProfileRecord.create(profile: profile1, isDefault: false);
      final record2 = ProfileRecord.create(profile: profile2, isDefault: false);

      expect(record1.id, equals(record2.id));

      expect(record1.metadataHash, isNot(equals(record2.metadataHash)));

      expect(record1.compoundHash, isNot(equals(record2.compoundHash)));
    });

    test('serializes to and from JSON correctly', () {
      final profile = Profile(
        version: '2',
        title: 'JSON Test Profile',
        author: 'Test Author',
        notes: 'Testing JSON serialization',
        beverageType: BeverageType.espresso,
        steps: [_sampleStep()],
        tankTemperature: 93.0,
        targetVolumeCountStart: 0,
      );

      final original = ProfileRecord.create(
        profile: profile,
        isDefault: true,
        metadata: {'test': 'value'},
      );

      final json = original.toJson();
      final deserialized = ProfileRecord.fromJson(json);

      expect(deserialized.id, equals(original.id));
      expect(deserialized.metadataHash, equals(original.metadataHash));
      expect(deserialized.compoundHash, equals(original.compoundHash));
      expect(deserialized.profile.title, equals(original.profile.title));
      expect(deserialized.visibility, equals(original.visibility));
      expect(deserialized.isDefault, equals(original.isDefault));
      expect(deserialized.metadata?['test'], equals('value'));
    });

    test('copyWith recalculates hashes when profile changes', () {
      final profile = Profile(
        version: '2',
        title: 'Original',
        author: 'Test',
        notes: '',
        beverageType: BeverageType.espresso,
        steps: [],
        tankTemperature: 93.0,
        targetVolumeCountStart: 0,
      );

      final original = ProfileRecord.create(profile: profile, isDefault: false);

      final updatedProfile = profile.copyWith(tankTemperature: 94.0);
      final updated = original.copyWith(profile: updatedProfile);

      expect(updated.id, isNot(equals(original.id)));

      expect(updated.metadataHash, equals(original.metadataHash));

      expect(updated.compoundHash, isNot(equals(original.compoundHash)));
    });
  });

  group('MockProfileStorage', () {
    late MockProfileStorage storage;

    setUp(() {
      storage = MockProfileStorage();
    });

    tearDown(() {
      storage.reset();
    });

    test('stores and retrieves profile by hash ID', () async {
      final profile = Profile(
        version: '2',
        title: 'Test Profile',
        author: 'Test',
        notes: '',
        beverageType: BeverageType.espresso,
        steps: [],
        tankTemperature: 93.0,
        targetVolumeCountStart: 0,
      );

      final record = ProfileRecord.create(profile: profile, isDefault: false);

      await storage.store(record);
      final retrieved = await storage.get(record.id);

      expect(retrieved, isNotNull);
      expect(retrieved!.id, equals(record.id));
      expect(retrieved.profile.title, equals('Test Profile'));
    });

    test('automatic deduplication with hash-based IDs', () async {
      final profile = Profile(
        version: '2',
        title: 'Test',
        author: 'Test',
        notes: '',
        beverageType: BeverageType.espresso,
        steps: [],
        tankTemperature: 93.0,
        targetVolumeCountStart: 0,
      );

      final record1 = ProfileRecord.create(profile: profile, isDefault: false);
      final record2 = ProfileRecord.create(profile: profile, isDefault: false);

      expect(record1.id, equals(record2.id));

      await storage.store(record1);

      await storage.store(record2);

      final count = await storage.count();
      expect(count, equals(1));
    });

    test('filters by visibility', () async {
      final profiles = [
        ProfileRecord.create(
          profile: Profile(
            version: '2',
            title: 'Visible',
            author: 'Test',
            notes: '',
            beverageType: BeverageType.espresso,
            steps: [],
            tankTemperature: 93.0,
            targetVolumeCountStart: 0,
          ),
          isDefault: false,
        ),
        ProfileRecord.create(
          profile: Profile(
            version: '2',
            title: 'Hidden',
            author: 'Test',
            notes: '',
            beverageType: BeverageType.espresso,
            steps: [],
            tankTemperature: 94.0,
            targetVolumeCountStart: 0,
          ),
          isDefault: false,
        ).copyWith(visibility: Visibility.hidden),
      ];

      for (final profile in profiles) {
        await storage.store(profile);
      }

      final visible = await storage.getAll(visibility: Visibility.visible);
      final hidden = await storage.getAll(visibility: Visibility.hidden);

      expect(visible.length, equals(1));
      expect(hidden.length, equals(1));
      expect(visible.first.profile.title, equals('Visible'));
      expect(hidden.first.profile.title, equals('Hidden'));
    });
  });

  group('Profile Versioning with Hashes', () {
    late MockProfileStorage storage;

    setUp(() {
      storage = MockProfileStorage();
    });

    tearDown(() {
      storage.reset();
    });

    test('creates version tree with parent ID references', () async {
      final parentProfile = Profile(
        version: '2',
        title: 'Original',
        author: 'Test',
        notes: '',
        beverageType: BeverageType.espresso,
        steps: [],
        tankTemperature: 93.0,
        targetVolumeCountStart: 0,
      );

      final parent = ProfileRecord.create(
        profile: parentProfile,
        isDefault: false,
      );

      await storage.store(parent);

      final childProfile = parentProfile.copyWith(tankTemperature: 94.0);
      final child = ProfileRecord.create(
        profile: childProfile,
        parentId: parent.id,
        isDefault: false,
      );

      await storage.store(child);

      expect(child.id, isNot(equals(parent.id)));
      expect(child.parentId, equals(parent.id));

      final children = await storage.getByParentId(parent.id);
      expect(children.length, equals(1));
      expect(children.first.id, equals(child.id));
    });
  });

  group('Default Profile Protection', () {
    late MockProfileStorage storage;

    setUp(() {
      storage = MockProfileStorage();
    });

    tearDown(() {
      storage.reset();
    });

    test('default profiles have isDefault flag', () {
      final profile = Profile(
        version: '2',
        title: 'Default Profile',
        author: 'REA',
        notes: '',
        beverageType: BeverageType.espresso,
        steps: [],
        tankTemperature: 93.0,
        targetVolumeCountStart: 0,
      );

      final record = ProfileRecord.create(profile: profile, isDefault: true);

      expect(record.isDefault, isTrue);
      expect(record.id.startsWith('profile:'), isTrue);
    });

    test('default profiles can be hidden but not deleted', () async {
      final profile = Profile(
        version: '2',
        title: 'Default Profile',
        author: 'REA',
        notes: '',
        beverageType: BeverageType.espresso,
        steps: [],
        tankTemperature: 93.0,
        targetVolumeCountStart: 0,
      );

      final record = ProfileRecord.create(profile: profile, isDefault: true);

      await storage.store(record);

      final hiddenRecord = record.copyWith(visibility: Visibility.hidden);
      await storage.update(hiddenRecord);

      final retrieved = await storage.get(record.id);
      expect(retrieved!.visibility, equals(Visibility.hidden));
      expect(retrieved.isDefault, isTrue);
    });
  });

  group('Hash Update Mechanics', () {
    test('updating metadata only keeps same profile ID', () {
      final profile = Profile(
        version: '2',
        title: 'Original Title',
        author: 'Original Author',
        notes: 'Original notes',
        beverageType: BeverageType.espresso,
        steps: [],
        tankTemperature: 93.0,
        targetVolumeCountStart: 0,
      );

      final original = ProfileRecord.create(profile: profile, isDefault: false);

      final updatedProfile = profile.copyWith(
        title: 'New Title',
        author: 'New Author',
        notes: 'New notes',
      );

      final updated = original.copyWith(profile: updatedProfile);

      expect(updated.id, equals(original.id));

      expect(updated.metadataHash, isNot(equals(original.metadataHash)));

      expect(updated.compoundHash, isNot(equals(original.compoundHash)));
    });

    test('updating execution fields changes profile ID', () {
      final profile = Profile(
        version: '2',
        title: 'Test',
        author: 'Test',
        notes: '',
        beverageType: BeverageType.espresso,
        steps: [],
        tankTemperature: 93.0,
        targetVolumeCountStart: 0,
      );

      final original = ProfileRecord.create(profile: profile, isDefault: false);

      final updatedProfile = profile.copyWith(tankTemperature: 94.0);
      final updated = original.copyWith(profile: updatedProfile);

      expect(updated.id, isNot(equals(original.id)));

      expect(updated.metadataHash, equals(original.metadataHash));

      expect(updated.compoundHash, isNot(equals(original.compoundHash)));
    });

    test('updating both metadata and execution changes all hashes', () {
      final profile = Profile(
        version: '2',
        title: 'Original',
        author: 'Test',
        notes: '',
        beverageType: BeverageType.espresso,
        steps: [],
        tankTemperature: 93.0,
        targetVolumeCountStart: 0,
      );

      final original = ProfileRecord.create(profile: profile, isDefault: false);

      final updatedProfile = profile.copyWith(
        title: 'Updated',
        tankTemperature: 94.0,
      );
      final updated = original.copyWith(profile: updatedProfile);

      expect(updated.id, isNot(equals(original.id)));
      expect(updated.metadataHash, isNot(equals(original.metadataHash)));
      expect(updated.compoundHash, isNot(equals(original.compoundHash)));
    });

    test('identical profiles from different sources have same ID', () {
      final profile1 = Profile(
        version: '2',
        title: 'User A Version',
        author: 'Alice',
        notes: 'Created by Alice',
        beverageType: BeverageType.espresso,
        steps: [],
        tankTemperature: 93.0,
        targetVolumeCountStart: 0,
      );

      final profile2 = Profile(
        version: '2',
        title: 'User B Version',
        author: 'Bob',
        notes: 'Created by Bob',
        beverageType: BeverageType.espresso,
        steps: [],
        tankTemperature: 93.0,
        targetVolumeCountStart: 0,
      );

      final record1 = ProfileRecord.create(profile: profile1, isDefault: false);
      final record2 = ProfileRecord.create(profile: profile2, isDefault: false);

      expect(record1.id, equals(record2.id));

      expect(record1.metadataHash, isNot(equals(record2.metadataHash)));
      expect(record1.compoundHash, isNot(equals(record2.compoundHash)));
    });

    test('hash remains stable across serialization', () {
      final profile = Profile(
        version: '2',
        title: 'Test Profile',
        author: 'Test',
        notes: '',
        beverageType: BeverageType.espresso,
        steps: [_sampleStep()],
        tankTemperature: 93.0,
        targetVolumeCountStart: 0,
      );

      final original = ProfileRecord.create(profile: profile, isDefault: false);

      final json = original.toJson();
      final deserialized = ProfileRecord.fromJson(json);

      expect(deserialized.id, equals(original.id));
      expect(deserialized.metadataHash, equals(original.metadataHash));
      expect(deserialized.compoundHash, equals(original.compoundHash));
    });

    test('changing beverage type changes profile hash', () {
      final profile1 = Profile(
        version: '2',
        title: 'Test',
        author: 'Test',
        notes: '',
        beverageType: BeverageType.espresso,
        steps: [],
        tankTemperature: 93.0,
        targetVolumeCountStart: 0,
      );

      final profile2 = Profile(
        version: '2',
        title: 'Test',
        author: 'Test',
        notes: '',
        beverageType: BeverageType.pourover,
        steps: [],
        tankTemperature: 93.0,
        targetVolumeCountStart: 0,
      );

      final record1 = ProfileRecord.create(profile: profile1, isDefault: false);
      final record2 = ProfileRecord.create(profile: profile2, isDefault: false);

      expect(record1.id, isNot(equals(record2.id)));
    });
  });

  group('Profile.fromJson field tolerance', () {
    Map<String, dynamic> validJson() => {
      'version': '2',
      'title': 'Test',
      'notes': 'Some notes',
      'author': 'Someone',
      'beverage_type': 'espresso',
      'steps': <dynamic>[
        {
          'name': 'pour',
          'pump': 'pressure',
          'transition': 'fast',
          'volume': 100,
          'seconds': 30,
          'temperature': 93,
          'sensor': 'coffee',
          'pressure': 9,
        },
      ],
      'tank_temperature': 93.0,
      'target_volume_count_start': 0,
    };

    test('defaults notes and author to empty string when missing', () {
      final json = validJson()
        ..remove('notes')
        ..remove('author');

      final profile = Profile.fromJson(json);

      expect(profile.notes, equals(''));
      expect(profile.author, equals(''));
      expect(profile.title, equals('Test'));
    });

    test('defaults notes and author to empty string when null', () {
      final json = validJson()
        ..['notes'] = null
        ..['author'] = null;

      final profile = Profile.fromJson(json);

      expect(profile.notes, equals(''));
      expect(profile.author, equals(''));
    });

    test('preserves provided notes, author, title and version', () {
      final profile = Profile.fromJson(validJson());

      expect(profile.version, equals('2'));
      expect(profile.title, equals('Test'));
      expect(profile.notes, equals('Some notes'));
      expect(profile.author, equals('Someone'));
    });

    test('tolerates a missing version', () {
      final json = validJson()..remove('version');

      final profile = Profile.fromJson(json);

      expect(profile.version, isNull);
    });

    test('throws ArgumentError when title is missing', () {
      final json = validJson()..remove('title');

      expect(() => Profile.fromJson(json), throwsArgumentError);
    });

    test('throws ArgumentError when title is null', () {
      final json = validJson()..['title'] = null;

      expect(() => Profile.fromJson(json), throwsArgumentError);
    });

    test('throws ArgumentError when title is empty', () {
      final json = validJson()..['title'] = '';

      expect(() => Profile.fromJson(json), throwsArgumentError);
    });

    test('throws ArgumentError when steps is missing', () {
      final json = validJson()..remove('steps');

      expect(() => Profile.fromJson(json), throwsArgumentError);
    });

    test('throws ArgumentError when steps is not a list', () {
      final json = validJson()..['steps'] = 'not-a-list';

      expect(() => Profile.fromJson(json), throwsArgumentError);
    });

    test('throws ArgumentError when steps is empty', () {
      final json = validJson()..['steps'] = <dynamic>[];

      expect(() => Profile.fromJson(json), throwsArgumentError);
    });

    test('parses a non-empty steps array', () {
      final profile = Profile.fromJson(validJson());

      expect(profile.steps, hasLength(1));
      expect(profile.steps.first.name, equals('pour'));
    });

    test('throws ArgumentError when tank_temperature is missing', () {
      final json = validJson()..remove('tank_temperature');

      expect(() => Profile.fromJson(json), throwsArgumentError);
    });

    test('throws ArgumentError when target_volume_count_start is missing', () {
      final json = validJson()..remove('target_volume_count_start');

      expect(() => Profile.fromJson(json), throwsArgumentError);
    });
  });
}
