import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/plugins/plugin_loader_service.dart';
import 'package:reaprime/src/plugins/plugin_manifest.dart';
import 'package:reaprime/src/plugins/plugin_source.dart';
import 'package:reaprime/src/plugins/plugin_source_service.dart';
import 'package:reaprime/src/settings/plugins_settings_view.dart';
import 'package:reaprime/src/widgets/page_action_menu.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

class _FakeLoader extends Fake implements PluginLoaderService {
  _FakeLoader(this.plugins);

  final List<PluginManifest> plugins;
  int initializeCalls = 0;
  int autoLoadChanges = 0;

  @override
  Future<void> initialize() async {
    initializeCalls++;
  }

  @override
  List<PluginManifest> get availablePlugins => plugins;

  @override
  bool isPluginLoaded(String pluginId) => false;

  @override
  Future<bool> shouldAutoLoad(String pluginId) async => false;

  @override
  Future<void> setPluginAutoLoad(String pluginId, bool autoLoad) async {
    autoLoadChanges++;
  }

  @override
  PluginManifest? getPluginManifest(String pluginId) {
    for (final plugin in plugins) {
      if (plugin.id == pluginId) return plugin;
    }
    return null;
  }
}

class _FakeSourceService extends PluginSourceService {
  _FakeSourceService(super.loader, {this.source, this.updateCompletion});

  final PluginSource? source;
  final Future<void>? updateCompletion;
  int updateCalls = 0;
  int approvals = 0;

  @override
  PluginSource? sourceFor(String pluginId) => source;

