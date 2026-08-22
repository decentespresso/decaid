import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';
import 'package:reaprime/src/launcher/launcher_view.dart';
import 'package:reaprime/src/settings/settings_controller.dart';
import 'package:reaprime/src/skin_feature/skin_view.dart';
import 'package:reaprime/src/skin_selector/skin_selector_page.dart';
import 'package:reaprime/src/webui_support/webui_service.dart';
import 'package:reaprime/src/webui_support/webui_storage.dart';
import 'package:shadcn_ui/shadcn_ui.dart';
import 'package:url_launcher_platform_interface/url_launcher_platform_interface.dart';

import 'helpers/mock_settings_service.dart';

const String _skinViewSentinel = 'SKIN VIEW SENTINEL';

final String _primaryActionLabel = Platform.isLinux
    ? 'Open in Browser'
    : 'Go to skin';

class _RecordingUrlLauncher extends Fake
    with MockPlatformInterfaceMixin
    implements UrlLauncherPlatform {
  final List<String> launched = [];

  @override
  Future<bool> canLaunch(String url) async => true;

  @override
  Future<bool> launchUrl(String url, LaunchOptions options) async {
    launched.add(url);
    return true;
  }

  @override
  Future<bool> supportsMode(PreferredLaunchMode mode) async => true;

  @override
  Future<bool> supportsCloseForMode(PreferredLaunchMode mode) async => false;
}

class _FakeWebUIService extends Fake implements WebUIService {
  _FakeWebUIService({this.serving = false});

  bool serving;
  final List<String> servedPaths = [];

  @override
  bool get isServing => serving;

  @override
  Future<void> serveFolderAtPath(String path, {int port = 3000}) async {
    servedPaths.add(path);
    serving = true;
  }

  @override
  Future<void> stopServing() async {
    serving = false;
  }
}

class _FakeWebUIStorage extends Fake implements WebUIStorage {
  final WebUISkin _skin = WebUISkin(
    id: 'streamline.js',
    name: 'Streamline',
    path: '/tmp/streamline.js',
    version: '0.2.2',
    isBundled: true,
  );

  String? defaultSkinSet;

  @override
  List<WebUISkin> get installedSkins => [_skin];

  @override
  WebUISkin? get defaultSkin => _skin;

  @override
  WebUISkin? getSkin(String id) => id == _skin.id ? _skin : null;

  @override
  Future<void> setDefaultSkin(String skinId) async {
    defaultSkinSet = skinId;
  }
}

Future<void> _pumpPage(WidgetTester tester, WebUIService service) async {
  await tester.pumpWidget(
    ShadApp(
      onGenerateRoute: (settings) {
        if (settings.name == LauncherView.routeName) {
          return MaterialPageRoute<void>(
            settings: settings,
            builder: (_) => const Scaffold(body: Text('Dashboard')),
          );
        }
        if (settings.name == SkinView.routeName) {
          return MaterialPageRoute<void>(
            settings: settings,
            builder: (_) => const Scaffold(body: Text(_skinViewSentinel)),
          );
        }
        return null;
      },
      home: ScaffoldMessenger(
        child: SkinSelectorPage(
          settingsController: SettingsController(MockSettingsService()),
          webUIService: service,
          webUIStorage: _FakeWebUIStorage(),
        ),
      ),
    ),
  );
  await tester.pump();
}

void main() {
  late _RecordingUrlLauncher launcher;
  late UrlLauncherPlatform original;

  setUp(() {
    original = UrlLauncherPlatform.instance;
    launcher = _RecordingUrlLauncher();
    UrlLauncherPlatform.instance = launcher;
  });

  tearDown(() {
    UrlLauncherPlatform.instance = original;
  });

  testWidgets('renders a "Go to skin" button below the skin selector', (
    tester,
  ) async {
    await _pumpPage(tester, _FakeWebUIService(serving: false));

    expect(find.text(_primaryActionLabel), findsOneWidget);
  });

  testWidgets('server controls are the quiet footer, not the primary action', (
    tester,
  ) async {
    await _pumpPage(tester, _FakeWebUIService(serving: true));

    expect(find.text('Stop server'), findsOneWidget);
    if (!Platform.isLinux) {
      expect(find.text('Open in browser'), findsOneWidget);
    }
    expect(find.text('Start server'), findsNothing);
    expect(find.text('Check for updates'), findsOneWidget);
  });

  testWidgets('server footer offers "Start server" when stopped', (
    tester,
  ) async {
    await _pumpPage(tester, _FakeWebUIService(serving: false));

    expect(find.text('Start server'), findsOneWidget);
    expect(find.text('Stop server'), findsNothing);
  });

  testWidgets('tapping "Go to skin" while serving opens the skin in-app '
      '(external browser on Linux)', (tester) async {
    await _pumpPage(tester, _FakeWebUIService(serving: true));

    final button = find.text(_primaryActionLabel);
    await tester.ensureVisible(button);
    await tester.tap(button);
    await tester.pump();
    await tester.pumpAndSettle();

    if (Platform.isLinux) {
      expect(launcher.launched, hasLength(1));
      expect(launcher.launched.single, contains('localhost:3000'));
      expect(find.text(_skinViewSentinel), findsNothing);
    } else {
      expect(find.text(_skinViewSentinel), findsOneWidget);
      expect(launcher.launched, isEmpty);
    }
  });

  testWidgets(
    'tapping "Go to skin" while stopped starts the selected skin then opens it',
    (tester) async {
      final service = _FakeWebUIService(serving: false);
      await _pumpPage(tester, service);

      final button = find.text(_primaryActionLabel);
      await tester.ensureVisible(button);
      await tester.tap(button);
      await tester.pump();
      await tester.pumpAndSettle();

      expect(service.servedPaths, ['/tmp/streamline.js']);

      if (Platform.isLinux) {
        expect(launcher.launched, hasLength(1));
      } else {
        expect(find.text(_skinViewSentinel), findsOneWidget);
      }
    },
  );
}
