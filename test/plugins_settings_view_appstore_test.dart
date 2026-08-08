import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shadcn_ui/shadcn_ui.dart';
import 'package:reaprime/src/plugins/plugin_loader_service.dart';
import 'package:reaprime/src/plugins/plugin_manifest.dart';
import 'package:reaprime/src/settings/plugins_settings_view.dart';

/// A fake PluginLoaderService that avoids creating a real PluginManager/JS runtime.
class FakePluginLoaderService extends Fake implements PluginLoaderService {
  FakePluginLoaderService({this.plugins = const [], this.settings = const {}});

  final List<PluginManifest> plugins;
  final Map<String, dynamic> settings;
  Map<String, dynamic>? savedSettings;

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
      // Refresh button should still be present
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

  testWidgets('clears a stored secure setting explicitly', (tester) async {
    final manifest = PluginManifest(
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
    fakePluginLoaderService = FakePluginLoaderService(
      plugins: [manifest],
      settings: {
        'Password': {'isSet': true},
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

    await tester.tap(find.byTooltip('Clear saved value'));
    await tester.tap(find.widgetWithText(ShadButton, 'Save'));
    await tester.pumpAndSettle();

    expect(fakePluginLoaderService.savedSettings, {'Password': null});
  });

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
