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
  _FakeWebUIStorage(this._version);

  String _version;
  int updateCount = 0;

  WebUISkin get _skin => WebUISkin(
    id: 'streamline.js',
    name: 'Streamline',
    path: '/tmp/streamline.js',
    version: _version,
    isBundled: false,
  );

  @override
  List<WebUISkin> get installedSkins => [_skin];

  @override
  WebUISkin? get defaultSkin => _skin;

  @override
  WebUISkin? getSkin(String id) => id == _skin.id ? _skin : null;

  @override
  Future<void> updateAllSkins() async {
    updateCount++;
    _version = '0.2.3';
  }
}

void main() {
  testWidgets(
    'skins list refreshes to the new version after "Check for updates" '
    '(issues #370, #503)',
    (tester) async {
      final storage = _FakeWebUIStorage('0.2.2');

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

      expect(find.textContaining('0.2.2'), findsOneWidget);
      expect(find.textContaining('0.2.3'), findsNothing);

      final updateButton = find.text('Check for updates');
      await tester.ensureVisible(updateButton);
      await tester.tap(updateButton);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      expect(storage.updateCount, 1);
      expect(find.textContaining('0.2.3'), findsOneWidget);
      expect(find.textContaining('0.2.2'), findsNothing);
    },
  );
}
