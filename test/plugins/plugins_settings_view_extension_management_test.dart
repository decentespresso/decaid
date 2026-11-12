import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:file_picker/src/platform/file_picker_platform_interface.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/plugins/plugin_loader_service.dart';
import 'package:reaprime/src/plugins/plugin_manifest.dart';
import 'package:reaprime/src/plugins/plugin_package.dart';
import 'package:reaprime/src/plugins/plugin_source.dart';
import 'package:reaprime/src/plugins/plugin_source_service.dart';
import 'package:reaprime/src/settings/plugins_settings_view.dart';
import 'package:reaprime/src/widgets/page_action_menu.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

const _pluginId = 'manager.reaplugin';

class _FolderPicker extends FilePickerPlatform {
  _FolderPicker(this.selected);

  final String selected;

  @override
  Future<String?> getDirectoryPath({
    String? dialogTitle,
    bool lockParentWindow = false,
    String? initialDirectory,
  }) async => selected;
}

class _InstallingLoader extends Fake implements PluginLoaderService {
  _InstallingLoader(this.root, [List<PluginManifest> plugins = const []])
    : plugins = [...plugins];

  final Directory root;
  final List<PluginManifest> plugins;
  final List<PluginManifest> installed = [];

  @override
  Future<void> initialize() async {}

  @override
  List<PluginManifest> get availablePlugins => plugins;

  @override
  bool isPluginLoaded(String pluginId) => false;

  @override
  Future<bool> shouldAutoLoad(String pluginId) async => false;

  @override
  String getPluginDirectory(String pluginId) => '${root.path}/$pluginId';

  @override
  PluginManifest? getPluginManifest(String pluginId) {
    for (final plugin in plugins) {
      if (plugin.id == pluginId) return plugin;
    }
    return null;
  }

  @override
  Future<PluginManifest> installPluginPackage(
    Directory stagedDir, {
    bool allowDowngrade = false,
  }) async {
    final manifest = resolvePluginPackage(stagedDir).manifest;
    Directory(getPluginDirectory(manifest.id)).createSync(recursive: true);
    installed.add(manifest);
    plugins
      ..removeWhere((plugin) => plugin.id == manifest.id)
      ..add(manifest);
    return manifest;
  }
}

class _LocalReleaseSourceService extends PluginSourceService {
  _LocalReleaseSourceService(super.loader, {required this.releaseFolder});

  final String releaseFolder;
  final List<String> folderInstalls = [];
  final StreamController<void> approvalRequested = StreamController.broadcast();

  @override
  Future<PluginManifest> installFromGitHubRelease(
    String repo, {
    String? assetName,
    bool includePrerelease = false,
    ExtensionManagementApproval? approveExtensionManagement,
  }) => installFromFolder(
    releaseFolder,
    approveExtensionManagement: approveExtensionManagement,
  );

  @override
  Future<PluginManifest> installFromFolder(
    String folderPath, {
    ExtensionManagementApproval? approveExtensionManagement,
  }) {
    folderInstalls.add(folderPath);
    return super.installFromFolder(
      folderPath,
      approveExtensionManagement: approveExtensionManagement == null
          ? null
          : (candidate) {
              approvalRequested.add(null);
              return approveExtensionManagement(candidate);
            },
    );
  }
}

class _PendingUpdateSourceService extends PluginSourceService {
  _PendingUpdateSourceService(super.loader, this.source);

  final PluginSource source;

  @override
  PluginSource? sourceFor(String pluginId) => source;
}

PluginManifest _manifest({Set<PluginPermissions> permissions = const {}}) =>
    PluginManifest(
      id: _pluginId,
      name: 'Manager plugin',
      author: 'Test',
      description: 'A plugin that manages extensions',
      version: '1.0.0',
      apiVersion: 1,
      permissions: permissions,
      settings: const {},
      api: null,
    );

