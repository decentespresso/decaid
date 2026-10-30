import 'dart:async';
import 'dart:io';

import 'package:file_picker/src/platform/file_picker_platform_interface.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:logging/logging.dart';
import 'package:reaprime/src/plugins/plugin_loader_service.dart';
import 'package:reaprime/src/plugins/plugin_manifest.dart';
import 'package:reaprime/src/plugins/plugin_source.dart';
import 'package:reaprime/src/plugins/plugin_source_service.dart';
import 'package:reaprime/src/settings/plugins_settings_view.dart';
import 'package:reaprime/src/widgets/page_action_menu.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

class _FolderPicker extends FilePickerPlatform {
  _FolderPicker({this.selected});

  final String? selected;

  @override
  Future<String?> getDirectoryPath({
    String? dialogTitle,
    bool lockParentWindow = false,
    String? initialDirectory,
  }) async {
    if (selected != null) return selected;
    throw const FileSystemException(
      'private folder diagnostics',
      '/private/plugin.reaplugin',
    );
  }
}

class _FakeLoader extends Fake implements PluginLoaderService {
  _FakeLoader(this.plugins);

  final List<PluginManifest> plugins;
  Future<void>? initialization;
  int initializeCalls = 0;
  int autoLoadChanges = 0;

  @override
  Future<void> initialize() async {
    initializeCalls++;
    if (initialization != null) await initialization;
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
  Future<void> removePlugin(String pluginId) async =>
      throw const FileSystemException(
        'private removal diagnostics',
        '/private/plugin.reaplugin',
      );

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

  PluginSource? source;
  final Future<void>? updateCompletion;
  @override
  final ValueNotifier<Future<void>?> updateCheck = ValueNotifier(null);
  int updateCalls = 0;
  int approvals = 0;
  Object? approvalError;
  int installCalls = 0;
  Object? installError;
  String? installedRepo;
  String? installedAsset;

  @override
  Future<PluginManifest> installFromGitHubRelease(
    String repo, {
    String? assetName,
    bool includePrerelease = false,
  }) async {
    installCalls++;
    if (installError != null) throw installError!;
    installedRepo = repo;
    installedAsset = assetName;
    return manifest();
  }

  @override
  PluginSource? sourceFor(String pluginId) => source;

  @override
  Future<void> updateAllPlugins() => updateCheck.value ??= _updateAllPlugins()
      .whenComplete(() => updateCheck.value = null);

  Future<void> _updateAllPlugins() async {
    updateCalls++;
    if (updateCompletion != null) await updateCompletion;
  }

  @override
  Future<PluginManifest> approvePendingUpdate(String pluginId) async {
    approvals++;
    if (approvalError != null) throw approvalError!;
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

  testWidgets('folder installation failure hides filesystem diagnostics', (
    tester,
  ) async {
    final picker = FilePickerPlatform.instance;
    FilePickerPlatform.instance = _FolderPicker();
    addTearDown(() => FilePickerPlatform.instance = picker);
    await pumpView(
      tester,
      sourceService: _FakeSourceService(_FakeLoader(const [])),
    );
    await tester.tap(find.byTooltip('Plugin actions'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Install plugin'));
    await tester.pumpAndSettle();
    final install = tester
        .widget<MenuItemButton>(
          find.widgetWithText(MenuItemButton, 'Folder snapshot'),
        )
        .onPressed!;
    await tester.runAsync(() async {
      final failure = Logger('PluginsSettingsView').onRecord.firstWhere(
        (record) => record.message == 'Failed to install plugin',
      );
      install();
      await failure.timeout(const Duration(seconds: 10));
    });
    await tester.pumpAndSettle();

    expect(
      find.text(
        "Couldn't install the plugin. Check storage space and file permissions, then try again.",
      ),
      findsOneWidget,
    );
    expect(find.textContaining('private'), findsNothing);
    expect(find.textContaining('FileSystemException'), findsNothing);
  });

  testWidgets('invalid plugin folder selection keeps actionable guidance', (
    tester,
  ) async {
    final picker = FilePickerPlatform.instance;
    FilePickerPlatform.instance = _FolderPicker(
      selected: '/private/not-a-plugin',
    );
    addTearDown(() => FilePickerPlatform.instance = picker);
    await pumpView(
      tester,
      sourceService: _FakeSourceService(_FakeLoader(const [])),
    );
    final install = tester
        .widget<PageActionMenu>(find.byType(PageActionMenu))
        .onInstall!;
    await tester.runAsync(() async {
      final failure = Logger('PluginsSettingsView').onRecord.firstWhere(
        (record) => record.message == 'Failed to install plugin',
      );
      install('folder');
      await failure.timeout(const Duration(seconds: 10));
    });
    await tester.pumpAndSettle();

    expect(
      find.text(
        "Couldn't install the plugin. Select a folder ending in .reaplugin.",
      ),
      findsOneWidget,
    );
    expect(find.textContaining('private'), findsNothing);
  });

  testWidgets('plugin removal failure hides filesystem diagnostics', (
    tester,
  ) async {
    await pumpView(
      tester,
      sourceService: _FakeSourceService(_FakeLoader(const [])),
      plugins: [manifest()],
    );
    await tester.tap(find.byIcon(LucideIcons.ellipsisVertical));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Remove'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(TextButton, 'Remove'));
    await tester.pumpAndSettle();

    expect(
      find.text(
        "Couldn't remove the plugin. Check storage space and file permissions, then try again.",
      ),
      findsOneWidget,
    );
    expect(find.textContaining('private'), findsNothing);
    expect(find.textContaining('FileSystemException'), findsNothing);
    expect(find.text('Sourced plugin'), findsOneWidget);
  });

  testWidgets('offline plugin installation retries with the original options', (
    tester,
  ) async {
    final service = _FakeSourceService(_FakeLoader(const []))
      ..installError = const SocketException('private host lookup');
    await pumpView(tester, sourceService: service);
    await tester.tap(find.byTooltip('Plugin actions'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Install plugin'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('GitHub Release'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).at(0), 'acme/plugin');
    await tester.enterText(find.byType(TextField).at(1), 'plugin.zip');
    await tester.tap(find.text('Install'));
    await tester.pumpAndSettle();
    expect(
      find.text(
        "Couldn't install the plugin. Check your internet connection and try again.",
      ),
      findsOneWidget,
    );
    service.installError = null;
    await tester.tap(find.text('Retry'));
    await tester.pumpAndSettle();
    expect(service.installCalls, 2);
    expect(service.installedRepo, 'acme/plugin');
    expect(service.installedAsset, 'plugin.zip');
    expect(find.text('Plugin installed: Sourced plugin'), findsOneWidget);
  });

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

  testWidgets(
    'late update-check refresh after disposal does not reload plugins',
    (tester) async {
      final completion = Completer<void>();
      final sourceService = _FakeSourceService(
        _FakeLoader(const []),
        updateCompletion: completion.future,
      );
      await pumpView(tester, sourceService: sourceService);
      final view = tester.widget<PluginsSettingsView>(
        find.byType(PluginsSettingsView),
      );
      final loader = view.pluginLoaderService as _FakeLoader;
      final menu = tester.widget<PageActionMenu>(find.byType(PageActionMenu));
      final refresh = menu.onUpdatesChecked!;
      final check = menu.onCheckForUpdates!();
      expect(sourceService.updateCalls, 1);

      await tester.pumpWidget(const SizedBox.shrink());
      completion.complete();
      await check;
      refresh();
      await tester.pump();

      expect(loader.initializeCalls, 1);
      expect(tester.takeException(), isNull);
    },
  );

  for (final fails in [false, true]) {
    testWidgets(
      'plugin refresh ${fails ? 'failure' : 'completion'} after update check and disposal is safe',
      (tester) async {
        final completion = Completer<void>();
        final initialization = Completer<void>();
        final sourceService = _FakeSourceService(
          _FakeLoader(const []),
          updateCompletion: completion.future,
        );
        await pumpView(tester, sourceService: sourceService);
        final view = tester.widget<PluginsSettingsView>(
          find.byType(PluginsSettingsView),
        );
        final loader = view.pluginLoaderService as _FakeLoader;
        loader.initialization = initialization.future;
        final menu = tester.widget<PageActionMenu>(find.byType(PageActionMenu));
        final check = menu.onCheckForUpdates!();
        completion.complete();
        await check;
        await tester.pump();
        expect(loader.initializeCalls, 2);
        expect(find.byType(CircularProgressIndicator), findsOneWidget);

        await tester.pumpWidget(const SizedBox.shrink());
        if (fails) {
          initialization.completeError(StateError('scan failed'));
        } else {
          initialization.complete();
        }
        await tester.pump();

        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets('reopening plugins observes the existing update check', (
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
    await pumpView(tester, sourceService: sourceService);
    final currentLoader =
        tester
                .widget<PluginsSettingsView>(find.byType(PluginsSettingsView))
                .pluginLoaderService
            as _FakeLoader;
    expect(currentLoader.initializeCalls, 1);
    expect(
      find.descendant(
        of: find.byType(AppBar),
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
    expect(sourceService.updateCalls, 1);
    completion.complete();
    await tester.pumpAndSettle();
    expect(currentLoader.initializeCalls, 2);
    expect(find.byIcon(LucideIcons.settings), findsOneWidget);
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

  testWidgets(
    'Retry reviews the latest permission request before approving again',
    (tester) async {
      final service = _FakeSourceService(
        _FakeLoader(const []),
        source: PluginSource(
          kind: PluginSourceKind.githubRelease,
          repo: 'acme/plugin',
          installedAt: DateTime(2026),
          pendingUpdate: PluginPendingUpdate(
            version: '1.1.0',
            addedPermissions: const ['network'],
            detectedAt: DateTime(2026),
          ),
        ),
      )..approvalError = const SocketException('offline');
      await pumpView(tester, sourceService: service, plugins: [manifest()]);
      await tester.tap(find.text('Review'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Approve and update'));
      await tester.pumpAndSettle();
      expect(service.approvals, 1);
      service.source = service.source!.copyWith(
        pendingUpdate: PluginPendingUpdate(
          version: '1.2.0',
          addedPermissions: const ['transport.tcp'],
          detectedAt: DateTime(2026),
        ),
      );
      await tester.tap(find.text('Retry'));
      await tester.pumpAndSettle();
      expect(service.approvals, 1);
      expect(find.text('Update Sourced plugin to 1.2.0?'), findsOneWidget);
      expect(find.textContaining('transport.tcp'), findsWidgets);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(service.approvals, 1);
    },
  );

  testWidgets('a pending update changed during review is not approved', (
    tester,
  ) async {
    final service = _FakeSourceService(
      _FakeLoader(const []),
      source: PluginSource(
        kind: PluginSourceKind.githubRelease,
        repo: 'acme/plugin',
        installedAt: DateTime(2026),
        pendingUpdate: PluginPendingUpdate(
          version: '1.1.0',
          addedPermissions: const ['network'],
          detectedAt: DateTime(2026),
        ),
      ),
    );
    await pumpView(tester, sourceService: service, plugins: [manifest()]);
    await tester.tap(find.text('Review'));
    await tester.pumpAndSettle();
    service.source = service.source!.copyWith(
      pendingUpdate: PluginPendingUpdate(
        version: '1.2.0',
        addedPermissions: const ['transport.tcp'],
        detectedAt: DateTime(2026),
      ),
    );
    await tester.tap(find.text('Approve and update'));
    await tester.pumpAndSettle();
    expect(service.approvals, 0);
    expect(find.textContaining('Review its permissions again'), findsOneWidget);
  });
}
