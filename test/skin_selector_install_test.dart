import 'dart:async';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:file_picker/src/platform/file_picker_platform_interface.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/settings/settings_controller.dart';
import 'package:reaprime/src/skin_selector/skin_selector_page.dart';
import 'package:reaprime/src/webui_support/webui_service.dart';
import 'package:reaprime/src/webui_support/webui_storage.dart';
import 'package:shadcn_ui/shadcn_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'helpers/mock_settings_service.dart';

class _ZipPicker extends FilePickerPlatform {
  @override
  Future<FilePickerResult?> pickFiles({
    String? dialogTitle,
    String? initialDirectory,
    FileType type = FileType.any,
    List<String>? allowedExtensions,
    Function(FilePickerStatus)? onFileLoading,
    int compressionQuality = 0,
    bool allowMultiple = false,
    bool withData = false,
    bool withReadStream = false,
    bool lockParentWindow = false,
    bool readSequential = false,
    bool cancelUploadOnWindowBlur = true,
  }) async => FilePickerResult([
    PlatformFile(name: 'skin.zip', size: 0, path: '/private/skin.zip'),
  ]);
}

class _FakeWebUIService extends Fake implements WebUIService {
  @override
  bool get isServing => false;
}

class _FakeWebUIStorage extends Fake implements WebUIStorage {
  @override
  final ValueNotifier<Future<void>?> updateCheck = ValueNotifier(null);

  _FakeWebUIStorage({WebUISkin? skin})
    : _skins = [
        skin ??
            WebUISkin(
              id: 'streamline.js',
              name: 'Streamline',
              path: '/tmp/streamline.js',
              version: '0.2.2',
              isBundled: true,
            ),
      ];

  final List<WebUISkin> _skins;

  String? releaseRepo;
  String? releaseAsset;
  String? branchRepo;
  String? branchName;
  Object? installError;
  int installCalls = 0;
  Completer<void>? installGate;

  @override
  List<WebUISkin> get installedSkins => _skins;

  @override
  WebUISkin? get defaultSkin => _skins.first;

  @override
  WebUISkin? getSkin(String id) =>
      _skins.where((skin) => skin.id == id).firstOrNull;

  @override
  Future<String> installFromPath(
    String path, {
    bool overwriteIfExists = true,
  }) async {
    if (installError != null) throw installError!;
    return _skins.first.id;
  }

  @override
  Future<void> installFromGitHubRelease(
    String repo, {
    String? assetName,
    bool includePrerelease = false,
  }) async {
    installCalls++;
    await installGate?.future;
    if (installError != null) throw installError!;
    releaseRepo = repo;
    releaseAsset = assetName;
    _skins.add(
      WebUISkin(
        id: 'custom-skin',
        name: 'Custom Skin',
        path: '/tmp/custom-skin',
        version: '1.0.0',
        isBundled: false,
      ),
    );
  }

  @override
  Future<void> installFromGitHub(String repo, {String branch = 'main'}) async {
    installCalls++;
    await installGate?.future;
    if (installError != null) throw installError!;
    branchRepo = repo;
    branchName = branch;
    _skins.add(
      WebUISkin(
        id: 'custom-skin',
        name: 'Custom Skin',
        path: '/tmp/custom-skin',
        version: '1.0.0',
        isBundled: false,
      ),
    );
  }
}

Future<void> _pumpPage(WidgetTester tester, _FakeWebUIStorage storage) async {
  await tester.pumpWidget(
    ShadApp(
      home: ScaffoldMessenger(
        child: SkinSelectorPage(
          settingsController: SettingsController(MockSettingsService()),
          webUIService: _FakeWebUIService(),
          webUIStorage: storage,
        ),
      ),
    ),
  );
  await tester.pump();
}

