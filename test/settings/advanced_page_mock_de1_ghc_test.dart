import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/services/account/decent_account_service.dart';
import 'package:reaprime/src/services/github_credentials.dart';
import 'package:reaprime/src/settings/advanced_page.dart';
import 'package:reaprime/src/settings/settings_controller.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

import '../helpers/mock_settings_service.dart';

class _Store implements CredentialStore {
  @override
  Future<String?> read({required String key}) async => null;

  @override
  Future<void> write({required String key, required String value}) async {}

  @override
  Future<void> delete({required String key}) async {}
}

void main() {
  testWidgets('Mock DE1 GHC switch under Simulated Devices toggles setting', (
    tester,
  ) async {
    final controller = SettingsController(MockSettingsService());
    addTearDown(controller.dispose);
    await controller.loadSettings();

    await tester.pumpWidget(
      ShadApp(
        home: AdvancedPage(
          controller: controller,
          credentials: GithubCredentialProvider(store: _Store()),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final label = find.text('Mock DE1: GHC on');
    await tester.scrollUntilVisible(label, 200);
    expect(
      tester.getTopLeft(label).dy,
      greaterThan(tester.getTopLeft(find.text('Simulated Devices')).dy),
    );
    expect(controller.mockDe1GhcPresent, isFalse);

    final toggle = find.ancestor(of: label, matching: find.byType(ShadSwitch));
    await tester.tapAt(
      tester.getTopLeft(toggle) + Offset(12, tester.getSize(toggle).height / 2),
    );
    await tester.pumpAndSettle();

    expect(controller.mockDe1GhcPresent, isTrue);
  });
}
