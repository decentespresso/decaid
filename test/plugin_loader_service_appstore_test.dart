import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/plugins/plugin_loader_service.dart';
import 'package:reaprime/src/services/account/decent_account_service.dart'
    show CredentialStore;
import 'package:reaprime/src/services/storage/kv_store_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

class FakeCredentialStore implements CredentialStore {
  Map<String, String> values = {};
  Completer<void>? _nextWriteStarted;
  Future<void>? _nextWriteRelease;
  Object? _nextDeleteError;

  void blockNextWrite(Completer<void> started, Future<void> release) {
    _nextWriteStarted = started;
    _nextWriteRelease = release;
  }

  void failNextDelete(Object error) {
    _nextDeleteError = error;
  }

  @override
  Future<String?> read({required String key}) async => values[key];

  @override
  Future<void> write({required String key, required String value}) async {
    final started = _nextWriteStarted;
    if (started != null) {
      final release = _nextWriteRelease!;
      _nextWriteStarted = null;
      _nextWriteRelease = null;
      started.complete();
      await release;
    }
    values = {...values, key: value};
  }

  @override
  Future<void> delete({required String key}) async {
    final error = _nextDeleteError;
    if (error != null) {
      _nextDeleteError = null;
      throw error;
    }
    values = Map.fromEntries(values.entries.where((entry) => entry.key != key));
  }
}

class FakeKvStore implements KeyValueStoreService {
  final Map<String, Map<String, Object>> _store = {};
  Completer<void>? _nextWriteStarted;
  Future<void>? _nextWriteRelease;

  void blockNextWrite(Completer<void> started, Future<void> release) {
    _nextWriteStarted = started;
    _nextWriteRelease = release;
  }

  @override
  Future<void> initialize() async {}

  @override
  Future<void> set({
    String namespace = 'default',
    required String key,
    required Object value,
  }) async {
    final started = _nextWriteStarted;
    if (started != null) {
      final release = _nextWriteRelease!;
      _nextWriteStarted = null;
      _nextWriteRelease = null;
      started.complete();
      await release;
    }
    _store.putIfAbsent(namespace, () => {})[key] = value;
  }

  @override
  Future<bool> delete({
    String namespace = 'default',
    required String key,
  }) async {
    return _store[namespace]?.remove(key) != null;
  }

  @override
  Future<Object?> get({
    String namespace = 'default',
    required String key,
  }) async {
    return _store[namespace]?[key];
  }

  @override
  Future<List<String>> keys({String namespace = 'default'}) async {
    return _store[namespace]?.keys.toList() ?? [];
  }

  @override
  List<String> get namespaces => _store.keys.toList();

