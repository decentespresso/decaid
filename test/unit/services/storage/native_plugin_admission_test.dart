import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/services/storage/native_plugin_admission.dart';

const _activityPath =
    'android/app/src/main/kotlin/net/tadel/reaprime/MainActivity.kt';
const _manifestPath = 'android/app/src/main/AndroidManifest.xml';
const _foregroundServicePath = 'lib/src/services/foreground_service.dart';
const _mainPath = 'lib/main.dart';
const _iosAppDelegatePath = 'ios/Runner/AppDelegate.swift';
const _macAppDelegatePath = 'macos/Runner/AppDelegate.swift';
const _macMainWindowPath = 'macos/Runner/MainFlutterWindow.swift';
const _iosRegistrantPath = 'ios/Runner/GeneratedPluginRegistrant.m';
const _macRegistrantPath = 'macos/Flutter/GeneratedPluginRegistrant.swift';

const _sensitiveInitialisations = <String>[
  'MulticastLockService().acquire()',
  'Firebase.initializeApp(',
  'telemetryService.initialize()',
  'Hive.init(',
  'AppDatabase.defaults()',
  'PluginLoaderService(',
  'WebUIService(',
  'ForegroundTaskService.init()',
];

void main() {
  group('plugin admission call', () {
    late _RecordingAdmissionChannel channel;

    setUp(() => channel = _RecordingAdmissionChannel());

    NativePluginAdmission gatedAdmission() =>
        NativePluginAdmission(channel: channel, defersRegistration: () => true);

    test('only platforms that defer registration open the channel', () async {
      final admission = NativePluginAdmission(
        channel: channel,
        defersRegistration: () => false,
      );

      await admission.admit();

      expect(channel.calls, 0);
    });

    test('every deferring platform forwards one call per request', () async {
      final admission = gatedAdmission();

      await admission.admit();
      expect(channel.calls, 1);

      await admission.admit();
      expect(
        channel.calls,
        2,
        reason:
            'the engine guard owns idempotency; the Dart side must not cache a '
            'result that was never delivered',
      );
    });

    test('a native registration failure is never swallowed', () async {
      channel.refusal = PlatformException(
        code: 'PLUGIN_REGISTRATION_FAILED',
        message: 'GeneratedPluginRegistrant is missing',
      );

      await expectLater(
        gatedAdmission().admit(),
        throwsA(
          isA<NativePluginAdmissionException>().having(
            (error) => error.reason,
            'reason',
            allOf(
              contains('PLUGIN_REGISTRATION_FAILED'),
              contains('GeneratedPluginRegistrant is missing'),
            ),
          ),
        ),
      );
    });

    test('a missing native handler fails closed', () async {
      channel.refusal = MissingPluginException(
        'No implementation found for method admitPlugins',
      );

      await expectLater(
        gatedAdmission().admit(),
        throwsA(
          isA<NativePluginAdmissionException>().having(
            (error) => error.reason,
            'reason',
            contains('channel is missing'),
          ),
        ),
      );
    });

    test('the channel name and method are the ones the activity declares', () {
      expect(nativePluginAdmissionChannelName, 'com.reaprime/recovery_plugins');
      expect(nativePluginAdmissionMethod, 'admitPlugins');

      final activity = File(_activityPath).readAsStringSync();
      expect(activity, contains('"$nativePluginAdmissionChannelName"'));
      expect(activity, contains('"$nativePluginAdmissionMethod"'));
    });
  });

  group('platform deferral', () {
    test('Android, iOS and macOS defer the generated registrant', () {
      expect(platformDefersGeneratedPluginRegistration('android'), isTrue);
      expect(platformDefersGeneratedPluginRegistration('ios'), isTrue);
      expect(platformDefersGeneratedPluginRegistration('macos'), isTrue);
    });

    test('platforms that attach plugins at engine start never ask', () {
      for (final platform in const <String>['linux', 'windows', 'fuchsia']) {
        expect(
          platformDefersGeneratedPluginRegistration(platform),
          isFalse,
          reason: platform,
        );
      }
    });
  });

  group('Android deferred registration wiring', () {
    late String activity;
    late String configure;

    setUp(() {
      activity = File(_activityPath).readAsStringSync();
      configure = _kotlinFunctionBody(activity, 'configureFlutterEngine');
    });

    test('the engine is configured without registering plugins', () {
      expect(
        configure,
        isNot(contains('super.configureFlutterEngine')),
        reason:
            'FlutterFragmentActivity.configureFlutterEngine only runs the '
            'generated registrant, which must wait for the recovery admission',
      );
      expect(
        _occurrences(activity, 'super.configureFlutterEngine('),
        0,
        reason: 'the documented deferral seam is overriding without super()',
      );
    });

    test('the full generated set is registered through the engine call', () {
      expect(
        _occurrences(
          activity,
          'GeneratedPluginRegister.registerGeneratedPlugins',
        ),
        1,
        reason:
            'a second call site would duplicate engine attachment, and a '
            'hand-maintained list would silently drop new plugins',
      );
      for (final forbidden in const <String>[
        'FirebaseAnalytics',
        'firebase',
        'inappwebview',
        'shared_preferences',
        'foreground_task',
        'universal_ble',
        'FlutterSecureStorage',
      ]) {
        expect(
          activity.toLowerCase(),
          isNot(contains(forbidden.toLowerCase())),
          reason:
              'the activity must not copy the generated plugin list '
              '($forbidden)',
        );
      }
    });

    test('only the recovery bootstrap plugins are attached by hand', () {
      final adds = RegExp(r'\.plugins\.add\(([A-Za-z0-9_.]+)\(\)\)')
          .allMatches(activity)
          .map((match) => match.group(1)!)
          .toList();

      expect(
        adds,
        <String>['JniPlugin', 'JniFlutterPlugin'],
        reason:
            'path_provider on Android is a Dart-FFI plugin that needs the jni '
            'class loader and the jni_flutter application context before the '
            'gate can resolve its own directory; every other plugin waits',
      );
      expect(activity, contains('import com.github.dart_lang.jni.JniPlugin\n'));
      expect(
        activity,
        contains('import com.github.dart_lang.jni_flutter.JniFlutterPlugin\n'),
      );
    });

    test('a missing generated registrant fails instead of fizzling', () {
      final admit = _kotlinFunctionBody(activity, 'admitPlugins');
      final presenceCheck = admit.indexOf('requireGeneratedRegistrant()');
      final registration = admit.indexOf(
        'GeneratedPluginRegister.registerGeneratedPlugins',
      );

      expect(presenceCheck, greaterThanOrEqualTo(0));
      expect(
        presenceCheck,
        lessThan(registration),
        reason:
            'GeneratedPluginRegister logs and returns when the generated '
            'registrant cannot be found, which would leave every plugin '
            'unregistered while admission reported success',
      );
      expect(
        _kotlinFunctionBody(activity, 'requireGeneratedRegistrant'),
        contains(
          'Class.forName("io.flutter.plugins.GeneratedPluginRegistrant")',
        ),
      );
      expect(
        configure,
        contains('PLUGIN_REGISTRATION_FAILED'),
        reason: 'the platform channel must report the failure to Dart',
      );
    });

    test('registration is idempotent for one engine', () {
      final admit = _kotlinFunctionBody(activity, 'admitPlugins');
      final guard = admit.indexOf('admittedEngines.contains(flutterEngine)');
      final registration = admit.indexOf(
        'GeneratedPluginRegister.registerGeneratedPlugins',
      );
      final mark = admit.indexOf('admittedEngines.add(flutterEngine)');

      expect(admit, contains('synchronized(admittedEngines)'));
      expect(guard, greaterThanOrEqualTo(0));
      expect(guard, lessThan(registration));
      expect(registration, lessThan(mark));
      expect(activity, contains('WeakHashMap'));
    });

    test('WebView provider loading waits for admission', () {
      final onCreate = _kotlinFunctionBody(activity, 'onCreate');
      final admit = _kotlinFunctionBody(activity, 'admitPlugins');
      final debugging = _kotlinFunctionBody(activity, 'enableWebViewDebugging');

      expect(
        onCreate,
        isNot(contains('setWebContentsDebuggingEnabled')),
        reason:
            'WebView.setWebContentsDebuggingEnabled resolves the WebView '
            'factory, so it loads the Chromium provider before the gate',
      );
      expect(debugging, contains('setWebContentsDebuggingEnabled'));
      expect(
        admit.indexOf('enableWebViewDebugging()'),
        allOf(
          greaterThanOrEqualTo(0),
          lessThan(
            admit.indexOf('GeneratedPluginRegister.registerGeneratedPlugins'),
          ),
        ),
        reason:
            'WebViews are created by plugins, so debugging is enabled first',
      );
    });

    test('no receiver can build a second engine before admission', () {
      final service = File(_foregroundServicePath).readAsStringSync();
      final manifest = File(_manifestPath).readAsStringSync();

      expect(service, contains('autoRunOnBoot: false'));
      expect(service, contains('autoRunOnMyPackageReplaced: false'));
      expect(
        service,
        isNot(contains('allowAutoRestart: true')),
        reason:
            'ForegroundService.onDestroy schedules a restart alarm when '
            'allowAutoRestart is set, and that alarm starts the service - and '
            'its own Flutter engine with the full generated registrant - in a '
            'fresh process',
      );
      expect(
        service,
        isNot(contains('stopWithTask:')),
        reason:
            'ForegroundService.onTaskRemoved schedules a restart alarm unless '
            'stopWithTask is in effect',
      );
      expect(
        manifest,
        contains('android:stopWithTask="true"'),
        reason:
            'RebootReceiver returns early on the stopWithTask flag and '
            'onTaskRemoved stops instead of arming a restart alarm',
      );
    });
  });

  group('Apple deferred registration wiring', () {
    late String iosDelegate;
    late String macWindow;

    setUp(() {
      iosDelegate = File(_iosAppDelegatePath).readAsStringSync();
      macWindow = File(_macMainWindowPath).readAsStringSync();
    });

    test('the iOS engine callback registers no generated plugin', () {
      final callback = _swiftFunctionBody(
        iosDelegate,
        'didInitializeImplicitFlutterEngine',
      );

      expect(
        callback,
        isNot(contains('GeneratedPluginRegistrant.register(with:')),
        reason:
            'FLTFirebaseCorePlugin.registerWithRegistrar configures the '
            'default FIRApp from the bundled plist, so the generated '
            'registrant cannot run at engine creation',
      );
      expect(
        _occurrences(iosDelegate, 'GeneratedPluginRegistrant.register(with:'),
        1,
        reason:
            'the generated registrant stays the single authoritative plugin '
            'list and is called from one place only',
      );
      expect(
        _swiftFunctionBody(iosDelegate, 'admitPlugins'),
        contains('GeneratedPluginRegistrant.register(with:'),
      );
    });

    test('the iOS engine callback keeps the app-owned channels', () {
      final callback = _swiftFunctionBody(
        iosDelegate,
        'didInitializeImplicitFlutterEngine',
      );

      expect(callback, contains('SecurityScopedFilePlugin.register(with:'));
      expect(
        callback,
        contains('RecoveryProcessIdentityPlugin.register(with:'),
        reason:
            'the recovery gate cannot establish ownership without the '
            'process identity channel, so it must exist before admission',
      );
      expect(callback, contains('PluginAdmission.register('));
      expect(iosDelegate, contains('"$nativePluginAdmissionChannelName"'));
      expect(iosDelegate, contains('"$nativePluginAdmissionMethod"'));
      expect(iosDelegate, contains('com.reaprime/recovery_identity'));
    });

    test('the macOS nib load registers no generated plugin', () {
      final awake = _swiftFunctionBody(macWindow, 'awakeFromNib');

      expect(
        awake,
        isNot(contains('RegisterGeneratedPlugins(registry:')),
        reason:
            'RegisterGeneratedPlugins reaches FLTFirebaseCorePlugin at window '
            'creation, before Dart main() reaches the recovery gate',
      );
      expect(
        _occurrences(macWindow, 'RegisterGeneratedPlugins(registry:'),
        1,
        reason: 'one authoritative registration call site',
      );
      expect(
        _swiftFunctionBody(macWindow, 'admitPlugins'),
        contains('RegisterGeneratedPlugins(registry:'),
      );
      expect(awake, contains('registerPluginAdmission(with:'));
    });

    test('the macOS nib load keeps the app-owned channels', () {
      final awake = _swiftFunctionBody(macWindow, 'awakeFromNib');

      expect(awake, contains('registerRecoveryProcessIdentity(with:'));
      expect(awake, contains('registerSkinCameraPermission(with:'));
      expect(macWindow, contains('"$nativePluginAdmissionChannelName"'));
      expect(macWindow, contains('"$nativePluginAdmissionMethod"'));
      expect(macWindow, contains('com.reaprime/recovery_identity'));
      expect(
        macWindow,
        contains('contentViewController = flutterViewController'),
        reason:
            'the window still presents its native default frame while a '
            'blocked recovery state is shown',
      );
    });

    test('registration is idempotent for one engine on both platforms', () {
      for (final source in [iosDelegate, macWindow]) {
        expect(source, contains('NSLock()'));
        expect(source, contains('Set<ObjectIdentifier>'));
      }
      final cases = <({String body, String register})>[
        (
          body: _swiftFunctionBody(iosDelegate, 'admitPlugins'),
          register: 'GeneratedPluginRegistrant.register(with:',
        ),
        (
          body: _swiftFunctionBody(macWindow, 'admitPlugins'),
          register: 'RegisterGeneratedPlugins(registry:',
        ),
      ];
      for (final testCase in cases) {
        final guard = testCase.body.indexOf('admittedEngines.contains(');
        final register = testCase.body.indexOf(testCase.register);
        final mark = testCase.body.indexOf('admittedEngines.insert(');

        expect(guard, greaterThanOrEqualTo(0));
        expect(register, greaterThan(guard));
        expect(mark, greaterThan(register));
      }
    });

    test('neither Apple runner copies the generated plugin list', () {
      for (final forbidden in const <String>[
        'FLTFirebaseCorePlugin',
        'FirebaseAnalyticsPlugin',
        'FLTFirebaseCrashlyticsPlugin',
        'SharedPreferencesPlugin',
        'WindowManagerPlugin',
        'InAppWebViewFlutterPlugin',
        'UniversalBlePlugin',
        'FlutterSecureStorageDarwinPlugin',
        'FlutterForegroundTaskPlugin',
        'PathProviderPlugin',
      ]) {
        expect(iosDelegate, isNot(contains(forbidden)), reason: forbidden);
        expect(macWindow, isNot(contains(forbidden)), reason: forbidden);
      }
    });

    test('only the app-owned Apple channels bypass the deferral', () {
      for (final path in const <String>[
        _iosAppDelegatePath,
        _macAppDelegatePath,
        _macMainWindowPath,
      ]) {
        expect(File(path).existsSync(), isTrue, reason: path);
      }
      expect(
        _occurrences(iosDelegate, 'FlutterMethodChannel('),
        3,
        reason:
            'exactly three channels exist before admission: security-scoped '
            'access, process identity and plugin admission',
      );
      expect(iosDelegate, contains('SecurityScopedFilePlugin'));
      expect(iosDelegate, contains('RecoveryProcessIdentityPlugin'));
    });

    test('no other Apple runner source registers plugins', () {
      for (final directory in const <String>['ios/Runner', 'macos/Runner']) {
        for (final entity in Directory(directory).listSync(recursive: true)) {
          if (entity is! File) continue;
          if (!entity.path.endsWith('.swift') && !entity.path.endsWith('.m')) {
            continue;
          }
          final source = entity.readAsStringSync();
          final registers =
              source.contains('GeneratedPluginRegistrant.register(with:') ||
              source.contains('RegisterGeneratedPlugins(registry:');
          if (!registers) continue;
          expect(
            entity.path,
            anyOf(_iosAppDelegatePath, _macMainWindowPath),
            reason:
                'a second registration site would bypass the recovery '
                'admission fence',
          );
        }
      }
    });

    test('the generated registrants still carry the Firebase plugins', () {
      final iosRegistrant = File(_iosRegistrantPath).readAsStringSync();
      final macRegistrant = File(_macRegistrantPath).readAsStringSync();

      expect(iosRegistrant, contains('FLTFirebaseCorePlugin'));
      expect(macRegistrant, contains('FLTFirebaseCorePlugin.register('));
      expect(
        iosRegistrant.contains('PathProvider') ||
            macRegistrant.contains('PathProvider'),
        isFalse,
        reason:
            'AppDirectories must keep resolving paths before admission: '
            'path_provider_foundation is a Dart-FFI plugin with no native '
            'registration, so a native path provider would break the gate',
      );
      expect(
        File('pubspec.lock').readAsStringSync(),
        contains('path_provider_foundation'),
      );
    });
  });

  group('normal startup admission wiring', () {
    late String normalStart;

    setUp(() {
      final source = File(_mainPath).readAsStringSync();
      normalStart = _dartFunctionBody(
        source,
        'Future<void> startDecaidNormalServices(',
      );
    });

    test('plugins are admitted before any sensitive initialisation', () {
      final admission = normalStart.indexOf('await admitNativePlugins();');
      expect(admission, greaterThanOrEqualTo(0));

      for (final marker in _sensitiveInitialisations) {
        final index = normalStart.indexOf(marker);
        expect(index, greaterThan(admission), reason: marker);
      }
    });

    test('a failed admission stops normal startup with a visible error', () {
      final admission = normalStart.indexOf('await admitNativePlugins();');
      final failureView = normalStart.indexOf(
        '_NativePluginAdmissionFailureApp(',
      );
      final refusal = normalStart.indexOf('catch (error, stackTrace)');
      final firstSensitive = _sensitiveInitialisations
          .map(normalStart.indexOf)
          .reduce((a, b) => a < b ? a : b);

      expect(refusal, greaterThan(admission));
      expect(failureView, greaterThan(refusal));
      expect(
        normalStart.substring(refusal, firstSensitive),
        contains('return;'),
        reason:
            'a refused registration must not fall through to normal services '
            'that would then fail as unrelated missing-plugin errors',
      );
      expect(failureView, lessThan(firstSensitive));
    });

    test('plugin-dependent desktop setup waits for admission', () {
      final source = File(_mainPath).readAsStringSync();
      final main = _dartFunctionBody(source, 'void main(List<String> args)');
      final admission = normalStart.indexOf('await admitNativePlugins();');

      for (final marker in const <String>[
        'WindowManager.instance',
        'enableSimulatedWebViews()',
        'loadPersistedSimulatedWebViewDevice()',
        'setSimulatedWebViewDevice(',
      ]) {
        expect(main, isNot(contains(marker)), reason: marker);
      }
      for (final marker in const <String>[
        'WindowManager.instance.ensureInitialized()',
        'WindowManager.instance.setAspectRatio(',
        'WindowManager.instance.setSize(',
        'enableSimulatedWebViews()',
        'loadPersistedSimulatedWebViewDevice()',
      ]) {
        final index = normalStart.indexOf(marker);
        expect(index, greaterThan(admission), reason: marker);
      }
      expect(
        normalStart,
        contains('Platform.isMacOS'),
        reason:
            'the moved setup still covers every desktop platform it used to '
            'cover',
      );
    });

    test('CLI parsing and path printing stay available before the gate', () {
      final source = File(_mainPath).readAsStringSync();
      final main = _dartFunctionBody(source, 'void main(List<String> args)');
      final parse = main.indexOf('parseCliArgs(');
      final printPaths = main.indexOf('_printStoragePaths()');
      final gate = main.indexOf('runNewOwnerRecoveryStartup(');

      expect(parse, greaterThanOrEqualTo(0));
      expect(printPaths, greaterThan(parse));
      expect(gate, greaterThan(printPaths));
      expect(
        main.indexOf('Firebase.initializeApp('),
        -1,
        reason: 'Firebase initialization belongs to admitted normal startup',
      );
    });

    test('the admission failure text is not Android-specific', () {
      final source = File(_mainPath).readAsStringSync();

      expect(source, isNot(contains('The Android plugins this app runs on')));
      expect(source, contains('native plugins this app runs on were not'));
    });
  });
}

