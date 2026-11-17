import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/account/account_tokens_section.dart';
import 'package:reaprime/src/controllers/account_tokens_controller.dart';
import 'package:reaprime/src/services/account/decent_account_service.dart'
    show CredentialStore;
import 'package:reaprime/src/services/account/proxy_token_service.dart';
import 'package:reaprime/src/services/account/proxy_token_store.dart';

class _FakeCredentialStore implements CredentialStore {
  final Map<String, String> _data = {};
  @override
  Future<String?> read({required String key}) async => _data[key];
  @override
  Future<void> write({required String key, required String value}) async =>
      _data[key] = value;
  @override
  Future<void> delete({required String key}) async => _data.remove(key);
}

void main() {
  late ProxyTokenService service;
  late AccountTokensController controller;

  setUp(() {
    service = ProxyTokenService();
    controller = AccountTokensController(
      tokenService: service,
      store: ProxyTokenStore(credentialStore: _FakeCredentialStore()),
    );
  });

  Widget harness() => MaterialApp(
    home: Scaffold(body: AccountTokensSection(controller: controller)),
  );

  testWidgets('create -> show once -> list, then revoke', (tester) async {
    await tester.pumpWidget(harness());
    expect(find.text('No tokens yet.'), findsOneWidget);

    await tester.tap(find.byKey(const Key('create-token')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'laptop');
    await tester.tap(
      find.descendant(
        of: find.byType(AlertDialog),
        matching: find.text('Create'),
      ),
    );
    await tester.pumpAndSettle();

    final shown = tester.widget<SelectableText>(
      find.byKey(const Key('token-value')),
    );
    final tokenValue = shown.data!;
    expect(service.validate(tokenValue), isNotNull);

    await tester.tap(find.text('Done'));
    await tester.pumpAndSettle();

    expect(find.text('laptop'), findsOneWidget);
    expect(find.text('read'), findsOneWidget);

    await tester.tap(find.byKey(const Key('revoke-laptop')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Revoke'));
    await tester.pumpAndSettle();

    expect(find.text('laptop'), findsNothing);
    expect(find.text('No tokens yet.'), findsOneWidget);
    expect(service.validate(tokenValue), isNull);
  });

  testWidgets('create with write toggle mints a write-scoped token', (
    tester,
  ) async {
    await tester.pumpWidget(harness());

    await tester.tap(find.byKey(const Key('create-token')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'writer');
    await tester.tap(find.byKey(const Key('token-write-toggle')));
    await tester.pumpAndSettle();
    await tester.tap(
      find.descendant(
        of: find.byType(AlertDialog),
        matching: find.text('Create'),
      ),
    );
    await tester.pumpAndSettle();

    final shown = tester.widget<SelectableText>(
      find.byKey(const Key('token-value')),
    );
    final caller = service.validate(shown.data!);
    expect(caller, isNotNull);
    expect(
      caller!.scopes.contains(ProxyTokenService.scopeAccountProxyWrite),
      isTrue,
    );

    await tester.tap(find.text('Done'));
    await tester.pumpAndSettle();

    expect(find.text('writer'), findsOneWidget);
    expect(find.text('read + write'), findsOneWidget);
  });

  Future<void> openCreateDialog(WidgetTester tester, String label) async {
    await tester.tap(find.byKey(const Key('create-token')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), label);
  }

  Future<void> submitCreateDialog(WidgetTester tester) async {
    await tester.tap(
      find.descendant(
        of: find.byType(AlertDialog),
        matching: find.text('Create'),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets(
    'turning on plugin and skin management shows the warning instead of write',
    (tester) async {
      await tester.pumpWidget(harness());
      await openCreateDialog(tester, 'deploy');

      expect(find.byKey(const Key('token-write-toggle')), findsOneWidget);
      expect(find.byKey(const Key('token-extensions-warning')), findsNothing);

      await tester.tap(find.byKey(const Key('token-extensions-toggle')));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('token-extensions-warning')), findsOneWidget);
      expect(find.byKey(const Key('token-write-toggle')), findsNothing);

      await tester.tap(find.byKey(const Key('token-extensions-toggle')));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('token-write-toggle')), findsOneWidget);
      expect(find.byKey(const Key('token-extensions-warning')), findsNothing);
    },
  );

  testWidgets('creating a management token shows it once and lists its scope', (
    tester,
  ) async {
    await tester.pumpWidget(harness());
    await openCreateDialog(tester, 'deploy');
    await tester.tap(find.byKey(const Key('token-extensions-toggle')));
    await tester.pumpAndSettle();
    await submitCreateDialog(tester);

    final tokenValue = tester
        .widget<SelectableText>(find.byKey(const Key('token-value')))
        .data!;
    final caller = service.validate(tokenValue)!;
    expect(caller.scopes, {ProxyTokenService.scopeExtensionsManage});
    expect(caller.label, 'deploy');

    await tester.tap(find.text('Done'));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('token-value')), findsNothing);
    expect(find.textContaining(tokenValue), findsNothing);
    expect(
      find.byWidgetPredicate(
        (widget) =>
            (widget is SelectableText && widget.data == tokenValue) ||
            (widget is EditableText &&
                widget.controller.text.contains(tokenValue)),
      ),
      findsNothing,
    );
    expect(find.text('deploy'), findsOneWidget);
    expect(find.text('plugin and skin management'), findsOneWidget);

    await tester.tap(find.byKey(const Key('revoke-deploy')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Revoke'));
    await tester.pumpAndSettle();

    expect(find.text('deploy'), findsNothing);
    expect(find.text('No tokens yet.'), findsOneWidget);
    expect(service.validate(tokenValue), isNull);
  });

  testWidgets('a write choice made before turning on management is dropped', (
    tester,
  ) async {
    await tester.pumpWidget(harness());
    await openCreateDialog(tester, 'deploy');
    await tester.tap(find.byKey(const Key('token-write-toggle')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('token-extensions-toggle')));
    await tester.pumpAndSettle();
    await submitCreateDialog(tester);

    final tokenValue = tester
        .widget<SelectableText>(find.byKey(const Key('token-value')))
        .data!;
    expect(service.validate(tokenValue)!.scopes, {
      ProxyTokenService.scopeExtensionsManage,
    });
  });

  testWidgets('an account token is not shown again after the dialog closes', (
    tester,
  ) async {
    await tester.pumpWidget(harness());
    await openCreateDialog(tester, 'laptop');
    await submitCreateDialog(tester);

    final tokenValue = tester
        .widget<SelectableText>(find.byKey(const Key('token-value')))
        .data!;
    expect(
      service.validate(tokenValue)!.scopes,
      isNot(contains(ProxyTokenService.scopeExtensionsManage)),
    );

    await tester.tap(find.text('Done'));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('token-value')), findsNothing);
    expect(find.textContaining(tokenValue), findsNothing);
    expect(find.text('read'), findsOneWidget);
  });
}