  @override
  Future<Map<String, Object>> getAll({String namespace = 'default'}) async {
    return Map.from(_store[namespace] ?? {});
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('PluginLoaderService App Store mode', () {
    late Directory tempDir;
    late PluginLoaderService service;
    late FakeCredentialStore credentialStore;
    late FakeKvStore kvStore;
    var sourceCounter = 0;

    Future<Object?> waitForStorage(
      String namespace,
      String key,
      Object? expected,
    ) async {
      for (var i = 0; i < 200; i++) {
        final value = await kvStore.get(namespace: namespace, key: key);
        if (value == expected) return value;
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
      return kvStore.get(namespace: namespace, key: key);
    }

    Directory makePluginSource(
      String id, {
      Map<String, Object> settings = const {},
      List<String> permissions = const [],
      String? jsCode,
    }) {
      final dir = Directory('${tempDir.path}/source_${sourceCounter++}')
        ..createSync();
      File('${dir.path}/manifest.json').writeAsStringSync(
        jsonEncode({
          'id': id,
          'author': 'Test',
          'name': 'Test plugin',
          'description': 'Test plugin',
          'version': '1.0.0',
          'apiVersion': 1,
          'permissions': permissions,
          'settings': settings,
          'api': <Object>[],
        }),
      );
      File('${dir.path}/plugin.js').writeAsStringSync(
        jsCode ??
            '''
function createPlugin() {
  return { id: "x", onLoad() {} };
}
''',
      );
      return dir;
    }

    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      tempDir = Directory.systemTemp.createTempSync('plugin_appstore_test');
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
            const MethodChannel('plugins.flutter.io/path_provider'),
            (_) async => tempDir.path,
          );
      credentialStore = FakeCredentialStore();
      kvStore = FakeKvStore();
      service = PluginLoaderService(
        kvStore: kvStore,
        credentialStore: credentialStore,
      );
      await service.initialize();
    });

    tearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
            const MethodChannel('plugins.flutter.io/path_provider'),
            null,
          );
      if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
    });

    test('addPlugin installs a plugin from a real source directory', () async {
      const id = 'installed.reaplugin';
      final source = makePluginSource(id);

      await service.addPlugin(source.path);

      final pluginDir = Directory('${tempDir.path}/plugins/$id');
      expect(pluginDir.existsSync(), isTrue);
      expect(File('${pluginDir.path}/manifest.json').existsSync(), isTrue);
      expect(File('${pluginDir.path}/plugin.js').existsSync(), isTrue);
      expect(service.getPluginManifest(id), isNotNull);
      expect(service.availablePlugins.any((m) => m.id == id), isTrue);
    });

    test('addPlugin replaces an already-installed plugin', () async {
      const id = 'replaced.reaplugin';
      await service.addPlugin(makePluginSource(id).path);

      final updatedSource = makePluginSource(id);
      File('${updatedSource.path}/v2.txt').writeAsStringSync('v2');

      await service.addPlugin(updatedSource.path);

      final pluginDir = Directory('${tempDir.path}/plugins/$id');
      expect(pluginDir.existsSync(), isTrue);
      expect(File('${pluginDir.path}/v2.txt').existsSync(), isTrue);
    });

    test('removePlugin deletes the installed plugin directory', () async {
      const id = 'removable.reaplugin';
      await service.addPlugin(makePluginSource(id).path);

      final pluginDir = Directory('${tempDir.path}/plugins/$id');
      expect(pluginDir.existsSync(), isTrue);

      await service.removePlugin(id);

      expect(pluginDir.existsSync(), isFalse);
      expect(service.getPluginManifest(id), isNull);
    });

    test('migrates and redacts legacy secure settings on first read', () async {
      const id = 'secure.reaplugin';
      await service.addPlugin(
        makePluginSource(
          id,
          settings: {
            'Username': {'type': 'string'},
            'Password': {'type': 'string', 'secure': true},
          },
        ).path,
      );
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        'plugin.settings.$id',
        jsonEncode({'Username': 'user', 'Password': 'secret'}),
      );

      expect(await service.pluginSettings(id), {
        'Username': 'user',
        'Password': {'isSet': true},
      });
      expect(jsonDecode(prefs.getString('plugin.settings.$id')!), {
        'Username': 'user',
      });
      expect(
        credentialStore.values.values.single,
        jsonEncode({'Password': 'secret'}),
      );
    });

    test(
      'secure setting patches set, preserve, and clear credentials',
      () async {
        const id = 'patch.reaplugin';
        await service.addPlugin(
          makePluginSource(
            id,
            settings: {
              'Username': {'type': 'string'},
              'Password': {'type': 'string', 'secure': true},
            },
          ).path,
        );

        await service.savePluginSettings(id, {
          'Username': 'first',
          'Password': 'secret',
        });
        await service.savePluginSettings(id, {
          'Username': 'second',
          'Password': {'isSet': true},
        });

        expect(await service.pluginSettings(id), {
          'Username': 'second',
          'Password': {'isSet': true},
        });

        await service.savePluginSettings(id, {'Password': null});

        expect(await service.pluginSettings(id), {
          'Username': 'second',
          'Password': {'isSet': false},
        });
        expect(credentialStore.values, isEmpty);
      },
    );

    test('ordinary setting patches set, preserve, and clear values', () async {
      const id = 'ordinary-patch.reaplugin';
      await service.addPlugin(
        makePluginSource(
          id,
          settings: {
            'Username': {'type': 'string'},
            'Theme': {'type': 'string'},
            'Nickname': {'type': 'string'},
          },
        ).path,
      );
      final prefs = await SharedPreferences.getInstance();

      await service.savePluginSettings(id, {
        'Username': 'user',
        'Theme': 'dark',
        'Nickname': 'nick',
      });

      await service.savePluginSettings(id, {'Username': 'new-user'});

      expect(await service.pluginSettings(id), {
        'Username': 'new-user',
        'Theme': 'dark',
        'Nickname': 'nick',
      });

      await service.savePluginSettings(id, {'Nickname': null});

      expect(await service.pluginSettings(id), {
        'Username': 'new-user',
        'Theme': 'dark',
      });
      expect(jsonDecode(prefs.getString('plugin.settings.$id')!), {
        'Username': 'new-user',
        'Theme': 'dark',
      });
    });

    test('enum settings reject values outside the manifest array', () async {
      const id = 'enum.reaplugin';
      await service.addPlugin(
        makePluginSource(
          id,
          settings: {
            'Roast': {
              'type': 'enum',
              'values': ['Light', 'Medium', 'Dark'],
            },
          },
        ).path,
      );

      await service.savePluginSettings(id, {'Roast': 'Light'});
      await expectLater(
        service.savePluginSettings(id, {'Roast': 'Obsolete'}),
        throwsA(isA<PluginSettingsValidationException>()),
      );

      expect(await service.pluginSettings(id), {'Roast': 'Light'});

      await service.savePluginSettings(id, {'Roast': null});
      expect(await service.pluginSettings(id), isEmpty);
    });

    test('rejects pipe-delimited enum manifest values', () async {
      await expectLater(
        service.addPlugin(
          makePluginSource(
            'invalid-enum.reaplugin',
            settings: {
              'Roast': {'type': 'enum', 'values': 'Light | Medium | Dark'},
            },
          ).path,
        ),
        throwsFormatException,
      );
    });

    test(
      'a mixed patch updates, preserves, and clears settings at once',
      () async {
        const id = 'mixed-patch.reaplugin';
        await service.addPlugin(
          makePluginSource(
            id,
            settings: {
              'Username': {'type': 'string'},
              'Theme': {'type': 'string'},
              'Password': {'type': 'string', 'secure': true},
              'ApiKey': {'type': 'string', 'secure': true},
              'Token': {'type': 'string', 'secure': true},
            },
          ).path,
        );
        final prefs = await SharedPreferences.getInstance();

        await service.savePluginSettings(id, {
          'Username': 'user',
          'Theme': 'dark',
          'Password': 'secret',
          'ApiKey': 'key',
          'Token': 'token',
        });

        await service.savePluginSettings(id, {
          'Username': 'new-user',
          'Theme': null,
          'Password': 'new-secret',
          'ApiKey': {'isSet': true},
          'Token': null,
        });

        expect(await service.pluginSettings(id), {
          'Username': 'new-user',
          'Password': {'isSet': true},
          'ApiKey': {'isSet': true},
          'Token': {'isSet': false},
        });
        expect(jsonDecode(prefs.getString('plugin.settings.$id')!), {
          'Username': 'new-user',
        });
        expect(
          credentialStore.values.values.single,
          jsonEncode({'Password': 'new-secret', 'ApiKey': 'key'}),
        );
      },
    );

    test('concurrent setting patches preserve both updates', () async {
      const id = 'concurrent-patch.reaplugin';
      const credentialKey = 'plugin.settings.secure.$id';
      await service.addPlugin(
        makePluginSource(
          id,
          settings: {
            'Username': {'type': 'string'},
            'Password': {'type': 'string', 'secure': true},
          },
        ).path,
      );
      credentialStore.values = {
        credentialKey: jsonEncode({'Password': 'old-secret'}),
      };
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        'plugin.settings.$id',
        jsonEncode({'Username': 'old-user'}),
      );
      final staleWriteStarted = Completer<void>();
      final releaseStaleWrite = Completer<void>();
      credentialStore.blockNextWrite(
        staleWriteStarted,
        releaseStaleWrite.future,
      );

      final usernameUpdate = service.savePluginSettings(id, {
        'Username': 'new-user',
      });
      await staleWriteStarted.future;
      final passwordUpdate = service.savePluginSettings(id, {
        'Password': 'new-secret',
      });
      await Future<void>.delayed(Duration.zero);
      releaseStaleWrite.complete();
      await Future.wait([usernameUpdate, passwordUpdate]);

      expect(jsonDecode(credentialStore.values[credentialKey]!), {
        'Password': 'new-secret',
      });
      expect(jsonDecode(prefs.getString('plugin.settings.$id')!), {
        'Username': 'new-user',
      });
    });

    test('failed credential cleanup leaves uninstall retryable', () async {
      const id = 'retry-remove.reaplugin';
      await service.addPlugin(
        makePluginSource(
          id,
          settings: {
            'Password': {'type': 'string', 'secure': true},
          },
        ).path,
      );
      await service.savePluginSettings(id, {'Password': 'secret'});
      final pluginDir = Directory('${tempDir.path}/plugins/$id');
      credentialStore.failNextDelete(StateError('delete failed'));

      await expectLater(service.removePlugin(id), throwsStateError);

      expect(service.getPluginManifest(id), isNotNull);
      expect(pluginDir.existsSync(), isTrue);
      expect(credentialStore.values, isNotEmpty);

      await service.removePlugin(id);

      expect(service.getPluginManifest(id), isNull);
      expect(pluginDir.existsSync(), isFalse);
      expect(credentialStore.values, isEmpty);
    });

    test('assembles secure settings only for plugin onLoad', () async {
      const id = 'load-secure.reaplugin';
      await service.addPlugin(
        makePluginSource(
          id,
          settings: {
            'Username': {'type': 'string'},
            'Password': {'type': 'string', 'secure': true},
          },
          jsCode:
              '''
function createPlugin() {
  return {
    id: "$id",
    onLoad(settings) {
      if (settings.Username !== "user" || settings.Password !== "secret") {
        throw new Error("settings not assembled");
      }
    }
  };
}
''',
        ).path,
      );
      await service.savePluginSettings(id, {
        'Username': 'user',
        'Password': 'secret',
      });

      await service.loadPlugin(id);

      expect(service.isPluginLoaded(id), isTrue);
      expect(await service.pluginSettings(id), {
        'Username': 'user',
        'Password': {'isSet': true},
      });
    });

    test(
      'saving settings for a loaded plugin reloads it with the new value',
      () async {
        const id = 'live-apply.reaplugin';
        await service.addPlugin(
          makePluginSource(
            id,
            settings: {
              'Mode': {'type': 'string'},
            },
            permissions: ['pluginStorage'],
            jsCode:
                '''
function createPlugin(host) {
  return {
    id: "$id",
    onLoad(settings) {
      globalThis.__modeLoads = (globalThis.__modeLoads || 0) + 1;
      host.storage({type: "write", key: "mode",
        data: globalThis.__modeLoads + ":" + settings.Mode});
    }
  };
}
''',
          ).path,
        );

        await service.savePluginSettings(id, {'Mode': 'off'});
        await service.loadPlugin(id);
        expect(await waitForStorage(id, 'mode', '1:off'), '1:off');

        await service.savePluginSettings(id, {'Mode': 'auto'});

        expect(service.isPluginLoaded(id), isTrue);
        expect(
          await waitForStorage(id, 'mode', '2:auto'),
          '2:auto',
          reason: 'save must reload the loaded plugin exactly once ',
        );
      },
    );

    test('saving settings for an unloaded plugin leaves it unloaded', () async {
      const id = 'unloaded-save.reaplugin';
      await service.addPlugin(
        makePluginSource(
          id,
          settings: {
            'Mode': {'type': 'string'},
          },
        ).path,
      );

      await service.savePluginSettings(id, {'Mode': 'auto'});

      expect(service.isPluginLoaded(id), isFalse);
      expect(await service.pluginSettings(id), {'Mode': 'auto'});
    });

    test(
      'concurrent saves on a loaded plugin reload without deadlocking',
      () async {
        const id = 'concurrent-loaded.reaplugin';
        const credentialKey = 'plugin.settings.secure.$id';
        await service.addPlugin(
          makePluginSource(
            id,
            settings: {
              'Username': {'type': 'string'},
              'Password': {'type': 'string', 'secure': true},
            },
            jsCode:
                '''
function createPlugin() {
  return { id: "$id", onLoad() {} };
}
''',
          ).path,
        );
        credentialStore.values = {
          credentialKey: jsonEncode({'Password': 'old-secret'}),
        };
        final prefs = await SharedPreferences.getInstance();
        await prefs.setString(
          'plugin.settings.$id',
          jsonEncode({'Username': 'old-user'}),
        );
        await service.loadPlugin(id);

        final staleWriteStarted = Completer<void>();
        final releaseStaleWrite = Completer<void>();
        credentialStore.blockNextWrite(
          staleWriteStarted,
          releaseStaleWrite.future,
        );

        final usernameUpdate = service.savePluginSettings(id, {
          'Username': 'new-user',
        });
        await staleWriteStarted.future;
        final passwordUpdate = service.savePluginSettings(id, {
          'Password': 'new-secret',
        });
        await Future<void>.delayed(Duration.zero);
        releaseStaleWrite.complete();
        await Future.wait([usernameUpdate, passwordUpdate]);

        expect(service.isPluginLoaded(id), isTrue);
        expect(jsonDecode(credentialStore.values[credentialKey]!), {
          'Password': 'new-secret',
        });
        expect(jsonDecode(prefs.getString('plugin.settings.$id')!), {
          'Username': 'new-user',
        });
        expect(await service.pluginSettings(id), {
          'Username': 'new-user',
          'Password': {'isSet': true},
        });
      },
    );

    test('a disable racing a settings save does not fail the save', () async {
      const id = 'save-disable-race.reaplugin';
      await service.addPlugin(
        makePluginSource(
          id,
          settings: {
            'Mode': {'type': 'string'},
          },
          permissions: ['pluginStorage'],
          jsCode:
              '''
function createPlugin(host) {
  return {
    id: "$id",
    onUnload() {
      host.storage({type: "write", key: "unloaded", data: true});
    }
  };
}
''',
        ).path,
      );
      await service.savePluginSettings(id, {'Mode': 'auto'});
      await service.loadPlugin(id);

      // Hold the mutation lock inside disable's unload (its onUnload storage
      // write blocks) while the save persists and then attempts to apply.
      final unloadStarted = Completer<void>();
      final releaseUnload = Completer<void>();
      kvStore.blockNextWrite(unloadStarted, releaseUnload.future);

      final disable = service.disablePlugin(id);
      await unloadStarted.future;
      final save = service.savePluginSettings(id, {'Mode': 'fast'});
      await Future<void>.delayed(Duration.zero);
      releaseUnload.complete();

      await Future.wait([save, disable]);

      expect(service.isPluginLoaded(id), isFalse);
      expect(await service.pluginSettings(id), {'Mode': 'fast'});
    });

    group('settings schema evolution', () {
      test('drops a removed setting and cleans it from storage', () async {
        const id = 'evolve-remove.reaplugin';
        await service.addPlugin(
          makePluginSource(
            id,
            settings: {
              'AutoUpload': {'type': 'boolean'},
              'DrainHistory': {'type': 'boolean'},
            },
          ).path,
        );
        await service.savePluginSettings(id, {
          'AutoUpload': true,
          'DrainHistory': true,
        });
        final prefs = await SharedPreferences.getInstance();
        expect(jsonDecode(prefs.getString('plugin.settings.$id')!), {
          'AutoUpload': true,
          'DrainHistory': true,
        });

        await service.addPlugin(
          makePluginSource(
            id,
            settings: {
              'AutoUpload': {'type': 'boolean'},
            },
          ).path,
        );

        expect(await service.pluginSettings(id), {'AutoUpload': true});
        expect(jsonDecode(prefs.getString('plugin.settings.$id')!), {
          'AutoUpload': true,
        });

        await service.savePluginSettings(id, {'AutoUpload': false});
        expect(await service.pluginSettings(id), {'AutoUpload': false});
        expect(jsonDecode(prefs.getString('plugin.settings.$id')!), {
          'AutoUpload': false,
        });
      });

      test('reload after a schema change passes only current settings to the '
          'plugin', () async {
        const id = 'evolve-load.reaplugin';
        await service.addPlugin(
          makePluginSource(
            id,
            settings: {
              'Mode': {'type': 'string'},
              'Legacy': {'type': 'string'},
            },
            permissions: ['pluginStorage'],
            jsCode:
                '''
function createPlugin(host) {
  return {
    id: "$id",
    onLoad(settings) {
      host.storage({type: "write", key: "loads",
        data: JSON.stringify(settings)});
    }
  };
}
''',
          ).path,
        );
        await service.savePluginSettings(id, {'Mode': 'fast', 'Legacy': 'old'});
        await service.loadPlugin(id);
        expect(
          await waitForStorage(id, 'loads', '{"Mode":"fast","Legacy":"old"}'),
          '{"Mode":"fast","Legacy":"old"}',
        );

        await service.addPlugin(
          makePluginSource(
            id,
            settings: {
              'Mode': {'type': 'string'},
            },
            permissions: ['pluginStorage'],
            jsCode:
                '''
function createPlugin(host) {
  return {
    id: "$id",
    onLoad(settings) {
      host.storage({type: "write", key: "loads",
        data: JSON.stringify(settings)});
    }
  };
}
''',
          ).path,
        );

        expect(service.isPluginLoaded(id), isTrue);
        expect(
          await waitForStorage(id, 'loads', '{"Mode":"fast"}'),
          '{"Mode":"fast"}',
          reason: 'the reload after the update must not see the removed key',
        );
      });

      test('resets an obsolete enum value to a valid default', () async {
        const id = 'evolve-enum.reaplugin';
        await service.addPlugin(
          makePluginSource(
            id,
            settings: {
              'Roast': {
                'type': 'enum',
                'values': ['Light', 'Medium', 'Dark'],
                'default': 'Medium',
              },
            },
          ).path,
        );
        await service.savePluginSettings(id, {'Roast': 'Medium'});

        await service.addPlugin(
          makePluginSource(
            id,
            settings: {
              'Roast': {
                'type': 'enum',
                'values': ['Light', 'Dark'],
                'default': 'Dark',
              },
            },
          ).path,
        );

        expect(await service.pluginSettings(id), {'Roast': 'Dark'});
        final prefs = await SharedPreferences.getInstance();
        expect(jsonDecode(prefs.getString('plugin.settings.$id')!), {
          'Roast': 'Dark',
        });
      });

      test('removes an enum value with no valid default', () async {
        const id = 'evolve-enum-null.reaplugin';
        await service.addPlugin(
          makePluginSource(
            id,
            settings: {
              'Roast': {
                'type': 'enum',
                'values': ['Light', 'Medium'],
                'default': 'Medium',
              },
            },
          ).path,
        );
        await service.savePluginSettings(id, {'Roast': 'Light'});

        await service.addPlugin(
          makePluginSource(
            id,
            settings: {
              'Roast': {
                'type': 'enum',
                'values': ['Medium'],
                'default': 'Light',
              },
            },
          ).path,
        );

        expect(await service.pluginSettings(id), isEmpty);
        final prefs = await SharedPreferences.getInstance();
        expect(prefs.containsKey('plugin.settings.$id'), isFalse);
      });

      test('converts an incompatible persisted type via the default', () async {
        const id = 'evolve-type.reaplugin';
        await service.addPlugin(
          makePluginSource(
            id,
            settings: {
              'Enabled': {'type': 'string'},
            },
          ).path,
        );
        await service.savePluginSettings(id, {'Enabled': 'yes'});

        await service.addPlugin(
          makePluginSource(
            id,
            settings: {
              'Enabled': {'type': 'boolean', 'default': true},
            },
          ).path,
        );

        expect(await service.pluginSettings(id), {'Enabled': true});
        final prefs = await SharedPreferences.getInstance();
        expect(jsonDecode(prefs.getString('plugin.settings.$id')!), {
          'Enabled': true,
        });
      });

      test('drops a value incompatible with the new type', () async {
        const id = 'evolve-type-drop.reaplugin';
        await service.addPlugin(
          makePluginSource(
            id,
            settings: {
              'Level': {'type': 'string'},
            },
          ).path,
        );
        await service.savePluginSettings(id, {'Level': 'high'});

        await service.addPlugin(
          makePluginSource(
            id,
            settings: {
              'Level': {'type': 'number'},
            },
          ).path,
        );

        expect(await service.pluginSettings(id), isEmpty);
        final prefs = await SharedPreferences.getInstance();
        expect(prefs.containsKey('plugin.settings.$id'), isFalse);
      });

      test('still rejects unknown caller-provided keys', () async {
        const id = 'evolve-reject.reaplugin';
        await service.addPlugin(
          makePluginSource(
            id,
            settings: {
              'AutoUpload': {'type': 'boolean'},
            },
          ).path,
        );

        await expectLater(
          service.savePluginSettings(id, {
            'AutoUpload': true,
            'DrainHistory': true,
          }),
          throwsA(isA<PluginSettingsValidationException>()),
        );
      });

      test('migrates a setting that became secure', () async {
        const id = 'evolve-secure.reaplugin';
        await service.addPlugin(
          makePluginSource(
            id,
            settings: {
              'Token': {'type': 'string'},
            },
          ).path,
        );
        await service.savePluginSettings(id, {'Token': 'secret'});

        await service.addPlugin(
          makePluginSource(
            id,
            settings: {
              'Token': {'type': 'string', 'secure': true},
            },
          ).path,
        );

        expect(await service.pluginSettings(id), {
          'Token': {'isSet': true},
        });
        expect(
          credentialStore.values.values.single,
          jsonEncode({'Token': 'secret'}),
        );
        final prefs = await SharedPreferences.getInstance();
        expect(prefs.getString('plugin.settings.$id'), isNull);
      });

      test('never copies a former secret into ordinary storage', () async {
        const id = 'evolve-secure-drop.reaplugin';
        await service.addPlugin(
          makePluginSource(
            id,
            settings: {
              'Token': {'type': 'string', 'secure': true},
            },
          ).path,
        );
        await service.savePluginSettings(id, {'Token': 'secret'});

        await service.addPlugin(
          makePluginSource(
            id,
            settings: {
              'Token': {'type': 'string'},
            },
          ).path,
        );

        expect(await service.pluginSettings(id), isEmpty);
        expect(credentialStore.values, isEmpty);
        final prefs = await SharedPreferences.getInstance();
        expect(prefs.getString('plugin.settings.$id'), isNull);
      });

      test('a manifest with no settings cleans persisted settings', () async {
        const id = 'evolve-empty.reaplugin';
        await service.addPlugin(
          makePluginSource(
            id,
            settings: {
              'Mode': {'type': 'string'},
            },
          ).path,
        );
        await service.savePluginSettings(id, {'Mode': 'fast'});
        final prefs = await SharedPreferences.getInstance();
        expect(jsonDecode(prefs.getString('plugin.settings.$id')!), {
          'Mode': 'fast',
        });

        await service.addPlugin(makePluginSource(id, settings: {}).path);

        expect(await service.pluginSettings(id), isEmpty);
        expect(prefs.containsKey('plugin.settings.$id'), isFalse);
      });

      test('a manifest with no settings loads the plugin with none', () async {
        const id = 'evolve-empty-load.reaplugin';
        await service.addPlugin(
          makePluginSource(
            id,
            settings: {
              'Mode': {'type': 'string'},
            },
            permissions: ['pluginStorage'],
            jsCode:
                '''
function createPlugin(host) {
  return {
    id: "$id",
    onLoad(settings) {
      host.storage({type: "write", key: "loads",
        data: JSON.stringify(settings)});
    }
  };
}
''',
          ).path,
        );
        await service.savePluginSettings(id, {'Mode': 'fast'});
        await service.loadPlugin(id);
        expect(
          await waitForStorage(id, 'loads', '{"Mode":"fast"}'),
          '{"Mode":"fast"}',
        );

        await service.addPlugin(
          makePluginSource(
            id,
            settings: {},
            permissions: ['pluginStorage'],
            jsCode:
                '''
function createPlugin(host) {
  return {
    id: "$id",
    onLoad(settings) {
      host.storage({type: "write", key: "loads",
        data: JSON.stringify(settings)});
    }
  };
}
''',
          ).path,
        );

        expect(service.isPluginLoaded(id), isTrue);
        expect(
          await waitForStorage(id, 'loads', '{}'),
          '{}',
          reason: 'the reload after the update must not see old settings',
        );
        expect(await service.pluginSettings(id), isEmpty);
        final prefs = await SharedPreferences.getInstance();
        expect(prefs.containsKey('plugin.settings.$id'), isFalse);
      });

      test('a failed update restores the previous settings', () async {
        const id = 'evolve-rollback.reaplugin';
        await service.addPlugin(
          makePluginSource(
            id,
            settings: {
              'AutoUpload': {'type': 'boolean'},
              'DrainHistory': {'type': 'boolean'},
            },
            permissions: ['pluginStorage'],
            jsCode:
                '''
function createPlugin() {
  return { id: "$id", onLoad() {} };
}
''',
          ).path,
        );
        await service.savePluginSettings(id, {
          'AutoUpload': true,
          'DrainHistory': true,
        });
        await service.loadPlugin(id);
        expect(service.isPluginLoaded(id), isTrue);

        await expectLater(
          service.addPlugin(
            makePluginSource(
              id,
              settings: {
                'AutoUpload': {'type': 'boolean'},
              },
              permissions: ['pluginStorage'],
              jsCode: 'function createPlugin() { throw new Error("boom"); }',
            ).path,
          ),
          throwsA(anything),
        );

        expect(service.isPluginLoaded(id), isTrue);
        expect(await service.pluginSettings(id), {
          'AutoUpload': true,
          'DrainHistory': true,
        });
        final prefs = await SharedPreferences.getInstance();
        expect(jsonDecode(prefs.getString('plugin.settings.$id')!), {
          'AutoUpload': true,
          'DrainHistory': true,
        });
      });

      test(
        'a failed update restores settings reconciled away by the new schema',
        () async {
          const id = 'evolve-rollback-schema.reaplugin';
          await service.addPlugin(
            makePluginSource(
              id,
              settings: {
                'Level': {'type': 'string'},
                'Roast': {
                  'type': 'enum',
                  'values': ['Light', 'Medium'],
                  'default': 'Medium',
                },
              },
              permissions: ['pluginStorage'],
              jsCode:
                  '''
function createPlugin() {
  return { id: "$id", onLoad() {} };
}
''',
            ).path,
          );
          await service.savePluginSettings(id, {
            'Level': 'high',
            'Roast': 'Medium',
          });
          await service.loadPlugin(id);

          await expectLater(
            service.addPlugin(
              makePluginSource(
                id,
                settings: {
                  'Level': {'type': 'number'},
                  'Roast': {
                    'type': 'enum',
                    'values': ['Light'],
                    'default': 'Light',
                  },
                },
                permissions: ['pluginStorage'],
                jsCode: 'function createPlugin() { throw new Error("boom"); }',
              ).path,
            ),
            throwsA(anything),
          );

          expect(await service.pluginSettings(id), {
            'Level': 'high',
            'Roast': 'Medium',
          });
        },
      );

      test('a failed update restores a secure migration', () async {
        const id = 'evolve-rollback-secure.reaplugin';
        await service.addPlugin(
          makePluginSource(
            id,
            settings: {
              'Token': {'type': 'string'},
            },
            permissions: ['pluginStorage'],
            jsCode:
                '''
function createPlugin() {
  return { id: "$id", onLoad() {} };
}
''',
          ).path,
        );
        await service.savePluginSettings(id, {'Token': 'secret'});
        await service.loadPlugin(id);

        await expectLater(
          service.addPlugin(
            makePluginSource(
              id,
              settings: {
                'Token': {'type': 'string', 'secure': true},
              },
              permissions: ['pluginStorage'],
              jsCode: 'function createPlugin() { throw new Error("boom"); }',
            ).path,
          ),
          throwsA(anything),
        );

        expect(await service.pluginSettings(id), {'Token': 'secret'});
        final prefs = await SharedPreferences.getInstance();
        expect(jsonDecode(prefs.getString('plugin.settings.$id')!), {
          'Token': 'secret',
        });
        expect(credentialStore.values, isEmpty);
      });

      test('reconciles a secure value that changed type', () async {
        const id = 'evolve-secure-type.reaplugin';
        await service.addPlugin(
          makePluginSource(
            id,
            settings: {
              'Enabled': {'type': 'string'},
            },
          ).path,
        );
        await service.savePluginSettings(id, {'Enabled': 'yes'});

        await service.addPlugin(
          makePluginSource(
            id,
            settings: {
              'Enabled': {'type': 'boolean', 'secure': true},
            },
          ).path,
        );

        expect(await service.pluginSettings(id), {
          'Enabled': {'isSet': false},
        });
        expect(credentialStore.values, isEmpty);
        final prefs = await SharedPreferences.getInstance();
        expect(prefs.getString('plugin.settings.$id'), isNull);
      });

      test('resets a secure enum value removed from values', () async {
        const id = 'evolve-secure-enum.reaplugin';
        await service.addPlugin(
          makePluginSource(
            id,
            settings: {
              'Roast': {
                'type': 'enum',
                'secure': true,
                'values': ['Light', 'Medium'],
                'default': 'Medium',
              },
            },
          ).path,
        );
        await service.savePluginSettings(id, {'Roast': 'Medium'});

        await service.addPlugin(
          makePluginSource(
            id,
            settings: {
              'Roast': {
                'type': 'enum',
                'secure': true,
                'values': ['Light', 'Dark'],
                'default': 'Dark',
              },
            },
          ).path,
        );

        expect(await service.pluginSettings(id), {
          'Roast': {'isSet': true},
        });
        expect(
          credentialStore.values.values.single,
          jsonEncode({'Roast': 'Dark'}),
        );
      });
    });

    const unsafeIds = [
      '',
      '.',
      '..',
      '../escape',
      'a/b',
      r'a\b',
      '/abs',
      r'\abs',
      'C:evil',
      r'\\server\share',
      'a?b',
      'trailing.',
      'trailing ',
    ];

    for (final id in unsafeIds) {
      test(
        'addPlugin rejects unsafe plugin id ${id.isEmpty ? '(empty)' : '"$id"'}',
        () async {
          final source = makePluginSource(id);

          await expectLater(
            service.addPlugin(source.path),
            throwsFormatException,
          );
          expect(
            service.availablePlugins.any((m) => m.id == id),
            isFalse,
            reason: 'unsafe id must not enter the registry',
          );
        },
      );
    }

    test(
      'rejected installs never create or delete directories outside plugins root',
      () async {
        final pluginsDir = Directory('${tempDir.path}/plugins');

        final escapeDir = Directory('${tempDir.path}/escape');
        if (escapeDir.existsSync()) escapeDir.deleteSync(recursive: true);
        await expectLater(
          service.addPlugin(makePluginSource('../escape').path),
          throwsFormatException,
        );
        expect(escapeDir.existsSync(), isFalse);

        final nested = Directory('${pluginsDir.path}/a/b');
        await expectLater(
          service.addPlugin(makePluginSource('a/b').path),
          throwsFormatException,
        );
        expect(nested.existsSync(), isFalse);

        final absDir = Directory('${pluginsDir.path}/abs');
        if (absDir.existsSync()) absDir.deleteSync(recursive: true);
        await expectLater(
          service.addPlugin(makePluginSource('/abs').path),
          throwsFormatException,
        );
        expect(absDir.existsSync(), isFalse);

        final winSep = Directory('${pluginsDir.path}/a\\b');
        await expectLater(
          service.addPlugin(makePluginSource(r'a\b').path),
          throwsFormatException,
        );
        expect(winSep.existsSync(), isFalse);
      },
    );

    test(
      'removePlugin rejects an unsafe id before touching the filesystem',
      () async {
        await expectLater(
          service.removePlugin('../escape'),
          throwsFormatException,
        );
        expect(
          Directory('${tempDir.path}/escape').existsSync(),
          isFalse,
          reason: 'removePlugin must not resolve an unsafe id into a path',
        );
      },
    );

    test('getPluginDirectory rejects an unsafe id', () {
      expect(
        () => service.getPluginDirectory('../escape'),
        throwsFormatException,
      );
    });

    test('an unsafe manifest cannot enter the registry via scan', () async {
      final evilDir = Directory('${tempDir.path}/plugins/evil-dir')
        ..createSync(recursive: true);
      File('${evilDir.path}/manifest.json').writeAsStringSync(
        jsonEncode({
          'id': '../escape',
          'author': 'Test',
          'name': 'Evil',
          'description': 'Test plugin',
          'version': '1.0.0',
          'apiVersion': 1,
          'permissions': <String>[],
          'settings': <String, Object>{},
          'api': <Object>[],
        }),
      );
      File(
        '${evilDir.path}/plugin.js',
      ).writeAsStringSync('function createPlugin() {}');

      final fresh = PluginLoaderService(kvStore: FakeKvStore());
      await fresh.initialize();

      expect(fresh.getPluginManifest('../escape'), isNull);
      expect(
        fresh.availablePlugins.any((m) => m.id == '../escape'),
        isFalse,
        reason: 'an unsafe manifest id must not enter the registry',
      );
    });
  });
}