Future<void> _openInstallMenu(WidgetTester tester, String item) async {
  await tester.tap(find.byTooltip('Skin actions'));
  await tester.pumpAndSettle();
  await tester.tap(find.text('Install skin'));
  await tester.pumpAndSettle();
  await tester.tap(find.text(item));
  await tester.pumpAndSettle();
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('local skin ZIP failure hides filesystem diagnostics', (
    tester,
  ) async {
    final picker = FilePickerPlatform.instance;
    FilePickerPlatform.instance = _ZipPicker();
    addTearDown(() => FilePickerPlatform.instance = picker);
    final storage = _FakeWebUIStorage()
      ..installError = const FileSystemException(
        'private filesystem diagnostics',
        '/private/skin.zip',
      );
    await _pumpPage(tester, storage);

    await _openInstallMenu(tester, 'ZIP file');

    expect(
      find.text(
        "Couldn't install the skin. Check storage space and file permissions, then try again.",
      ),
      findsOneWidget,
    );
    expect(find.textContaining('private'), findsNothing);
    expect(find.textContaining('FileSystemException'), findsNothing);
  });

  testWidgets('the skin installation submenu fits a narrow screen', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await _pumpPage(tester, _FakeWebUIStorage());

    await tester.tap(find.byTooltip('Skin actions'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Install skin'));
    await tester.pumpAndSettle();
    expect(find.text('GitHub Release').hitTestable(), findsOneWidget);
    expect(find.text('ZIP file').hitTestable(), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('skin actions group updates and all installation sources', (
    tester,
  ) async {
    await _pumpPage(tester, _FakeWebUIStorage());

    expect(find.text('Check for updates'), findsNothing);
    expect(find.byTooltip('Install skin'), findsNothing);
    final cogwheel = find.widgetWithIcon(IconButton, LucideIcons.settings);
    final button = tester.widget<IconButton>(cogwheel);
    expect(button.iconSize, 28);
    expect(
      button.color,
      ShadTheme.of(tester.element(cogwheel)).colorScheme.primary,
    );
    await tester.tap(find.byTooltip('Skin actions'));
    await tester.pumpAndSettle();
    expect(find.text('Check for updates'), findsOneWidget);
    expect(find.text('Install skin'), findsOneWidget);
    await tester.tap(find.text('Install skin'));
    await tester.pumpAndSettle();
    expect(find.text('GitHub Release'), findsOneWidget);
    expect(find.text('GitHub Branch'), findsOneWidget);
    expect(find.text('ZIP file'), findsOneWidget);
    expect(find.text('Advanced'), findsNothing);
  });

  testWidgets('long removable skin names fit the narrow dropdown', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    const name = 'A very long custom skin name for a narrow display';
    final storage = _FakeWebUIStorage(
      skin: WebUISkin(
        id: 'long-custom-skin',
        name: name,
        path: '/tmp/long-custom-skin',
        version: '1.2.3',
        isBundled: false,
      ),
    );
    await _pumpPage(tester, storage);
    expect(tester.takeException(), isNull);

    await tester.tap(find.byType(DropdownButton<String>).first);
    await tester.pumpAndSettle();
    expect(find.byTooltip('Remove $name').hitTestable(), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('install menu installs a skin from a GitHub release', (
    tester,
  ) async {
    final storage = _FakeWebUIStorage();
    await _pumpPage(tester, storage);

    await _openInstallMenu(tester, 'GitHub Release');

    await tester.enterText(find.byType(TextField).at(0), 'tadelv/passione');
    await tester.enterText(find.byType(TextField).at(1), 'passione.zip');
    await tester.tap(find.text('Install'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(storage.releaseRepo, 'tadelv/passione');
    expect(storage.releaseAsset, 'passione.zip');
    expect(find.text('Skin installed from GitHub'), findsOneWidget);

    // the installed skin is visible after the selector rebuilds
    await tester.tap(find.byType(DropdownButton<String>).first);
    await tester.pumpAndSettle();
    expect(find.text('Custom Skin'), findsOneWidget);
  });

  testWidgets('install menu installs a skin from a GitHub branch', (
    tester,
  ) async {
    final storage = _FakeWebUIStorage();
    await _pumpPage(tester, storage);

    await _openInstallMenu(tester, 'GitHub Branch');

    await tester.enterText(find.byType(TextField).at(0), 'tadelv/passione');
    await tester.enterText(find.byType(TextField).at(1), 'dev');
    await tester.tap(find.text('Install'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(storage.branchRepo, 'tadelv/passione');
    expect(storage.branchName, 'dev');
    expect(find.text('Skin installed from GitHub'), findsOneWidget);

    // the installed skin is visible after the selector rebuilds
    await tester.tap(find.byType(DropdownButton<String>).first);
    await tester.pumpAndSettle();
    expect(find.text('Custom Skin'), findsOneWidget);
  });

  testWidgets('empty branch defaults to main', (tester) async {
    final storage = _FakeWebUIStorage();
    await _pumpPage(tester, storage);

    await _openInstallMenu(tester, 'GitHub Branch');

    await tester.enterText(find.byType(TextField).at(0), 'tadelv/passione');
    // explicitly clear the pre-filled branch field so the default path runs
    await tester.enterText(find.byType(TextField).at(1), '');
    await tester.tap(find.text('Install'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(storage.branchRepo, 'tadelv/passione');
    expect(storage.branchName, 'main');
  });

  testWidgets('install failure surfaces the storage error', (tester) async {
    final storage = _FakeWebUIStorage()
      ..installError = Exception('No .zip asset found in release');
    await _pumpPage(tester, storage);

    await _openInstallMenu(tester, 'GitHub Release');

    await tester.enterText(find.byType(TextField).at(0), 'acme/custom-skin');
    await tester.tap(find.text('Install'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.textContaining("Couldn't install the skin"), findsOneWidget);
  });

  testWidgets('offline install retries the same repository and asset', (
    tester,
  ) async {
    final storage = _FakeWebUIStorage()
      ..installError = const SocketException(
        'Failed host lookup: api.github.com',
      );
    await _pumpPage(tester, storage);
    await _openInstallMenu(tester, 'GitHub Release');
    await tester.enterText(find.byType(TextField).at(0), 'acme/custom-skin');
    await tester.enterText(find.byType(TextField).at(1), 'custom.zip');
    await tester.tap(find.text('Install'));
    await tester.pumpAndSettle();
    expect(
      find.text(
        "Couldn't install the skin. Check your internet connection and try again.",
      ),
      findsOneWidget,
    );
    expect(find.textContaining('SocketException'), findsNothing);
    storage.installError = null;
    final gate = Completer<void>();
    storage.installGate = gate;
    final retry = tester
        .widget<SnackBarAction>(find.byType(SnackBarAction))
        .onPressed;
    await tester.tap(find.text('Retry'));
    retry();
    await tester.pump();
    expect(storage.installCalls, 2);
    gate.complete();
    await tester.pumpAndSettle();
    expect(storage.installCalls, 2);
    expect(storage.releaseRepo, 'acme/custom-skin');
    expect(storage.releaseAsset, 'custom.zip');
    expect(find.byType(TextField), findsNothing);
    expect(find.text('Skin installed from GitHub'), findsOneWidget);
  });

  testWidgets(
    'installation completion after disposal does not update the page',
    (tester) async {
      final gate = Completer<void>();
      final storage = _FakeWebUIStorage()..installGate = gate;
      await _pumpPage(tester, storage);
      await _openInstallMenu(tester, 'GitHub Release');
      await tester.enterText(find.byType(TextField).at(0), 'acme/custom-skin');
      await tester.tap(find.text('Install'));
      await tester.pumpAndSettle();
      await tester.pumpWidget(const SizedBox.shrink());
      gate.complete();
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    },
  );
}
