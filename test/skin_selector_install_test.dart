import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/settings/settings_controller.dart';
import 'package:reaprime/src/skin_selector/skin_selector_page.dart';
import 'package:reaprime/src/webui_support/webui_service.dart';
import 'package:reaprime/src/webui_support/webui_storage.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

import 'helpers/mock_settings_service.dart';

class _FakeWebUIService extends Fake implements WebUIService {
  @override
  bool get isServing => false;
}

class _FakeWebUIStorage extends Fake implements WebUIStorage {
  final WebUISkin _skin = WebUISkin(
    id: 'streamline.js',
    name: 'Streamline',
    path: '/tmp/streamline.js',
    version: '0.2.2',
    isBundled: true,
  );

  String? releaseRepo;
  String? releaseAsset;
  String? branchRepo;
  String? branchName;
  Object? installError;

  @override
  List<WebUISkin> get installedSkins => [_skin];

  @override
  WebUISkin? get defaultSkin => _skin;

  @override
  Future<void> installFromGitHubRelease(
    String repo, {
    String? assetName,
    bool includePrerelease = false,
  }) async {
    if (installError != null) throw installError!;
    releaseRepo = repo;
    releaseAsset = assetName;
  }

  @override
  Future<void> installFromGitHub(String repo, {String branch = 'main'}) async {
    if (installError != null) throw installError!;
    branchRepo = repo;
    branchName = branch;
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
  await tester.tap(find.byIcon(Icons.add));
  await tester.pumpAndSettle();
  await tester.tap(find.text(item));
  await tester.pumpAndSettle();
}

void main() {
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
  });

  testWidgets('empty branch defaults to main', (tester) async {
    final storage = _FakeWebUIStorage();
    await _pumpPage(tester, storage);

    await _openInstallMenu(tester, 'GitHub Branch');

    await tester.enterText(find.byType(TextField).at(0), 'tadelv/passione');
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

    expect(find.textContaining('Failed to install skin'), findsOneWidget);
  });
}
