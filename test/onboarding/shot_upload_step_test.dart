import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:logging/logging.dart';
import 'package:reaprime/src/onboarding_feature/onboarding_controller.dart';
import 'package:reaprime/src/onboarding_feature/steps/shot_upload_step.dart';
import 'package:reaprime/src/plugins/plugin_loader_service.dart';
import 'package:reaprime/src/services/account/account_consent_store.dart';
import 'package:reaprime/src/services/account/decent_account_service.dart';
import 'package:reaprime/src/settings/settings_controller.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

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

class _RecordingConsentStore extends AccountConsentStore {
  _RecordingConsentStore({
    required super.credentialStore,
    required this.events,
  });

  final List<String> events;
  final List<String> writes = [];
  bool failWrites = false;

  @override
  Future<void> write(String key, AccountConsentDecision decision) async {
    writes.add('$key:${decision.name}');
    events.add('consent:$key:${decision.name}');
    if (failWrites) throw Exception('consent store unavailable');
    await super.write(key, decision);
  }
}

class _OrderedSettingsService extends MockSettingsService {
  _OrderedSettingsService({required this.events});

  final List<String> events;

  @override
  Future<void> setShotUploadOptIn(bool value) async {
    events.add('optIn:$value');
    await super.setShotUploadOptIn(value);
  }

  @override
  Future<void> setShotUploadStepSeen(bool value) async {
    events.add('seen:$value');
    await super.setShotUploadStepSeen(value);
  }
}

class _SpyPluginLoader extends Fake implements PluginLoaderService {
  Map<String, dynamic> stored = {};
  bool failSave = false;
  int reads = 0;
  final List<Map<String, dynamic>> saves = [];
  final List<String> suppressed = [];

  @override
  Future<Map<String, dynamic>> pluginSettings(String pluginId) async {
    reads++;
    return Map<String, dynamic>.of(stored);
  }

  @override
  Future<void> savePluginSettings(
    String pluginId,
    Map<String, dynamic> settings,
  ) async {
    if (failSave) throw Exception('Plugin not found: $pluginId');
    saves.add(Map<String, dynamic>.of(settings));
    stored = {...stored, ...settings};
  }

  @override
  void suppressLoad(String pluginId) => suppressed.add(pluginId);
}

class _Harness {
  _Harness({
    required this.events,
    required this.consent,
    required this.settings,
    required this.controller,
    required this.step,
  });

  final List<String> events;
  final _RecordingConsentStore consent;
  final SettingsController settings;
  final OnboardingController controller;
  final OnboardingStep step;

  String get currentStepId => controller.currentStep.id;
}

Future<_Harness> _build({
  bool linked = true,
  bool consentFails = false,
  bool seen = false,
}) async {
  final events = <String>[];
  final credentials = _CredentialStore();
  if (linked) {
    await credentials.write(key: 'email', value: 'user@example.com');
    await credentials.write(key: 'password', value: 'cryptpw');
  }
  final consent = _RecordingConsentStore(
    credentialStore: credentials,
    events: events,
  )..failWrites = consentFails;
  final settingsService = _OrderedSettingsService(events: events);
  await settingsService.setShotUploadStepSeen(seen);
  events.clear();
  final settings = SettingsController(settingsService);
  await settings.loadSettings();
  final accountService = DecentAccountService(
    httpClient: MockClient((_) async => http.Response('', 200)),
    credentialStore: credentials,
  );
  final step = createShotUploadStep(
    accountService: accountService,
    settingsController: settings,
    consentStore: consent,
  );
  final controller = OnboardingController(
    steps: [
      step,
      OnboardingStep(
        id: 'sentinel',
        shouldShow: () async => true,
        builder: (_) => const SizedBox.shrink(),
      ),
    ],
  );
  await controller.initialize();
  return _Harness(
    events: events,
    consent: consent,
    settings: settings,
    controller: controller,
    step: step,
  );
}

class _StepHost extends StatelessWidget {
  const _StepHost({required this.controller});

