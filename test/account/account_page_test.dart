import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart' as http_testing;
import 'package:reaprime/src/account/account_page.dart';
import 'package:reaprime/src/services/account/decent_account_service.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

class FakeCredentialStore implements CredentialStore {
  final Map<String, String> _values = {};

  @override
  Future<String?> read({required String key}) async => _values[key];

  @override
  Future<void> write({required String key, required String value}) async {
    _values[key] = value;
  }

  @override
  Future<void> delete({required String key}) async {
    _values.remove(key);
  }
}

Widget buildTestApp(Widget child) => ShadApp(home: child);

DecentAccountService buildService(
  FakeCredentialStore store,
  http_testing.MockClientHandler handler,
) {
  return DecentAccountService(
    httpClient: http_testing.MockClient(handler),
    credentialStore: store,
  );
}

class _RebuildingHost extends StatefulWidget {
  const _RebuildingHost(this.childBuilder);

  final WidgetBuilder childBuilder;

  @override
  State<_RebuildingHost> createState() => _RebuildingHostState();
}

class _RebuildingHostState extends State<_RebuildingHost> {
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(const Duration(seconds: 1), (_) => setState(() {}));
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.childBuilder(context);
}

void main() {
  testWidgets('shows Link Your Account for stored invalid credentials', (
    tester,
  ) async {
    final store = FakeCredentialStore();
    await store.write(key: 'email', value: 'user@example.com');
    await store.write(key: 'password', value: 'stale_cryptpw');
    final service = buildService(store, (_) async => http.Response('', 401));

    await tester.pumpWidget(buildTestApp(AccountPage(accountService: service)));
    await tester.pumpAndSettle();

    expect(find.text('Logged In'), findsNothing);
    expect(find.text('Link Your Account'), findsOneWidget);
  });

  testWidgets('shows Logged In for stored valid credentials', (tester) async {
    final store = FakeCredentialStore();
    await store.write(key: 'email', value: 'user@example.com');
    await store.write(key: 'password', value: 'cryptpw_abc123');
    final service = buildService(
      store,
      (_) async => http.Response('cryptpw_abc123', 200),
    );

    await tester.pumpWidget(buildTestApp(AccountPage(accountService: service)));
    await tester.pumpAndSettle();

    expect(find.text('Logged In'), findsOneWidget);
    expect(find.text('Link Your Account'), findsNothing);
  });

  testWidgets('parent rebuilds during an outage do not hammer the backend', (
    tester,
  ) async {
    final store = FakeCredentialStore();
    await store.write(key: 'email', value: 'user@example.com');
    await store.write(key: 'password', value: 'cryptpw_abc123');
    var requests = 0;
    final service = buildService(store, (_) async {
      requests++;
      return http.Response('', 500);
    });

    await tester.pumpWidget(
      buildTestApp(
        _RebuildingHost((_) => AccountPage(accountService: service)),
      ),
    );
    await tester.pumpAndSettle();
    expect(requests, 1);

    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(seconds: 1));
    }
    expect(requests, 1);

    await tester.pump(const Duration(seconds: 25));
    expect(requests, 2);
    expect(find.text('Link Your Account'), findsOneWidget);
  });

  testWidgets('no longer shows Logged In after an upstream auth failure', (
    tester,
  ) async {
    final store = FakeCredentialStore();
    await store.write(key: 'email', value: 'user@example.com');
    await store.write(key: 'password', value: 'cryptpw_abc123');
    final service = buildService(
      store,
      (_) async => http.Response('cryptpw_abc123', 200),
    );

    await tester.pumpWidget(buildTestApp(AccountPage(accountService: service)));
    await tester.pumpAndSettle();
    expect(find.text('Logged In'), findsOneWidget);

    service.reportAuthenticationFailure();

    await tester.pumpWidget(buildTestApp(AccountPage(accountService: service)));
    await tester.pumpAndSettle();

    expect(find.text('Logged In'), findsNothing);
    expect(find.text('Link Your Account'), findsOneWidget);
  });
}
