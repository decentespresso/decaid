import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/services/account/account_consent_gate.dart';
import 'package:reaprime/src/services/account/account_consent_store.dart';
import 'package:reaprime/src/services/account/decent_account_service.dart'
    show CredentialStore;

class _CredentialStore implements CredentialStore {
  final Map<String, String> values = {};

  @override
  Future<String?> read({required String key}) async => values[key];

  @override
  Future<void> write({required String key, required String value}) async {
    values[key] = value;
  }

  @override
  Future<void> delete({required String key}) async {
    values.remove(key);
  }
}

void main() {
  late _CredentialStore credentials;
  late AccountConsentStore store;
  late ActiveSkinConsent? activeSkin;
  late List<String> prompts;

  setUp(() {
    credentials = _CredentialStore();
    store = AccountConsentStore(credentialStore: credentials);
    activeSkin = const ActiveSkinConsent(
      id: 'aileen',
      name: 'Aileen',
      path: '/skins/aileen',
    );
    prompts = [];
  });

  AccountConsentGate gate({
    Future<AccountConsentDecision?> Function(String label)? prompt,
    Set<String> trustedConsentKeys = const {},
    bool trustAllConsent = false,
  }) => AccountConsentGate(
    store: store,
    activeSkin: () => activeSkin,
    prompt:
        prompt ??
        (label) async {
          prompts.add(label);
          return AccountConsentDecision.allowed;
        },
    trustedConsentKeys: trustedConsentKeys,
    trustAllConsent: trustAllConsent,
  );

  test('prompts once and remembers an installed skin allow', () async {
    final consent = gate();

    expect(await consent.requireConsent('skin'), isTrue);
    expect(await consent.requireConsent('skin'), isTrue);
    expect(prompts, ['Aileen']);
    expect(await store.read('skin:aileen'), AccountConsentDecision.allowed);
  });

  test('remembers an explicit deny', () async {
    final consent = gate(
      prompt: (label) async {
        prompts.add(label);
        return AccountConsentDecision.denied;
      },
    );

    expect(await consent.requireConsent('api:laptop'), isFalse);
    expect(await consent.requireConsent('api:laptop'), isFalse);
    expect(prompts, ['API client "laptop"']);
    expect(await store.read('api:laptop'), AccountConsentDecision.denied);
  });

  test('a different skin id cannot inherit consent', () async {
    final consent = gate();

    expect(await consent.requireConsent('skin'), isTrue);
    activeSkin = const ActiveSkinConsent(
      id: 'streamline',
      name: 'Streamline',
      path: '/skins/streamline',
    );
    expect(await consent.requireConsent('skin'), isTrue);

    expect(prompts, ['Aileen', 'Streamline']);
  });

  test('a custom skin path is hashed instead of persisted', () async {
    activeSkin = const ActiveSkinConsent(
      name: 'Custom skin',
      path: r'C:\Users\rea\private-skin',
    );

    expect(await gate().requireConsent('skin'), isTrue);

    final persisted = credentials.values['account_proxy_consent']!;
    expect(persisted, contains('skin:path:'));
    expect(persisted, isNot(contains('private-skin')));
  });

  test('concurrent requests for one caller share one prompt', () async {
    final decision = Completer<AccountConsentDecision?>();
    var promptCount = 0;
    final consent = gate(
      prompt: (_) {
        promptCount++;
        return decision.future;
      },
    );

    final first = consent.requireConsent('plugin:dye2');
    final second = consent.requireConsent('plugin:dye2');
    await Future<void>.delayed(Duration.zero);
    expect(promptCount, 1);

    decision.complete(AccountConsentDecision.allowed);
    expect(await Future.wait([first, second]), [isTrue, isTrue]);
  });

  test('timeout denial is not persisted', () async {
    final consent = gate(
      prompt: (label) async {
        prompts.add(label);
        return null;
      },
    );

    expect(await consent.requireConsent('plugin:dye2'), isFalse);
    expect(await consent.requireConsent('plugin:dye2'), isFalse);
    expect(prompts, ['Plugin "dye2"', 'Plugin "dye2"']);
    expect(await store.read('plugin:dye2'), isNull);
  });

  test('headless skin request denies without a wildcard decision', () async {
    activeSkin = null;

    expect(await gate().requireConsent('skin'), isFalse);
    expect(prompts, isEmpty);
  });

  test('trust-all permits a headless skin caller', () async {
    activeSkin = null;

    expect(await gate(trustAllConsent: true).requireConsent('skin'), isTrue);
    expect(prompts, isEmpty);
  });

  test('rejects unsupported and empty caller identities', () async {
    final consent = gate(trustAllConsent: true);

    expect(await consent.requireConsent('unknown'), isFalse);
    expect(await consent.requireConsent('plugin:'), isFalse);
    expect(await consent.requireConsent('api:'), isFalse);
    expect(prompts, isEmpty);
  });

  test('session trust takes precedence over a persisted deny', () async {
    await store.write('api:station', AccountConsentDecision.denied);

    expect(
      await gate(
        trustedConsentKeys: {'api:station'},
      ).requireConsent('api:station'),
      isTrue,
    );
    expect(prompts, isEmpty);
  });

  test('trust-all permits a caller without prompting or persistence', () async {
    expect(
      await gate(trustAllConsent: true).requireConsent('plugin:dye2'),
      isTrue,
    );
    expect(prompts, isEmpty);
    expect(await store.read('plugin:dye2'), isNull);
  });
}