  final OnboardingController controller;

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<OnboardingStep>(
      stream: controller.currentStepStream,
      builder: (context, snapshot) {
        final step = snapshot.data ?? controller.currentStep;
        return step.builder(controller);
      },
    );
  }
}

Future<void> _tapToggle(WidgetTester tester) async {
  final toggle = find.byType(ShadSwitch);
  await tester.ensureVisible(toggle);
  await tester.pumpAndSettle();
  await tester.tap(toggle);
}

Future<void> _tapContinue(WidgetTester tester) async {
  final button = find.text('Continue');
  await tester.ensureVisible(button);
  await tester.pumpAndSettle();
  await tester.tap(button);
}

Future<void> _pumpStep(WidgetTester tester, _Harness harness) async {
  await tester.pumpWidget(
    ShadApp(home: _StepHost(controller: harness.controller)),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('renders the agreed copy verbatim', (tester) async {
    final harness = await _build();
    await _pumpStep(tester, harness);

    expect(find.text(shotUploadCopy), findsOneWidget);
    expect(harness.currentStepId, 'shot-upload');
  });

  testWidgets('continue with the toggle untouched persists off', (
    tester,
  ) async {
    final harness = await _build();
    await _pumpStep(tester, harness);

    await _tapContinue(tester);
    await tester.pumpAndSettle();

    expect(harness.events, ['seen:true']);
    expect(harness.consent.writes, isEmpty);
    expect(harness.settings.shotUploadOptIn, isFalse);
    expect(harness.settings.shotUploadStepSeen, isTrue);
    expect(harness.currentStepId, 'sentinel');
  });

  testWidgets('toggling on writes consent before the opt-in and seen flags', (
    tester,
  ) async {
    final harness = await _build();
    await _pumpStep(tester, harness);

    await _tapToggle(tester);
    await tester.pump();
    await _tapContinue(tester);
    await tester.pumpAndSettle();

    expect(harness.events, [
      'consent:$shotUploadConsentKey:allowed',
      'optIn:true',
      'seen:true',
    ]);
    expect(harness.settings.shotUploadOptIn, isTrue);
    expect(harness.settings.shotUploadStepSeen, isTrue);
    expect(harness.currentStepId, 'sentinel');
  });

  testWidgets('toggling on then off leaves no consent record', (tester) async {
    final harness = await _build();
    await _pumpStep(tester, harness);

    await _tapToggle(tester);
    await tester.pump();
    await _tapToggle(tester);
    await tester.pump();
    await _tapContinue(tester);
    await tester.pumpAndSettle();

    expect(harness.consent.writes, isEmpty);
    expect(harness.settings.shotUploadOptIn, isFalse);
    expect(harness.events, ['seen:true']);
  });

  testWidgets('a consent failure keeps the user on the screen and retries', (
    tester,
  ) async {
    final harness = await _build(consentFails: true);
    await _pumpStep(tester, harness);

    await _tapToggle(tester);
    await tester.pump();
    await _tapContinue(tester);
    await tester.pumpAndSettle();

    expect(harness.currentStepId, 'shot-upload');
    expect(find.text('Could not save your choice. Try again.'), findsOneWidget);
    expect(harness.settings.shotUploadOptIn, isFalse);
    expect(harness.settings.shotUploadStepSeen, isFalse);
    expect(harness.events, ['consent:$shotUploadConsentKey:allowed']);
    expect(await harness.consent.read(shotUploadConsentKey), isNull);

    harness.consent.failWrites = false;
    await _tapContinue(tester);
    await tester.pumpAndSettle();

    expect(harness.currentStepId, 'sentinel');
    expect(harness.settings.shotUploadOptIn, isTrue);
    expect(harness.settings.shotUploadStepSeen, isTrue);
  });

  test('shouldShow is false once the step was seen', () async {
    final harness = await _build(seen: true);

    expect(await harness.step.shouldShow(), isFalse);
  });

  testWidgets('no linked account renders nothing and advances', (tester) async {
    final harness = await _build(linked: false);
    await _pumpStep(tester, harness);

    expect(find.text(shotUploadCopy), findsNothing);
    expect(harness.currentStepId, 'sentinel');
    expect(harness.events, isEmpty);
    expect(harness.consent.writes, isEmpty);
    expect(harness.settings.shotUploadStepSeen, isFalse);
  });

  testWidgets('a linked account renders the screen instead of advancing', (
    tester,
  ) async {
    final harness = await _build();
    await _pumpStep(tester, harness);

    expect(find.text(shotUploadCopy), findsOneWidget);
    expect(harness.currentStepId, 'shot-upload');
  });

  group('applyShotUploadIntent', () {
    Future<(SettingsController, _SpyPluginLoader)> intentHarness({
      required bool seen,
      required bool optedIn,
      Map<String, dynamic> stored = const {},
      bool failSave = false,
    }) async {
      final events = <String>[];
      final service = _OrderedSettingsService(events: events);
      final settings = SettingsController(service);
      await settings.loadSettings();
      await settings.setShotUploadStepSeen(seen);
      await settings.setShotUploadOptIn(optedIn);
      final loader = _SpyPluginLoader()
        ..stored = Map<String, dynamic>.of(stored)
        ..failSave = failSave;
      return (settings, loader);
    }

    test('writes the opt-in when the stored value disagrees', () async {
      final (settings, loader) = await intentHarness(
        seen: true,
        optedIn: true,
        stored: {'AutoUpload': false},
      );

      await applyShotUploadIntent(settings, loader);

      expect(loader.reads, 1);
      expect(loader.saves, [
        {'AutoUpload': true},
      ]);
    });

    test('does not write when the stored value already matches', () async {
      final (settings, loader) = await intentHarness(
        seen: true,
        optedIn: true,
        stored: {'AutoUpload': true},
      );

      await applyShotUploadIntent(settings, loader);

      expect(loader.saves, isEmpty);
    });

    test('the answer is one-shot: it is cleared once applied', () async {
      final (settings, loader) = await intentHarness(
        seen: true,
        optedIn: true,
        stored: {'AutoUpload': false},
      );

      await applyShotUploadIntent(settings, loader);

      expect(loader.saves, [
        {'AutoUpload': true},
      ]);
      expect(settings.shotUploadOptIn, isFalse);

      loader.saves.clear();
      loader.stored = {'AutoUpload': false};
      await applyShotUploadIntent(settings, loader);

      expect(
        loader.saves,
        isEmpty,
        reason: 'a later launch must not overwrite the plugin setting',
      );
    });

    test(
      'a handed-off answer survives a launch that never applied it',
      () async {
        final (settings, loader) = await intentHarness(
          seen: true,
          optedIn: true,
          failSave: true,
        );

        await applyShotUploadIntent(settings, loader);

        expect(
          settings.shotUploadOptIn,
          isTrue,
          reason: 'the retry needs the answer until it lands',
        );
      },
    );

    test('enforces an opt-out over a stored true value', () async {
      final (settings, loader) = await intentHarness(
        seen: true,
        optedIn: false,
        stored: {'AutoUpload': true},
      );

      await applyShotUploadIntent(settings, loader);

      expect(loader.saves, [
        {'AutoUpload': false},
      ]);
    });

    test('does nothing before the user has answered', () async {
      final (settings, loader) = await intentHarness(
        seen: false,
        optedIn: false,
        stored: {'AutoUpload': true},
      );

      await applyShotUploadIntent(settings, loader);

      expect(loader.reads, 0);
      expect(loader.saves, isEmpty);
      expect(loader.stored['AutoUpload'], isTrue);
    });

    test('suppresses the plugin when the write fails', () async {
      final (settings, loader) = await intentHarness(
        seen: true,
        optedIn: true,
        failSave: true,
      );
      final warnings = <String>[];
      final sub = Logger('ShotUploadStep').onRecord.listen((record) {
        if (record.level >= Level.WARNING) warnings.add(record.message);
      });
      addTearDown(sub.cancel);

      await applyShotUploadIntent(settings, loader);

      expect(loader.suppressed, [shotUploadPluginId]);
      expect(warnings, ['shot upload intent not applied; plugin not loaded']);
    });
  });
}
