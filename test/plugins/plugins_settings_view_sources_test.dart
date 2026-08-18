import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/plugins/plugin_loader_service.dart';
import 'package:reaprime/src/plugins/plugin_manifest.dart';
import 'package:reaprime/src/plugins/plugin_source.dart';
import 'package:reaprime/src/plugins/plugin_source_service.dart';
import 'package:reaprime/src/settings/plugins_settings_view.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

class _FakeLoader extends Fake implements PluginLoaderService {
  _FakeLoader(this.plugins);

  final List<PluginManifest> plugins;

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
}

class _FakeSourceService extends PluginSourceService {
  _FakeSourceService(super.loader, {this.source});

  final PluginSource? source;
  int updateCalls = 0;
  int approvals = 0;

  @override
  PluginSource? sourceFor(String pluginId) => source;

  @override
  Future<void> updateAllPlugins() async {
    updateCalls++;
  }

  @override
  Future<PluginManifest> approvePendingUpdate(String pluginId) async {
    approvals++;
    return PluginManifest(
      id: pluginId,
      name: 'Test plugin',
      author: 'Test',
      description: '',
      version: '1.1.0',
      apiVersion: 1,
      permissions: const {},
      settings: const {},
      api: null,
    );
  }
}

PluginManifest manifest({Set<PluginPermissions> permissions = const {}}) =>
    PluginManifest(
      id: 'source.reaplugin',
      name: 'Sourced plugin',
      author: 'Test',
      description: 'A plugin with provenance',
      version: '1.0.0',
      apiVersion: 1,
      permissions: permissions,
      settings: const {},
      api: null,
    );

void main() {
  Future<void> pumpView(
    WidgetTester tester, {
    required _FakeSourceService sourceService,
    List<PluginManifest> plugins = const [],
  }) async {
    await tester.pumpWidget(
      ShadApp(
        home: ScaffoldMessenger(
          child: PluginsSettingsView(
            pluginLoaderService: _FakeLoader(plugins),
            pluginSourceService: sourceService,
          ),
        ),
      ),
    );
    await tester.pump();
  }

  testWidgets('the install menu offers every source', (tester) async {
    final sourceService = _FakeSourceService(_FakeLoader(const []));
    await pumpView(tester, sourceService: sourceService);

    await tester.tap(find.byTooltip('Install Plugin'));
    await tester.pumpAndSettle();

    expect(find.text('GitHub Release'), findsOneWidget);
    expect(find.text('GitHub Branch'), findsOneWidget);
    expect(find.text('ZIP file'), findsOneWidget);
    expect(find.text('Folder snapshot'), findsOneWidget);
  });

  testWidgets('check for updates runs the managed update', (tester) async {
    final sourceService = _FakeSourceService(_FakeLoader(const []));
    await pumpView(tester, sourceService: sourceService);

    await tester.tap(find.byTooltip('Check for updates'));
    await tester.pumpAndSettle();

    expect(sourceService.updateCalls, 1);
  });

  testWidgets('a GitHub-backed plugin shows its provenance', (tester) async {
    final sourceService = _FakeSourceService(
      _FakeLoader(const []),
      source: PluginSource(
        kind: PluginSourceKind.githubRelease,
        repo: 'acme/plugin',
        releaseTag: 'v1.0.0',
        installedAt: DateTime(2026, 1, 1),
      ),
    );

    await pumpView(tester, sourceService: sourceService, plugins: [manifest()]);

    expect(
      find.textContaining('GitHub release acme/plugin @ v1.0.0'),
      findsOneWidget,
    );
  });

  testWidgets('a permission escalation is confirmed before it installs', (
    tester,
  ) async {
    final sourceService = _FakeSourceService(
      _FakeLoader(const []),
      source: PluginSource(
        kind: PluginSourceKind.githubRelease,
        repo: 'acme/plugin',
        releaseTag: 'v1.0.0',
        installedAt: DateTime(2026, 1, 1),
        pendingUpdate: PluginPendingUpdate(
          version: '1.1.0',
          releaseTag: 'v1.1.0',
          addedPermissions: const ['proxy.decent_api'],
          detectedAt: DateTime(2026, 1, 2),
        ),
      ),
    );

    await pumpView(
      tester,
      sourceService: sourceService,
      plugins: [
        manifest(permissions: {PluginPermissions.log}),
      ],
    );

    expect(
      find.textContaining('needs approval: adds proxy.decent_api'),
      findsOneWidget,
    );

    await tester.tap(find.text('Review'));
    await tester.pumpAndSettle();

    expect(find.textContaining('requests new permissions'), findsOneWidget);
    expect(find.text('• proxy.decent_api'), findsOneWidget);

    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(sourceService.approvals, 0);

    await tester.tap(find.text('Review'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Approve and update'));
    await tester.pumpAndSettle();

    expect(sourceService.approvals, 1);
  });
}
