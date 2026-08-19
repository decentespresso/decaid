import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/account/account_consent_prompter.dart';
import 'package:reaprime/src/services/account/account_consent_store.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

void main() {
  late GlobalKey<NavigatorState> navigatorKey;

  setUp(() {
    navigatorKey = GlobalKey<NavigatorState>();
  });

  Future<void> pumpApp(WidgetTester tester) {
    return tester.pumpWidget(
      ShadApp(
        navigatorKey: navigatorKey,
        home: const Scaffold(body: SizedBox.expand(child: Text('Skin view'))),
      ),
    );
  }

  testWidgets('allows from a trusted native dialog over the active view', (
    tester,
  ) async {
    await pumpApp(tester);
    final prompter = AccountConsentPrompter(navigatorKey: navigatorKey);

    final result = prompter.prompt('Aileen');
    await tester.pumpAndSettle();

    expect(find.text('Skin view'), findsOneWidget);
    expect(find.text('Decent account access'), findsOneWidget);
    expect(
      find.text('Aileen wants to use your linked Decent account.'),
      findsOneWidget,
    );
    await tester.tap(find.text('Allow'));
    await tester.pumpAndSettle();

    expect(await result, AccountConsentDecision.allowed);
  });

  testWidgets('returns an explicit denial', (tester) async {
    await pumpApp(tester);
    final prompter = AccountConsentPrompter(navigatorKey: navigatorKey);

    final result = prompter.prompt('Plugin "dye2"');
    await tester.pumpAndSettle();
    await tester.tap(find.text('Deny'));
    await tester.pumpAndSettle();

    expect(await result, AccountConsentDecision.denied);
  });

  testWidgets('timeout closes the prompt without a persisted decision', (
    tester,
  ) async {
    await pumpApp(tester);
    final prompter = AccountConsentPrompter(
      navigatorKey: navigatorKey,
      timeout: const Duration(milliseconds: 20),
    );

    final result = prompter.prompt('Aileen');
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 20));
    await tester.pumpAndSettle();

    expect(await result, isNull);
    expect(find.text('Decent account access'), findsNothing);
  });

  test('no attached navigator denies without showing UI', () async {
    final prompter = AccountConsentPrompter(navigatorKey: navigatorKey);

    expect(await prompter.prompt('Aileen'), isNull);
  });
}
