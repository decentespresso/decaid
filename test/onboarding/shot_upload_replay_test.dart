import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:reaprime/src/onboarding_feature/onboarding_controller.dart';
import 'package:reaprime/src/onboarding_feature/steps/shot_upload_step.dart';
import 'package:reaprime/src/services/account/decent_account_service.dart';
import 'package:reaprime/src/settings/settings_controller.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

import '../helpers/mock_settings_service.dart';

const _legacyAutoUploadKey = 'plugin.settings.shot-upload.reaplugin';

class _FailingReadStore extends SharedPreferencesStorePlatform {
  _FailingReadStore({required this.data});

  final Map<String, Object> data;
  bool failReads = true;

  @override
  Future<bool> clear() async => true;

  @override
  Future<Map<String, Object>> getAll() async {
    if (failReads) throw StateError('preferences unavailable');
    return Map<String, Object>.of(data);
  }

  @override
  Future<bool> remove(String key) async => true;

  @override
  Future<bool> setValue(String valueType, String key, Object value) async =>
      true;
}

class _CredentialStore implements CredentialStore {
  _CredentialStore() {
    values['email'] = 'user@example.com';
    values['password'] = 'cryptpw';
  }

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

class _RecordingSettingsService extends MockSettingsService {
  final List<String> events = [];

  @override
  Future<void> setShotUploadDecision(bool value) async {
    events.add('decision:$value');
    await super.setShotUploadDecision(value);
  }

  @override
  Future<void> setShotUploadStepSeen(bool value) async {
    events.add('seen:$value');
    await super.setShotUploadStepSeen(value);
  }
}

class _Harness {
  _Harness({
    required this.events,
    required this.settings,
    required this.controller,
  });

  final List<String> events;
  final SettingsController settings;
  final OnboardingController controller;