void main() {
  late Directory tempDir;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('plugins_view_extensions');
  });

  tearDown(() {
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });

  String pluginFolder({List<String> permissions = const []}) {
    final dir = Directory('${tempDir.path}/picked/$_pluginId')
      ..createSync(recursive: true);
    File('${dir.path}/manifest.json').writeAsStringSync(
      jsonEncode({
        'id': _pluginId,
        'author': 'Test',
        'name': 'Manager plugin',
        'description': 'Test plugin',
        'version': '1.0.0',
        'apiVersion': 1,
        'permissions': permissions,
        'settings': <String, dynamic>{},
        'api': <Object>[],
      }),
    );
    File('${dir.path}/plugin.js')
        .writeAsStringSync('function createPlugin() { return {}; }');
    return dir.path;
  }

  Future<void> pumpView(
    WidgetTester tester, {
    required PluginLoaderService loader,
    required PluginSourceService sourceService,
  }) async {
    await tester.pumpWidget(
      ShadApp(
        home: ScaffoldMessenger(
          child: PluginsSettingsView(
            pluginLoaderService: loader,
            pluginSourceService: sourceService,
          ),
        ),
      ),
    );
    await tester.pump();
  }

  Future<void> startReleaseInstall(WidgetTester tester) async {
    await tester.tap(find.byTooltip('Plugin actions'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Install plugin'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('GitHub Release'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).at(0), 'acme/manager');
    await tester.tap(find.text('Install'));
    await tester.pumpAndSettle();
  }

  group('plugin card', () {
    testWidgets('warns about a plugin holding manage.extensions', (
      tester,
    ) async {
      final loader = _InstallingLoader(tempDir, [
        _manifest(permissions: {PluginPermissions.manageExtensions}),
      ]);
      await pumpView(
        tester,
        loader: loader,
        sourceService: PluginSourceService(loader),
      );

      expect(find.byType(ExtensionManagementWarning), findsOneWidget);
      expect(find.text(ExtensionManagementWarning.message), findsOneWidget);
    });

    testWidgets('does not warn about a plugin without manage.extensions', (
      tester,
    ) async {
      final loader = _InstallingLoader(tempDir, [
        _manifest(permissions: {PluginPermissions.log}),
      ]);
      await pumpView(
        tester,
        loader: loader,
        sourceService: PluginSourceService(loader),
      );

      expect(find.text('Manager plugin'), findsOneWidget);
      expect(find.byType(ExtensionManagementWarning), findsNothing);
    });
  });

  group('pending update approval', () {
    PluginSource sourceAdding(List<String> permissions) => PluginSource(
      kind: PluginSourceKind.githubRelease,
      repo: 'acme/manager',
      releaseTag: 'v1.0.0',
      installedAt: DateTime(2026, 1, 1),
      pendingUpdate: PluginPendingUpdate(
        version: '1.1.0',
        releaseTag: 'v1.1.0',
        addedPermissions: permissions,
        detectedAt: DateTime(2026, 1, 2),
      ),
    );

    testWidgets('warns when the update adds manage.extensions', (tester) async {
      final loader = _InstallingLoader(tempDir, [_manifest()]);
      await pumpView(
        tester,
        loader: loader,
        sourceService: _PendingUpdateSourceService(
          loader,
          sourceAdding([PluginPermissions.manageExtensions.wireName]),
        ),
      );
      expect(find.byType(ExtensionManagementWarning), findsNothing);

      await tester.tap(find.text('Review'));
      await tester.pumpAndSettle();

      expect(
        find.descendant(
          of: find.byType(AlertDialog),
          matching: find.byType(ExtensionManagementWarning),
        ),
        findsOneWidget,
      );
    });

    testWidgets('does not warn when the update adds other permissions', (
      tester,
    ) async {
      final loader = _InstallingLoader(tempDir, [_manifest()]);
      await pumpView(
        tester,
        loader: loader,
        sourceService: _PendingUpdateSourceService(
          loader,
          sourceAdding([PluginPermissions.proxyDecentApi.wireName]),
        ),
      );

      await tester.tap(find.text('Review'));
      await tester.pumpAndSettle();

      expect(find.byType(AlertDialog), findsOneWidget);
      expect(find.byType(ExtensionManagementWarning), findsNothing);
    });
  });

  group('native install of a plugin requesting manage.extensions', () {
    testWidgets('asks first, and Cancel installs nothing without an error', (
      tester,
    ) async {
      final loader = _InstallingLoader(tempDir);
      final sourceService = _LocalReleaseSourceService(
        loader,
        releaseFolder: pluginFolder(
          permissions: [PluginPermissions.manageExtensions.wireName],
        ),
      );
      await pumpView(tester, loader: loader, sourceService: sourceService);

      await startReleaseInstall(tester);

      expect(
        find.text('Allow Manager plugin to manage plugins and skins?'),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: find.byType(AlertDialog),
          matching: find.byType(ExtensionManagementWarning),
        ),
        findsOneWidget,
      );
      expect(loader.installed, isEmpty);

      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();

      expect(loader.installed, isEmpty);
      expect(find.byType(AlertDialog), findsNothing);
      expect(find.byType(SnackBar), findsNothing);
      expect(find.text('Manager plugin'), findsNothing);
    });

    testWidgets('Allow and install installs the plugin', (tester) async {
      final loader = _InstallingLoader(tempDir);
      final sourceService = _LocalReleaseSourceService(
        loader,
        releaseFolder: pluginFolder(
          permissions: [PluginPermissions.manageExtensions.wireName],
        ),
      );
      await pumpView(tester, loader: loader, sourceService: sourceService);

      await startReleaseInstall(tester);
      await tester.tap(find.byKey(const Key('approve-extension-management')));
      await tester.pumpAndSettle();

      expect(loader.installed.map((m) => m.id), [_pluginId]);
      expect(find.text('Plugin installed: Manager plugin'), findsOneWidget);
      expect(find.byType(ExtensionManagementWarning), findsOneWidget);
    });

    testWidgets('a plugin without the permission installs without asking', (
      tester,
    ) async {
      final loader = _InstallingLoader(tempDir);
      final sourceService = _LocalReleaseSourceService(
        loader,
        releaseFolder: pluginFolder(
          permissions: [PluginPermissions.log.wireName],
        ),
      );
      await pumpView(tester, loader: loader, sourceService: sourceService);

      await startReleaseInstall(tester);

      expect(
        find.byKey(const Key('approve-extension-management')),
        findsNothing,
      );
      expect(loader.installed.map((m) => m.id), [_pluginId]);
      expect(find.text('Plugin installed: Manager plugin'), findsOneWidget);
    });

    for (final approve in [false, true]) {
      testWidgets(
        'a folder install ${approve ? 'installs once allowed' : 'is dropped on Cancel'}',
        (tester) async {
          final picker = FilePickerPlatform.instance;
          FilePickerPlatform.instance = _FolderPicker(
            pluginFolder(
              permissions: [PluginPermissions.manageExtensions.wireName],
            ),
          );
          addTearDown(() => FilePickerPlatform.instance = picker);
          final loader = _InstallingLoader(tempDir);
          final sourceService = _LocalReleaseSourceService(
            loader,
            releaseFolder: '',
          );
          await pumpView(tester, loader: loader, sourceService: sourceService);
          final install = tester
              .widget<PageActionMenu>(find.byType(PageActionMenu))
              .onInstall!;

          await tester.runAsync(() async {
            final asked = sourceService.approvalRequested.stream.first;
            install('folder');
            await asked.timeout(const Duration(seconds: 10));
          });
          await tester.pumpAndSettle();

          expect(
            find.text('Allow Manager plugin to manage plugins and skins?'),
            findsOneWidget,
          );
          await tester.tap(
            approve
                ? find.byKey(const Key('approve-extension-management'))
                : find.text('Cancel'),
          );
          await tester.pumpAndSettle();
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 200)),
          );
          await tester.pumpAndSettle();

          expect(sourceService.folderInstalls, hasLength(1));
          if (approve) {
            expect(loader.installed.map((m) => m.id), [_pluginId]);
            expect(find.text('Plugin installed successfully'), findsOneWidget);
          } else {
            expect(loader.installed, isEmpty);
            expect(find.byType(SnackBar), findsNothing);
          }
        },
      );
    }
  });
}
