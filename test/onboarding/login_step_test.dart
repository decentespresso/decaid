import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:reaprime/src/onboarding_feature/steps/login_step.dart';
import 'package:reaprime/src/services/account/account_consent_store.dart';
import 'package:reaprime/src/services/account/decent_account_service.dart';
import 'package:reaprime/src/services/app_log_upload_service.dart';
import 'package:reaprime/src/settings/settings_controller.dart';
import 'package:shadcn_ui/shadcn_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../helpers/mock_settings_service.dart';

class _CredentialStore implements CredentialStore {
  final Map<String, String> values = {};

  @override
  Future<void> delete({required String key}) async => values.remove(key);

  @override
  Future<String?> read({required String key}) async => values[key];

  @override
  Future<void> write({required String key, required String value}) async {
    values[key] = value;
  }
}

DecentAccountService _accountService(
  MockClient client, {
  _CredentialStore? store,
}) {
  return DecentAccountService(
    httpClient: client,
    credentialStore: store ?? _CredentialStore(),
  );
}

void main() {
  test(
    'linked account bypasses onboarding without a network request',
    () async {
      final settingsService = MockSettingsService();
      await settingsService.setAccountStepSeen(false);
      final settingsController = SettingsController(settingsService);
      await settingsController.loadSettings();
      final store = _CredentialStore();
      await store.write(key: 'email', value: 'user@example.com');
      await store.write(key: 'password', value: 'cryptpw');
      var requests = 0;
      final accountService = _accountService(
        MockClient((_) async {
          requests++;
          return http.Response('cryptpw', 200);
        }),
        store: store,
      );

      final step = createLoginStep(
        accountService: accountService,
        settingsController: settingsController,
      );

      expect(await step.shouldShow(), isFalse);
      expect(requests, 0);
    },
  );

  testWidgets('offline state explains limitations and can continue', (
    tester,
  ) async {
    var completed = false;
    final accountService = _accountService(
      MockClient((_) async => throw http.ClientException('offline')),
    );

    await tester.pumpWidget(
      ShadApp(
        home: LoginStepWidget(
          accountService: accountService,
          onComplete: () => completed = true,
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Connect to the internet'), findsOneWidget);
    expect(
      find.text(
        'Account login, cloud sync, and skin downloads need an internet '
        'connection. Machine control and installed skins remain available '
        'offline.',
      ),
      findsOneWidget,
    );
    expect(find.text('Check again'), findsOneWidget);
    expect(find.text('Continue offline'), findsOneWidget);

    await tester.tap(find.text('Continue offline'));
    await tester.pump();

    expect(completed, isTrue);
  });

  testWidgets('reachable backend shows the login form', (tester) async {
    final accountService = _accountService(
      MockClient((_) async => http.Response('', 401)),
    );

    await tester.pumpWidget(
      ShadApp(
        home: LoginStepWidget(
          accountService: accountService,
          onComplete: () {},
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Link Your Decent Account'), findsOneWidget);
    expect(find.text('Email'), findsOneWidget);
    expect(find.text('Login'), findsOneWidget);
  });

  testWidgets('check again shows login after connectivity returns', (
    tester,
  ) async {
    var requests = 0;
    final accountService = _accountService(
      MockClient((_) async {
        requests++;
        if (requests == 1) throw http.ClientException('offline');
        return http.Response('', 401);
      }),
    );

    await tester.pumpWidget(
      ShadApp(
        home: LoginStepWidget(
          accountService: accountService,
          onComplete: () {},
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Check again'));
    await tester.pumpAndSettle();

    expect(requests, 2);
    expect(find.text('Link Your Decent Account'), findsOneWidget);
  });

  testWidgets('resuming the app preserves entered login details', (
    tester,
  ) async {
    var requests = 0;
    final accountService = _accountService(
      MockClient((_) async {
        requests++;
        return http.Response('', 401);
      }),
    );

    await tester.pumpWidget(
      ShadApp(
        home: LoginStepWidget(
          accountService: accountService,
          onComplete: () {},
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(ShadInput).first, 'user@example.com');

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();

    expect(requests, 1);
    expect(find.text('user@example.com'), findsOneWidget);
  });

  group('support log sharing opt-in', () {
    late _CredentialStore store;
    late DecentAccountService accountService;
    late AppLogUploadService uploadService;

    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      store = _CredentialStore();
      accountService = _accountService(
        MockClient((_) async => http.Response('cryptpw', 200)),
        store: store,
      );
      uploadService = AppLogUploadService(
        accountService: accountService,
        consentStore: AccountConsentStore(credentialStore: store),
        preferences: await SharedPreferences.getInstance(),
        logFilePath: 'unused-log.txt',
        machineIdentity: () => null,
        initialDelay: const Duration(days: 1),
      );
    });

    Future<void> signIn(WidgetTester tester, {required bool share}) async {
      var completed = false;
      await tester.pumpWidget(
        ShadApp(
          home: LoginStepWidget(
            accountService: accountService,
            appLogUploadService: uploadService,
            onComplete: () => completed = true,
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Share app logs with Decent Support'), findsOneWidget);
      if (share) {
        final toggle = find.byKey(const Key('onboarding-app-log-upload'));
        await tester.ensureVisible(toggle);
        await tester.tap(toggle);
        await tester.pump();
      }
      await tester.enterText(find.byType(ShadInput).at(0), 'user@example.com');
      await tester.enterText(find.byType(ShadInput).at(1), 'secret');
      await tester.ensureVisible(find.text('Login'));
      await tester.tap(find.text('Login'));
      for (var i = 0; i < 20 && !completed; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10)),
        );
        await tester.pump();
      }
      expect(completed, isTrue);
    }

    testWidgets('turning it on enables sharing after sign-in', (tester) async {
      await signIn(tester, share: true);

      expect(uploadService.enabled, isTrue);
      uploadService.dispose();
    });

    testWidgets('sharing stays off by default', (tester) async {
      await signIn(tester, share: false);

      expect(uploadService.enabled, isFalse);
      uploadService.dispose();
    });
  });
}
