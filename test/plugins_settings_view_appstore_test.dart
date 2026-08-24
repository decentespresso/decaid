import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shadcn_ui/shadcn_ui.dart';
import 'package:reaprime/src/plugins/plugin_loader_service.dart';
import 'package:reaprime/src/plugins/plugin_manifest.dart';
import 'package:reaprime/src/settings/plugins_settings_view.dart';

class FakePluginLoaderService extends Fake implements PluginLoaderService {
  FakePluginLoaderService({this.plugins = const [], this.settings = const {}});

  final List<PluginManifest> plugins;
  final Map<String, dynamic> settings;
  Map<String, dynamic>? savedSettings;
  int saveCallCount = 0;

  @override
  List<PluginManifest> get availablePlugins => plugins;

  @override
  bool isPluginLoaded(String pluginId) => false;

  @override
  Future<bool> shouldAutoLoad(String pluginId) async => false;

  @override
  PluginManifest? getPluginManifest(String pluginId) {
    for (final plugin in plugins) {
      if (plugin.id == pluginId) return plugin;
    }
    return null;
  }

  @override
  Future<Map<String, dynamic>> pluginSettings(String pluginId) async =>
      settings;

  @override
  Future<void> savePluginSettings(
    String pluginId,
    Map<String, dynamic> settings,
  ) async {
    saveCallCount++;
    savedSettings = settings;
  }
}

