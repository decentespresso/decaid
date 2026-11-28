import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:reaprime/src/services/account/decent_account_service.dart';
import 'package:reaprime/src/services/account/encrypted_credential_store.dart';
import 'package:reaprime/src/services/github_credentials.dart';
import 'package:reaprime/src/services/github_token_verifier.dart';
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

Widget _page(
  GithubCredentialProvider credentials, {
  GithubTokenVerifier verifier = const GithubTokenVerifier(),
}) {
  return MaterialApp(
    home: Scaffold(
      body: SingleChildScrollView(
        child: GithubTokenSection(credentials: credentials, verifier: verifier),
      ),
    ),
  );
}

void main() {
  testWidgets('guidance recommends least-privilege classic feedback scopes', (
    tester,
  ) async {
    await tester.pumpWidget(_page(GithubCredentialProvider(store: _Store())));
    await tester.pumpAndSettle();

    expect(
      find.textContaining('personal access token (classic)'),
      findsOneWidget,
    );
    expect(find.textContaining('public_repo'), findsOneWidget);
    expect(find.textContaining('gist'), findsWidgets);
    expect(find.textContaining('private-repository access'), findsOneWidget);
    expect(find.textContaining('fine-grained'), findsOneWidget);
    expect(find.text('Create classic token'), findsOneWidget);
  });

  testWidgets('test requires a pasted or saved user token and is explicit', (
    tester,
  ) async {
    var requests = 0;
    final verifier = GithubTokenVerifier(
      client: MockClient((_) async {
        requests++;
        return http.Response('{"login":"user"}', 200);
      }),
    );
    await tester.pumpWidget(
      _page(GithubCredentialProvider(store: _Store()), verifier: verifier),
    );
    await tester.pumpAndSettle();

    expect(requests, 0);
    expect(
      tester
          .widget<OutlinedButton>(
            find.widgetWithText(OutlinedButton, 'Test token'),
          )
          .onPressed,
      isNull,
    );
    await tester.enterText(find.byType(TextField), 'draft-token');
    await tester.pump();
    expect(requests, 0);
    await tester.tap(find.text('Test token'));
    await tester.pumpAndSettle();
    expect(requests, 1);
    expect(find.textContaining('Pasted token (not saved)'), findsOneWidget);
  });

  for (final input in ['', ' \t ']) {
    testWidgets('blank input "$input" tests a stable saved snapshot', (
      tester,
    ) async {
      final store = _Store()..value = 'saved-token';
      final credentials = GithubCredentialProvider(store: store);
      final verifier = GithubTokenVerifier(
        client: MockClient((request) async {
          expect(request.headers['authorization'], 'Bearer saved-token');
          return http.Response('{"login":"saved-user"}', 200);
        }),
      );
      await tester.pumpWidget(_page(credentials, verifier: verifier));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), input);
      await tester.tap(find.text('Test token'));
      await tester.pumpAndSettle();

      expect(find.textContaining('Saved token:'), findsOneWidget);
      expect(
        find.textContaining('Authenticated as saved-user'),
        findsOneWidget,
      );
      expect(store.value, 'saved-token');
      expect(store.writeKey, isNull);
    });
  }

  testWidgets('draft overrides saved token without changing active identity', (
    tester,
  ) async {
    final store = _Store()..value = 'saved-token';
    final credentials = GithubCredentialProvider(store: store);
    final verifier = GithubTokenVerifier(
      client: MockClient((request) async {
        expect(request.headers['authorization'], 'Bearer draft-token');
        return http.Response('{"login":"draft-user"}', 200);
      }),
    );
    await tester.pumpWidget(_page(credentials, verifier: verifier));
    await tester.pumpAndSettle();
    final saved = credentials.current;
    await tester.enterText(find.byType(TextField), '  draft-token  ');
    await tester.tap(find.text('Test token'));
    await tester.pumpAndSettle();

    expect(find.textContaining('Pasted token (not saved)'), findsOneWidget);
    expect(find.textContaining('have not been tested'), findsOneWidget);
    expect(credentials.current, same(saved));
    expect(store.value, 'saved-token');
    expect(store.writeKey, isNull);
    expect(store.deleteKey, isNull);

    await tester.enterText(find.byType(TextField), 'changed-token');
    await tester.pump();
    expect(find.textContaining('Authenticated as draft-user'), findsNothing);
  });

  testWidgets('testing disables conflicting controls and ignores stale input', (
    tester,
  ) async {
    final store = _Store()..value = 'saved-token';
    final gate = Completer<http.Response>();
    final verifier = GithubTokenVerifier(
      client: MockClient((_) => gate.future),
    );
    await tester.pumpWidget(
      _page(GithubCredentialProvider(store: store), verifier: verifier),
    );
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'draft-token');
    await tester.tap(find.text('Test token'));
    await tester.pump();

    final field = tester.widget<TextField>(find.byType(TextField));
    expect(field.enabled, isFalse);
    expect(find.text('Testing token...'), findsOneWidget);
    expect(
      tester.widget<FilledButton>(find.byType(FilledButton)).onPressed,
      isNull,
    );
    expect(
      tester
          .widget<OutlinedButton>(find.widgetWithText(OutlinedButton, 'Remove'))
          .onPressed,
      isNull,
    );
    field.controller!.text = 'different-token';
    gate.complete(http.Response('{"login":"old-user"}', 200));
    await tester.pumpAndSettle();

    expect(find.textContaining('Authenticated as old-user'), findsNothing);
    expect(tester.widget<TextField>(find.byType(TextField)).enabled, isTrue);
  });

  testWidgets('stored replacement invalidates an in-flight saved result', (
    tester,
  ) async {
    final credentials = GithubCredentialProvider(
      store: _Store()..value = 'old-token',
    );
    final gate = Completer<http.Response>();
    await tester.pumpWidget(
      _page(
        credentials,
        verifier: GithubTokenVerifier(client: MockClient((_) => gate.future)),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Test token'));
    await tester.pump();
    await credentials.save('replacement-token');
    gate.complete(http.Response('{"login":"old-user"}', 200));
    await tester.pumpAndSettle();

    expect(find.textContaining('Authenticated as old-user'), findsNothing);
  });

  testWidgets('save and remove invalidate previous verification results', (
    tester,
  ) async {
    final credentials = GithubCredentialProvider(store: _Store());
    await tester.pumpWidget(
      _page(
        credentials,
        verifier: GithubTokenVerifier(
          client: MockClient(
            (_) async => http.Response('{"login":"user"}', 200),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'draft-token');
    await tester.pump();
    await tester.tap(find.text('Test token'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Authenticated as user'), findsOneWidget);
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Authenticated as user'), findsNothing);
    await tester.tap(find.text('Test token'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Saved token:'), findsOneWidget);
    await tester.tap(find.text('Remove'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Authenticated as user'), findsNothing);
  });

  testWidgets('failed verification is safe and disposal ignores late results', (
    tester,
  ) async {
    final gate = Completer<http.Response>();
    var requests = 0;
    await tester.pumpWidget(
      _page(
        GithubCredentialProvider(store: _Store()..value = 'saved-secret'),
        verifier: GithubTokenVerifier(
          client: MockClient((_) async {
            requests++;
            if (requests == 1) return http.Response('saved-secret', 401);
            return gate.future;
          }),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Test token'));
    await tester.pumpAndSettle();
    expect(find.textContaining('invalid, revoked, or expired'), findsOneWidget);
    expect(find.textContaining('saved-secret'), findsNothing);
    await tester.tap(find.text('Test token'));
    await tester.pump();
    await tester.pumpWidget(const SizedBox());
    gate.complete(http.Response('{"login":"user"}', 200));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

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