  String get currentStepId => controller.currentStep.id;
}

Future<_Harness> _build({required bool seen}) async {
  final service = _RecordingSettingsService();
  await service.setShotUploadStepSeen(seen);
  final events = service.events;
  events.clear();
  final settings = SettingsController(service);
  await settings.loadSettings();
  final step = createShotUploadStep(
    accountService: DecentAccountService(
      httpClient: MockClient((_) async => http.Response('', 200)),
      credentialStore: _CredentialStore(),
    ),
    settingsController: settings,
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
  return _Harness(events: events, settings: settings, controller: controller);
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

Future<void> _pumpStep(WidgetTester tester, _Harness harness) async {
  await tester.pumpWidget(
    ShadApp(home: _StepHost(controller: harness.controller)),
  );
  await tester.pumpAndSettle();
}

Future<void> _continue(WidgetTester tester) async {
  final button = find.byType(ShadButton);
  await tester.ensureVisible(button);
  await tester.pumpAndSettle();
  await tester.tap(button);
  await tester.pumpAndSettle();
}

void _storeAutoUpload(String raw) {
  SharedPreferences.setMockInitialValues({_legacyAutoUploadKey: raw});
}

void main() {
  setUp(() {
    SharedPreferences.resetStatic();
    SharedPreferences.setMockInitialValues({});
  });

  tearDown(() {
    SharedPreferences.resetStatic();
    SharedPreferences.setMockInitialValues({});
  });

  testWidgets(
    'a replayed opt-in shows the real state, continue writes no answer',
    (tester) async {
      _storeAutoUpload('{"AutoUpload":true}');
      final harness = await _build(seen: false);
      await harness.settings.setShotUploadDecision(true);
      await harness.settings.clearShotUploadPendingDecision();
      await harness.settings.setShotUploadStepSeen(false);
      harness.events.clear();

      final optInBefore = harness.settings.shotUploadOptIn;

      await _pumpStep(tester, harness);

      expect(find.text(shotUploadCopy), findsOneWidget);
      expect(find.text('Continue'), findsOneWidget);

      await _continue(tester);

      expect(harness.events, ['seen:true']);
      expect(harness.currentStepId, 'sentinel');
      expect(harness.settings.shotUploadPendingDecision, isNull);
      expect(harness.settings.shotUploadRecordedAnswer, isTrue);
      expect(harness.settings.shotUploadOptIn, optInBefore);
    },
  );

  testWidgets('a legacy opt-out without a decision is presented and kept', (
    tester,
  ) async {
    _storeAutoUpload('{"AutoUpload":false}');
    final harness = await _build(seen: false);

    await _pumpStep(tester, harness);

    expect(find.text('Not now'), findsOneWidget);

    await _continue(tester);

    expect(harness.events, ['seen:true']);
    expect(harness.currentStepId, 'sentinel');
    expect(
      harness.settings.shotUploadPendingDecision,
      isNull,
      reason: 'an untouched explicit opt-out is not re-decided',
    );
    expect(harness.settings.shotUploadRecordedAnswer, isNull);
  });

  testWidgets(
    'a consumed opt-in does not override a plugin opt-out decided later',
    (tester) async {
      _storeAutoUpload('{"AutoUpload":false}');
      final harness = await _build(seen: false);
      await harness.settings.setShotUploadDecision(true);
      await harness.settings.clearShotUploadPendingDecision();
      await harness.settings.setShotUploadStepSeen(false);
      harness.events.clear();

      await _pumpStep(tester, harness);

      expect(find.text('Not now'), findsOneWidget);
      expect(find.text('Continue'), findsNothing);

      await _continue(tester);

      expect(harness.events, ['seen:true']);
      expect(harness.currentStepId, 'sentinel');
      expect(harness.settings.shotUploadPendingDecision, isNull);
      expect(
        harness.settings.shotUploadRecordedAnswer,
        isTrue,
        reason: 'the consumed answer is not rewritten',
      );
    },
  );

  testWidgets(
    'a consumed opt-out does not override a plugin opt-in decided later',
    (tester) async {
      _storeAutoUpload('{"AutoUpload":true}');
      final harness = await _build(seen: false);
      await harness.settings.setShotUploadDecision(false);
      await harness.settings.clearShotUploadPendingDecision();
      await harness.settings.setShotUploadStepSeen(false);
      harness.events.clear();

      await _pumpStep(tester, harness);

      expect(find.text('Continue'), findsOneWidget);
      expect(find.text('Not now'), findsNothing);

      await _continue(tester);

      expect(harness.events, ['seen:true']);
      expect(harness.currentStepId, 'sentinel');
      expect(harness.settings.shotUploadPendingDecision, isNull);
      expect(
        harness.settings.shotUploadRecordedAnswer,
        isFalse,
        reason: 'the consumed answer is not rewritten',
      );
    },
  );

  testWidgets(
    'a consumed answer with no stored plugin setting keeps the known answer',
    (tester) async {
      final harness = await _build(seen: false);
      await harness.settings.setShotUploadDecision(true);
      await harness.settings.clearShotUploadPendingDecision();
      await harness.settings.setShotUploadStepSeen(false);
      harness.events.clear();

      await _pumpStep(tester, harness);

      expect(find.text('Continue'), findsOneWidget);

      await _continue(tester);

      expect(harness.events, ['seen:true']);
      expect(harness.currentStepId, 'sentinel');
      expect(
        harness.settings.shotUploadPendingDecision,
        isNull,
        reason: 'an unchanged replay does not manufacture a pending answer',
      );
      expect(harness.settings.shotUploadRecordedAnswer, isTrue);
    },
  );

  testWidgets('a stored-state read failure is retryable and records nothing', (
    tester,
  ) async {
    final store = _FailingReadStore(
      data: {'flutter.$_legacyAutoUploadKey': '{"AutoUpload":true}'},
    );
    SharedPreferencesStorePlatform.instance = store;
    addTearDown(() {
      SharedPreferences.setMockInitialValues({});
    });
    final harness = await _build(seen: false);

    await _pumpStep(tester, harness);

    expect(
      find.text('Could not load your shot upload setting. Try again.'),
      findsOneWidget,
    );
    expect(find.text('Retry'), findsOneWidget);
    expect(find.text(shotUploadCopy), findsNothing);
    expect(harness.currentStepId, 'shot-upload');
    expect(harness.events, isEmpty);
    expect(harness.settings.shotUploadPendingDecision, isNull);
    expect(harness.settings.shotUploadRecordedAnswer, isNull);

    store.failReads = false;
    await tester.tap(find.byType(ShadButton));
    await tester.pumpAndSettle();

    expect(find.text('Continue'), findsOneWidget);

    await _continue(tester);

    expect(harness.events, ['seen:true']);
    expect(harness.currentStepId, 'sentinel');
    expect(harness.settings.shotUploadPendingDecision, isNull);
  });

  testWidgets(
    'a malformed stored setting fails retryably instead of presenting off',
    (tester) async {
      _storeAutoUpload('{not json');
      final harness = await _build(seen: false);

      await _pumpStep(tester, harness);

      expect(
        find.text('Could not load your shot upload setting. Try again.'),
        findsOneWidget,
      );
      expect(find.text('Retry'), findsOneWidget);
      expect(harness.events, isEmpty);
      expect(harness.settings.shotUploadPendingDecision, isNull);
      expect(harness.settings.shotUploadRecordedAnswer, isNull);

      _storeAutoUpload('{"AutoUpload":true}');
      await tester.tap(find.byType(ShadButton));
      await tester.pumpAndSettle();

      expect(find.text('Continue'), findsOneWidget);

      await _continue(tester);

      expect(harness.events, ['seen:true']);
      expect(harness.currentStepId, 'sentinel');
      expect(harness.settings.shotUploadPendingDecision, isNull);
    },
  );

  testWidgets(
    'an invalid stored AutoUpload type fails retryably instead of presenting off',
    (tester) async {
      _storeAutoUpload('{"AutoUpload":"true"}');
      final harness = await _build(seen: false);

      await _pumpStep(tester, harness);

      expect(
        find.text('Could not load your shot upload setting. Try again.'),
        findsOneWidget,
      );
      expect(harness.events, isEmpty);
      expect(harness.settings.shotUploadPendingDecision, isNull);

      _storeAutoUpload('{"AutoUpload":false}');
      await tester.tap(find.byType(ShadButton));
      await tester.pumpAndSettle();

      expect(find.text('Not now'), findsOneWidget);

      await _continue(tester);

      expect(harness.events, ['seen:true']);
      expect(harness.settings.shotUploadPendingDecision, isNull);
    },
  );

  testWidgets(
    'an explicitly null stored AutoUpload fails retryably instead of reading as absent',
    (tester) async {
      _storeAutoUpload('{"AutoUpload":null}');
      final harness = await _build(seen: false);

      await _pumpStep(tester, harness);

      expect(
        find.text('Could not load your shot upload setting. Try again.'),
        findsOneWidget,
      );
      expect(harness.events, isEmpty);
      expect(harness.settings.shotUploadPendingDecision, isNull);
      expect(harness.settings.shotUploadRecordedAnswer, isNull);

      _storeAutoUpload('{"AutoUpload":true}');
      await tester.tap(find.byType(ShadButton));
      await tester.pumpAndSettle();

      expect(find.text('Continue'), findsOneWidget);

      await _continue(tester);

      expect(harness.events, ['seen:true']);
      expect(harness.settings.shotUploadPendingDecision, isNull);
    },
  );

  testWidgets('a genuine pending decision survives an unchanged continue', (
    tester,
  ) async {
    final harness = await _build(seen: false);
    await harness.settings.setShotUploadDecision(true);
    await harness.settings.setShotUploadStepSeen(false);
    harness.events.clear();

    await _pumpStep(tester, harness);
    await _continue(tester);

    expect(harness.events, ['seen:true']);
    expect(harness.currentStepId, 'sentinel');
    expect(
      harness.settings.shotUploadPendingDecision,
      isTrue,
      reason: 'the loader still has to apply this answer',
    );
  });

  testWidgets(
    'a genuine pending decision outranks a conflicting stored plugin opt-out',
    (tester) async {
      _storeAutoUpload('{"AutoUpload":false}');
      final harness = await _build(seen: false);
      await harness.settings.setShotUploadDecision(true);
      await harness.settings.setShotUploadStepSeen(false);
      harness.events.clear();

      await _pumpStep(tester, harness);

      expect(find.text('Continue'), findsOneWidget);
      expect(find.text('Not now'), findsNothing);

      await _continue(tester);

      expect(harness.events, ['seen:true']);
      expect(harness.settings.shotUploadPendingDecision, isTrue);
    },
  );

  testWidgets(
    'a genuine pending decision is shown without reading unreadable stored settings',
    (tester) async {
      _storeAutoUpload('{not json');
      final harness = await _build(seen: false);
      await harness.settings.setShotUploadDecision(true);
      await harness.settings.setShotUploadStepSeen(false);
      harness.events.clear();

      await _pumpStep(tester, harness);

      expect(find.text('Continue'), findsOneWidget);
      expect(
        find.text('Could not load your shot upload setting. Try again.'),
        findsNothing,
      );

      await _continue(tester);

      expect(harness.events, ['seen:true']);
      expect(harness.settings.shotUploadPendingDecision, isTrue);
    },
  );

  testWidgets('changing the toggle during a replay records that change', (
    tester,
  ) async {
    _storeAutoUpload('{"AutoUpload":true}');
    final harness = await _build(seen: false);
    await harness.settings.setShotUploadDecision(true);
    await harness.settings.clearShotUploadPendingDecision();
    await harness.settings.setShotUploadStepSeen(false);
    harness.events.clear();

    await _pumpStep(tester, harness);
    expect(find.text('Continue'), findsOneWidget);

    await tester.tap(find.byType(ShadSwitch));
    await tester.pumpAndSettle();
    expect(find.text('Not now'), findsOneWidget);

    await _continue(tester);

    expect(harness.events, ['decision:false']);
    expect(harness.currentStepId, 'sentinel');
    expect(harness.settings.shotUploadPendingDecision, isFalse);
    expect(harness.settings.shotUploadRecordedAnswer, isFalse);
  });

  testWidgets('a legacy AutoUpload install shows its real state and is kept', (
    tester,
  ) async {
    _storeAutoUpload('{"AutoUpload":true}');
    final harness = await _build(seen: false);

    await _pumpStep(tester, harness);

    expect(find.text('Continue'), findsOneWidget);

    await _continue(tester);

    expect(harness.events, ['seen:true']);
    expect(
      harness.settings.shotUploadPendingDecision,
      isNull,
      reason: 'an untouched legacy setting is not re-decided',
    );
  });

  testWidgets('a first run without any prior state still records the answer', (
    tester,
  ) async {
    final harness = await _build(seen: false);

    await _pumpStep(tester, harness);

    expect(find.text('Not now'), findsOneWidget);

    await _continue(tester);

    expect(harness.events, ['decision:false']);
    expect(harness.settings.shotUploadPendingDecision, isFalse);
  });
}