void main() {
  late FakePluginLoaderService fakePluginLoaderService;

  setUp(() {
    fakePluginLoaderService = FakePluginLoaderService();
  });

  group('PluginsSettingsView install button visibility', () {
    testWidgets('shows install button by default', (tester) async {
      await tester.pumpWidget(
        ShadApp(
          home: PluginsSettingsView(
            pluginLoaderService: fakePluginLoaderService,
          ),
        ),
      );
      await tester.pump();

      expect(find.byTooltip('Install Plugin'), findsOneWidget);
      expect(find.byTooltip('Refresh Plugins'), findsOneWidget);
    });

    testWidgets('hides install button when allowInstall is false', (
      tester,
    ) async {
      await tester.pumpWidget(
        ShadApp(
          home: PluginsSettingsView(
            pluginLoaderService: fakePluginLoaderService,
            allowInstall: false,
          ),
        ),
      );
      await tester.pump();

      expect(find.byTooltip('Install Plugin'), findsNothing);
      expect(find.byTooltip('Refresh Plugins'), findsOneWidget);
    });
  });

  testWidgets('renders manifest permission wire names', (tester) async {
    final manifest = PluginManifest(
      id: 'proxy.reaplugin',
      name: 'Proxy Plugin',
      author: 'Test',
      description: 'Test plugin',
      version: '1.0.0',
      apiVersion: 1,
      permissions: {PluginPermissions.proxyDecentApi},
      settings: {},
      api: PluginApi(endpoints: []),
    );

    fakePluginLoaderService = FakePluginLoaderService(plugins: [manifest]);

    await tester.pumpWidget(
      ShadApp(
        home: PluginsSettingsView(
          pluginLoaderService: fakePluginLoaderService,
          allowInstall: false,
        ),
      ),
    );
    await tester.pump();

    expect(find.text('proxy.decent_api'), findsOneWidget);
    expect(find.text('proxyDecentApi'), findsNothing);
  });

  PluginManifest enumManifest({bool includeDefault = true}) => PluginManifest(
    id: 'enum.reaplugin',
    name: 'Enum Plugin',
    author: 'Test',
    description: 'Test plugin',
    version: '1.0.0',
    apiVersion: 1,
    permissions: {},
    settings: {
      'Roast': {
        'type': 'enum',
        'values': ['Light', 'Medium', 'Dark'],
        if (includeDefault) 'default': 'Medium',
      },
    },
    api: PluginApi(endpoints: []),
  );

  Future<void> openEnumSettingsDialog(
    WidgetTester tester,
    Map<String, dynamic> settings, {
    bool includeDefault = true,
  }) async {
    fakePluginLoaderService = FakePluginLoaderService(
      plugins: [enumManifest(includeDefault: includeDefault)],
      settings: settings,
    );

    await tester.pumpWidget(
      ShadApp(
        builder: (_, child) => ScaffoldMessenger(child: child!),
        home: PluginsSettingsView(
          pluginLoaderService: fakePluginLoaderService,
          allowInstall: false,
        ),
      ),
    );
    await tester.pump();
    await tester.tap(find.widgetWithText(ShadButton, 'Settings'));
    await tester.pumpAndSettle();
  }

  testWidgets('selects and saves enum settings', (tester) async {
    await openEnumSettingsDialog(tester, {'Roast': 'Light'});

    expect(find.byType(ShadSelect<String>), findsOneWidget);
    expect(find.text('Light'), findsOneWidget);
    await tester.tap(find.byType(ShadSelect<String>));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(ShadOption<String>, 'Dark'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(ShadButton, 'Save'));
    await tester.pumpAndSettle();

    expect(fakePluginLoaderService.savedSettings, {'Roast': 'Dark'});
  });

  testWidgets('replaces an invalid enum setting with its valid default', (
    tester,
  ) async {
    await openEnumSettingsDialog(tester, {'Roast': 'Obsolete'});

    expect(find.text('Medium'), findsOneWidget);
    await tester.tap(find.widgetWithText(ShadButton, 'Save'));
    await tester.pumpAndSettle();

    expect(fakePluginLoaderService.savedSettings, {'Roast': 'Medium'});
  });

  testWidgets('clears an invalid enum setting without a valid default', (
    tester,
  ) async {
    await openEnumSettingsDialog(tester, {
      'Roast': 'Obsolete',
    }, includeDefault: false);

    await tester.tap(find.widgetWithText(ShadButton, 'Save'));
    await tester.pumpAndSettle();

    expect(fakePluginLoaderService.savedSettings, {'Roast': null});
  });

  testWidgets('does not persist an untouched enum default', (tester) async {
    await openEnumSettingsDialog(tester, {});

    expect(find.text('Medium'), findsOneWidget);
    await tester.tap(find.widgetWithText(ShadButton, 'Save'));
    await tester.pumpAndSettle();

    expect(fakePluginLoaderService.savedSettings, isEmpty);
  });

  PluginManifest secureManifest() => PluginManifest(
    id: 'secure.reaplugin',
    name: 'Secure Plugin',
    author: 'Test',
    description: 'Test plugin',
    version: '1.0.0',
    apiVersion: 1,
    permissions: {},
    settings: {
      'Password': {'type': 'string', 'secure': true},
    },
    api: PluginApi(endpoints: []),
  );

  Future<void> openSecureSettingsDialog(
    WidgetTester tester, {
    required Map<String, dynamic> settings,
  }) async {
    fakePluginLoaderService = FakePluginLoaderService(
      plugins: [secureManifest()],
      settings: settings,
    );
    await tester.pumpWidget(
      ShadApp(
        builder: (_, child) => ScaffoldMessenger(child: child!),
        home: PluginsSettingsView(
          pluginLoaderService: fakePluginLoaderService,
          allowInstall: false,
        ),
      ),
    );
    await tester.pump();
    await tester.tap(find.widgetWithText(ShadButton, 'Settings'));
    await tester.pumpAndSettle();
  }

  testWidgets('clears a stored secure setting explicitly', (tester) async {
    await openSecureSettingsDialog(
      tester,
      settings: {
        'Password': {'isSet': true},
      },
    );

    await tester.tap(find.byTooltip('Clear saved value'));
    await tester.tap(find.widgetWithText(ShadButton, 'Save'));
    await tester.pumpAndSettle();

    expect(fakePluginLoaderService.savedSettings, {'Password': null});
  });

  testWidgets(
    'secure setting: replacing then erasing the typed value preserves the '
    'stored credential on Save',
    (tester) async {
      await openSecureSettingsDialog(
        tester,
        settings: {
          'Password': {'isSet': true},
        },
      );

      final input = find.byType(ShadInput);
      await tester.enterText(input, 'replacement');
      await tester.enterText(input, '');
      await tester.tap(find.widgetWithText(ShadButton, 'Save'));
      await tester.pumpAndSettle();

      expect(fakePluginLoaderService.savedSettings, {
        'Password': {'isSet': true},
      });
    },
  );

  testWidgets(
    'secure setting: Cancel after typing never calls savePluginSettings',
    (tester) async {
      await openSecureSettingsDialog(
        tester,
        settings: {
          'Password': {'isSet': true},
        },
      );

      await tester.enterText(find.byType(ShadInput), 'replacement');
      await tester.tap(find.widgetWithText(ShadButton, 'Cancel'));
      await tester.pumpAndSettle();

      expect(fakePluginLoaderService.saveCallCount, 0);
      expect(fakePluginLoaderService.savedSettings, isNull);
    },
  );

  testWidgets('secure setting: typed replacement is committed on Save', (
    tester,
  ) async {
    await openSecureSettingsDialog(
      tester,
      settings: {
        'Password': {'isSet': true},
      },
    );

    await tester.enterText(find.byType(ShadInput), 'new-secret');
    await tester.tap(find.widgetWithText(ShadButton, 'Save'));
    await tester.pumpAndSettle();

    expect(fakePluginLoaderService.savedSettings, {'Password': 'new-secret'});
  });

  testWidgets(
    'secure setting: typing then erasing with no stored credential never '
    'sends an unintended clear',
    (tester) async {
      await openSecureSettingsDialog(
        tester,
        settings: {
          'Password': {'isSet': false},
        },
      );

      final input = find.byType(ShadInput);
      await tester.enterText(input, 'typo');
      await tester.enterText(input, '');
      await tester.tap(find.widgetWithText(ShadButton, 'Save'));
      await tester.pumpAndSettle();

      expect(fakePluginLoaderService.savedSettings, {
        'Password': {'isSet': false},
      });
    },
  );

  testWidgets('secure number and boolean settings stay obscured and typed', (
    tester,
  ) async {
    final manifest = PluginManifest(
      id: 'typed-secure.reaplugin',
      name: 'Typed Secure Plugin',
      author: 'Test',
      description: 'Test plugin',
      version: '1.0.0',
      apiVersion: 1,
      permissions: {},
      settings: {
        'NumberSecret': {'type': 'number', 'secure': true},
        'BooleanSecret': {'type': 'boolean', 'secure': true},
      },
      api: PluginApi(endpoints: []),
    );
    fakePluginLoaderService = FakePluginLoaderService(
      plugins: [manifest],
      settings: {
        'NumberSecret': {'isSet': true},
        'BooleanSecret': {'isSet': true},
      },
    );
    await tester.pumpWidget(
      ShadApp(
        builder: (_, child) => ScaffoldMessenger(child: child!),
        home: PluginsSettingsView(
          pluginLoaderService: fakePluginLoaderService,
          allowInstall: false,
        ),
      ),
    );
    await tester.pump();
    await tester.tap(find.widgetWithText(ShadButton, 'Settings'));
    await tester.pumpAndSettle();

    final inputs = find.descendant(
      of: find.byType(AlertDialog),
      matching: find.byType(ShadInput),
    );
    expect(inputs, findsNWidgets(2));
    expect(
      tester.widgetList<ShadInput>(inputs).every((input) => input.obscureText),
      isTrue,
    );
    await tester.enterText(inputs.at(0), '42');
    await tester.enterText(inputs.at(1), 'true');
    await tester.tap(find.widgetWithText(ShadButton, 'Save'));
    await tester.pumpAndSettle();

    expect(fakePluginLoaderService.savedSettings, {
      'NumberSecret': 42,
      'BooleanSecret': true,
    });
  });
}
