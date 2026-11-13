import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/services/account/decent_account_service.dart';
import 'package:reaprime/src/services/github_credentials.dart';
import 'package:reaprime/src/settings/advanced_page.dart';
import 'package:reaprime/src/settings/github_token_section.dart';
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
  testWidgets('places the GitHub token section at the bottom', (tester) async {
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

    final list = tester.widget<ListView>(find.byType(ListView));
    final children =
        (list.childrenDelegate as SliverChildListDelegate).children;
    final sectionIndex = children.indexWhere(
      (child) => child is GithubTokenSection,
    );
    final exitIndex = children.indexWhere(
      (child) =>
          child is ListTile &&
          child.title is Text &&
          (child.title! as Text).data == 'Exit Decaid',
    );
    expect(sectionIndex, greaterThan(exitIndex));
    expect(sectionIndex, children.length - 1);
  });
}