final class _RecordingAdmissionChannel implements NativePluginAdmissionChannel {
  int calls = 0;
  Object? refusal;

  @override
  Future<void> admit() async {
    calls++;
    final error = refusal;
    if (error != null) throw error;
  }
}

int _occurrences(String source, String needle) =>
    needle.allMatches(source).length;

/// The body of a Kotlin function, from its opening brace to the matching close.
String _kotlinFunctionBody(String source, String name) {
  final signature = source.indexOf('fun $name(');
  expect(signature, greaterThanOrEqualTo(0), reason: 'fun $name not found');
  final open = source.indexOf('{', signature);
  expect(open, greaterThanOrEqualTo(0), reason: 'fun $name has no body');
  var depth = 0;
  for (var index = open; index < source.length; index++) {
    final char = source[index];
    if (char == '{') depth++;
    if (char == '}') {
      depth--;
      if (depth == 0) return source.substring(open, index + 1);
    }
  }
  fail('fun $name body is not balanced');
}

/// The body of a Swift function, from its opening brace to the matching close.
///
/// String literals are skipped so interpolated or brace-bearing text cannot
/// unbalance the scan.
String _swiftFunctionBody(String source, String name) {
  final signature = source.indexOf('func $name(');
  expect(signature, greaterThanOrEqualTo(0), reason: 'func $name not found');
  final open = source.indexOf('{', signature);
  expect(open, greaterThanOrEqualTo(0), reason: 'func $name has no body');
  var depth = 0;
  var inString = false;
  var escaped = false;
  for (var index = open; index < source.length; index++) {
    final char = source[index];
    if (inString) {
      if (escaped) {
        escaped = false;
        continue;
      }
      if (char == r'\') {
        escaped = true;
        continue;
      }
      if (char == '"') inString = false;
      continue;
    }
    if (char == '"') {
      inString = true;
      continue;
    }
    if (char == '{') depth++;
    if (char == '}') {
      depth--;
      if (depth == 0) return source.substring(open, index + 1);
    }
  }
  fail('func $name body is not balanced');
}

/// The body of a top-level Dart function: the block after `async {`.
String _dartFunctionBody(String source, String signature) {
  final start = source.indexOf(signature);
  expect(start, greaterThanOrEqualTo(0), reason: '$signature not found');
  final open = source.indexOf('async {', start) + 'async '.length;
  var depth = 0;
  for (var index = open; index < source.length; index++) {
    final char = source[index];
    if (char == '{') depth++;
    if (char == '}') {
      depth--;
      if (depth == 0) return source.substring(open, index + 1);
    }
  }
  fail('$signature body is not balanced');
}