  @override
  Future<void> updateAllPlugins() async {
    updateCalls++;
    if (updateCompletion != null) await updateCompletion;
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

    expect(find.byType(PageActionMenu), findsOneWidget);
    expect(find.byTooltip('Plugin actions'), findsOneWidget);
    final cogwheel = find.widgetWithIcon(IconButton, LucideIcons.settings);
    final button = tester.widget<IconButton>(cogwheel);
    expect(button.iconSize, 28);
    expect(
      button.color,
      ShadTheme.of(tester.element(cogwheel)).colorScheme.primary,
    );
    expect(find.byTooltip('Refresh Plugins'), findsNothing);
    expect(find.byTooltip('Install Plugin'), findsNothing);
    await tester.tap(find.byTooltip('Plugin actions'));
    await tester.pumpAndSettle();
    expect(find.text('Refresh plugins'), findsOneWidget);
    expect(find.text('Check for updates'), findsOneWidget);
    await tester.tap(find.text('Install plugin'));
    await tester.pumpAndSettle();

    expect(find.text('GitHub Release'), findsOneWidget);
    expect(find.text('GitHub Branch'), findsOneWidget);
    expect(find.text('ZIP file'), findsOneWidget);
    expect(find.text('Folder snapshot'), findsOneWidget);
  });

  testWidgets('check for updates runs the managed update', (tester) async {
    final sourceService = _FakeSourceService(_FakeLoader(const []));
    await pumpView(tester, sourceService: sourceService);

    await tester.tap(find.byTooltip('Plugin actions'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Check for updates'));
    await tester.pumpAndSettle();

    expect(sourceService.updateCalls, 1);
  });

  testWidgets('refresh plugins reinitializes the list from the page menu', (
    tester,
  ) async {
    final sourceService = _FakeSourceService(_FakeLoader(const []));
    await pumpView(tester, sourceService: sourceService);
    final loader =
        tester
                .widget<PluginsSettingsView>(find.byType(PluginsSettingsView))
                .pluginLoaderService
            as _FakeLoader;

    expect(loader.initializeCalls, 1);
    await tester.tap(find.byTooltip('Plugin actions'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Refresh plugins'));
    await tester.pumpAndSettle();
    expect(loader.initializeCalls, 2);
  });

  testWidgets('dismissing plugin actions does not change auto-load', (
    tester,
  ) async {
    final sourceService = _FakeSourceService(_FakeLoader(const []));
    await pumpView(tester, sourceService: sourceService, plugins: [manifest()]);
    final loader =
        tester
                .widget<PluginsSettingsView>(find.byType(PluginsSettingsView))
                .pluginLoaderService
            as _FakeLoader;

    await tester.tap(find.byTooltip('Plugin actions'));
    await tester.pumpAndSettle();
    await tester.tap(find.byType(ShadSwitch));
    await tester.pumpAndSettle();
    expect(find.text('Install plugin'), findsNothing);
    expect(loader.autoLoadChanges, 0);

    await tester.tap(find.byType(ShadSwitch));
    await tester.pumpAndSettle();
    expect(loader.autoLoadChanges, 1);
  });

  testWidgets('plugin update progress stays visible after the menu closes', (
    tester,
  ) async {
    final completion = Completer<void>();
    final sourceService = _FakeSourceService(
      _FakeLoader(const []),
      updateCompletion: completion.future,
    );
    await pumpView(tester, sourceService: sourceService);

    await tester.tap(find.byTooltip('Plugin actions'));
    await tester.pumpAndSettle();
    final startCheck = tester
        .widget<MenuItemButton>(
          find.widgetWithText(MenuItemButton, 'Check for updates'),
        )
        .onPressed!;
    await tester.tap(find.text('Check for updates'));
    startCheck();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(sourceService.updateCalls, 1);
    expect(find.text('Check for updates'), findsNothing);
    final button = find.byWidgetPredicate(
      (widget) => widget is IconButton && widget.tooltip == 'Plugin actions',
    );
    expect(
      find.descendant(
        of: button,
        matching: find.byType(CircularProgressIndicator),
      ),
      findsOneWidget,
    );

    await tester.tap(find.byTooltip('Plugin actions'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(
      tester
          .widget<MenuItemButton>(
            find.widgetWithText(MenuItemButton, 'Check for updates'),
          )
          .onPressed,
      isNull,
    );

    completion.complete();
    await tester.pumpAndSettle();
    expect(
      find.descendant(
        of: button,
        matching: find.byType(CircularProgressIndicator),
      ),
      findsNothing,
    );
    expect(find.byIcon(LucideIcons.settings), findsOneWidget);
  });

  testWidgets('plugin check completion after leaving the page is safe', (
    tester,
  ) async {
    final completion = Completer<void>();
    final sourceService = _FakeSourceService(
      _FakeLoader(const []),
      updateCompletion: completion.future,
    );
    await pumpView(tester, sourceService: sourceService);
    await tester.tap(find.byTooltip('Plugin actions'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Check for updates'));
    await tester.pump();
    await tester.pumpWidget(const SizedBox.shrink());
    completion.complete();
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets('the installation submenu fits a narrow screen', (tester) async {
    tester.view.physicalSize = const Size(320, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final sourceService = _FakeSourceService(_FakeLoader(const []));
    await pumpView(tester, sourceService: sourceService);

    await tester.tap(find.byTooltip('Plugin actions'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Install plugin'));
    await tester.pumpAndSettle();
    expect(find.text('GitHub Release').hitTestable(), findsOneWidget);
    expect(find.text('Folder snapshot').hitTestable(), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('plugin actions have no duplicated card buttons', (tester) async {
    final sourceService = _FakeSourceService(_FakeLoader(const []));
    await pumpView(tester, sourceService: sourceService, plugins: [manifest()]);

    expect(find.widgetWithText(ShadButton, 'Load'), findsNothing);
    expect(find.widgetWithText(ShadButton, 'Settings'), findsNothing);
    await tester.tap(find.byIcon(LucideIcons.ellipsisVertical));
    await tester.pumpAndSettle();
    expect(find.text('Load'), findsOneWidget);
    expect(find.text('Settings'), findsOneWidget);
    expect(find.text('Reload'), findsOneWidget);
    expect(find.text('Remove'), findsOneWidget);
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
