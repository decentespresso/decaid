import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/services/account/decent_account_service.dart';
import 'package:reaprime/src/services/account/encrypted_credential_store.dart';
import 'package:reaprime/src/services/github_credentials.dart';
import 'package:reaprime/src/settings/github_token_section.dart';

class _Store implements CredentialStore {
  String? value;
  String? readKey;
  String? writeKey;
  String? deleteKey;
  Object? readFailure;
  Object? writeFailure;
  Object? deleteFailure;
  Completer<void>? readGate;
  Completer<void>? writeGate;
  Completer<void>? deleteGate;

  @override
  Future<String?> read({required String key}) async {
    readKey = key;
    if (readGate != null) await readGate!.future;
    if (readFailure != null) throw readFailure!;
    return value;
  }

  @override
  Future<void> write({required String key, required String value}) async {
    writeKey = key;
    if (writeGate != null) await writeGate!.future;
    if (writeFailure != null) throw writeFailure!;
    this.value = value;
  }

  @override
  Future<void> delete({required String key}) async {
    deleteKey = key;
    if (deleteGate != null) await deleteGate!.future;
    if (deleteFailure != null) throw deleteFailure!;
    value = null;
  }
}

Widget _page(GithubCredentialProvider credentials) {
  return MaterialApp(
    home: Scaffold(body: GithubTokenSection(credentials: credentials)),
  );
}

void main() {
  testWidgets('does not prefill, obscures, and persists token actions', (
    tester,
  ) async {
    final store = _Store()..value = 'existing-secret';
    final credentials = GithubCredentialProvider(store: store);
    await tester.pumpWidget(_page(credentials));
    await tester.pumpAndSettle();

    expect(find.text('Status: Configured'), findsOneWidget);
    final field = tester.widget<TextField>(find.byType(TextField));
    expect(field.obscureText, isTrue);
    expect(field.enableSuggestions, isFalse);
    expect(field.autocorrect, isFalse);
    expect(field.enableIMEPersonalizedLearning, isFalse);
    expect(field.enabled, isTrue);
    expect(field.controller!.text, isEmpty);
    expect(find.text('existing-secret'), findsNothing);

    await tester.enterText(find.byType(TextField), '  replacement-secret  ');
    await tester.tap(find.text('Replace'));
    await tester.pumpAndSettle();
    expect(store.value, 'replacement-secret');
    expect(store.writeKey, GithubCredentialProvider.storageKey);
    expect(find.text('Status: Configured'), findsOneWidget);
    expect(
      tester.widget<TextField>(find.byType(TextField)).controller!.text,
      isEmpty,
    );
    expect(find.text('replacement-secret'), findsNothing);

    await tester.tap(find.text('Remove'));
    await tester.pumpAndSettle();
    expect(store.value, isNull);
    expect(store.deleteKey, GithubCredentialProvider.storageKey);
    expect(find.text('Status: Not configured'), findsOneWidget);
  });

  testWidgets('disables the secret field while saving and removing', (
    tester,
  ) async {
    final store = _Store()..value = 'keep-secret';
    store.readGate = Completer<void>();
    final credentials = GithubCredentialProvider(store: store);
    await tester.pumpWidget(_page(credentials));
    await tester.pump();
    expect(tester.widget<TextField>(find.byType(TextField)).enabled, isFalse);
    store.readGate!.complete();
    await tester.pumpAndSettle();

    store.writeGate = Completer<void>();
    await tester.enterText(find.byType(TextField), 'new-secret');
    await tester.tap(find.text('Replace'));
    await tester.pump();
    expect(tester.widget<TextField>(find.byType(TextField)).enabled, isFalse);
    store.writeGate!.complete();
    await tester.pumpAndSettle();

    store.deleteGate = Completer<void>();
    await tester.tap(find.text('Remove'));
    await tester.pump();
    expect(tester.widget<TextField>(find.byType(TextField)).enabled, isFalse);
    store.deleteGate!.complete();
    await tester.pumpAndSettle();
  });

  testWidgets('blank save is actionable and does not erase configured token', (
    tester,
  ) async {
    final store = _Store()..value = 'keep-secret';
    final credentials = GithubCredentialProvider(store: store);
    await tester.pumpWidget(_page(credentials));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), ' \t ');
    await tester.tap(find.text('Replace'));
    await tester.pumpAndSettle();

    expect(store.value, 'keep-secret');
    expect(
      find.text('Enter a GitHub personal access token before saving.'),
      findsOneWidget,
    );
    expect(find.text('Status: Configured'), findsOneWidget);
  });

  testWidgets('storage errors preserve state and expose no secret', (
    tester,
  ) async {
    final store = _Store()..value = 'keep-secret';
    final credentials = GithubCredentialProvider(store: store);
    await tester.pumpWidget(_page(credentials));
    await tester.pumpAndSettle();

    store.writeFailure = StateError('keep-secret');
    await tester.enterText(find.byType(TextField), 'new-secret');
    await tester.tap(find.text('Replace'));
    await tester.pumpAndSettle();
    expect(store.value, 'keep-secret');
    expect(find.text('Status: Configured'), findsOneWidget);
    expect(find.textContaining('keep-secret'), findsNothing);

    store.writeFailure = null;
    store.deleteFailure = StateError('keep-secret');
    await tester.tap(find.text('Remove'));
    await tester.pumpAndSettle();
    expect(store.value, 'keep-secret');
    expect(find.text('Status: Configured'), findsOneWidget);
    expect(find.text('keep-secret'), findsNothing);
  });

  testWidgets('unreadable state offers explicit recovery actions', (
    tester,
  ) async {
    final store = _Store()
      ..readFailure = const EncryptedCredentialStoreException();
    final credentials = GithubCredentialProvider(store: store);
    await tester.pumpWidget(_page(credentials));
    await tester.pumpAndSettle();

    expect(find.text('Status: Stored token cannot be read'), findsOneWidget);
    expect(find.text('Replace'), findsOneWidget);
    expect(find.text('Remove'), findsOneWidget);
    expect(find.text('Retry'), findsNothing);

    store.readFailure = null;
    await tester.enterText(find.byType(TextField), 'replacement-secret');
    await tester.tap(find.text('Replace'));
    await tester.pumpAndSettle();
    expect(find.text('Status: Configured'), findsOneWidget);
  });

  testWidgets('read errors offer retry without revealing storage details', (
    tester,
  ) async {
    final store = _Store()..readFailure = StateError('secret-in-error');
    final credentials = GithubCredentialProvider(store: store);
    await tester.pumpWidget(_page(credentials));
    await tester.pumpAndSettle();

    expect(find.text('Status: Unknown (storage unavailable)'), findsOneWidget);
    expect(find.text('secret-in-error'), findsNothing);
    expect(find.text('Retry'), findsOneWidget);

    store.readFailure = null;
    store.value = 'stored-secret';
    await tester.tap(find.text('Retry'));
    await tester.pumpAndSettle();
    expect(find.text('Status: Configured'), findsOneWidget);
    expect(find.text('stored-secret'), findsNothing);
  });
}
