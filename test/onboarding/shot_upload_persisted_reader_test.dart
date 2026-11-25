import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/plugins/plugin_loader_service.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';

const _key = 'plugin.settings.shot-upload.reaplugin';

class _FailingReadStore extends SharedPreferencesStorePlatform {
  _FailingReadStore({required this.data});

  final Map<String, Object> data;
  bool failReads = true;

  @override
  Future<bool> clear() async => true;

  @override
  Future<Map<String, Object>> getAll() async {
    if (failReads) throw StateError('preferences unavailable');
    return Map<String, Object>.of(data);
  }

  @override
  Future<bool> remove(String key) async => true;

  @override
  Future<bool> setValue(String valueType, String key, Object value) async =>
      true;
}

void main() {
  setUp(() {
    SharedPreferences.resetStatic();
    SharedPreferences.setMockInitialValues({});
  });

  tearDown(() {
    SharedPreferences.resetStatic();
    SharedPreferences.setMockInitialValues({});
  });

  test('an explicit opt-in reads as true', () async {
    SharedPreferences.setMockInitialValues({_key: '{"AutoUpload":true}'});

    expect(await persistedShotUploadAutoUploadSetting(), isTrue);
  });

  test('an explicit opt-out reads as false, not absent', () async {
    SharedPreferences.setMockInitialValues({_key: '{"AutoUpload":false}'});

    expect(await persistedShotUploadAutoUploadSetting(), isFalse);
  });

  test('a missing preference reads as absent', () async {
    expect(await persistedShotUploadAutoUploadSetting(), isNull);
  });

  test('a settings object without AutoUpload reads as absent', () async {
    SharedPreferences.setMockInitialValues({_key: '{"autoload":true}'});

    expect(await persistedShotUploadAutoUploadSetting(), isNull);
  });

  test('malformed JSON throws instead of reporting disabled', () async {
    SharedPreferences.setMockInitialValues({_key: '{not json'});

    await expectLater(
      persistedShotUploadAutoUploadSetting(),
      throwsFormatException,
    );
  });

  test('a non-object JSON document throws', () async {
    SharedPreferences.setMockInitialValues({_key: '[]'});

    await expectLater(
      persistedShotUploadAutoUploadSetting(),
      throwsFormatException,
    );
  });

  test('a non-boolean AutoUpload throws', () async {
    SharedPreferences.setMockInitialValues({_key: '{"AutoUpload":"true"}'});

    await expectLater(
      persistedShotUploadAutoUploadSetting(),
      throwsFormatException,
    );
  });

  test(
    'an explicit null AutoUpload throws instead of reading as absent',
    () async {
      SharedPreferences.setMockInitialValues({_key: '{"AutoUpload":null}'});

      await expectLater(
        persistedShotUploadAutoUploadSetting(),
        throwsFormatException,
      );
    },
  );

  test('a non-string stored preference throws', () async {
    SharedPreferences.setMockInitialValues({_key: true});

    await expectLater(
      persistedShotUploadAutoUploadSetting(),
      throwsA(isA<TypeError>()),
    );
  });

  test(
    'a storage read failure propagates and the next read recovers',
    () async {
      final store = _FailingReadStore(
        data: {'flutter.$_key': '{"AutoUpload":true}'},
      );
      SharedPreferencesStorePlatform.instance = store;
      addTearDown(() {
        SharedPreferences.setMockInitialValues({});
      });

      await expectLater(
        persistedShotUploadAutoUploadSetting(),
        throwsStateError,
      );

      store.failReads = false;

      expect(await persistedShotUploadAutoUploadSetting(), isTrue);
    },
  );

  test('the best-effort migration helper still reports disabled', () async {
    SharedPreferences.setMockInitialValues({_key: '{not json'});
    expect(await persistedShotUploadAutoUploadEnabled(), isFalse);

    SharedPreferences.setMockInitialValues({_key: true});
    expect(await persistedShotUploadAutoUploadEnabled(), isFalse);

    SharedPreferences.setMockInitialValues({});
    expect(await persistedShotUploadAutoUploadEnabled(), isFalse);

    SharedPreferences.setMockInitialValues({_key: '{"AutoUpload":false}'});
    expect(await persistedShotUploadAutoUploadEnabled(), isFalse);

    SharedPreferences.setMockInitialValues({_key: '{"AutoUpload":true}'});
    expect(await persistedShotUploadAutoUploadEnabled(), isTrue);
  });
}
