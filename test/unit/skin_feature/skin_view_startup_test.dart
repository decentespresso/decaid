import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:logging/logging.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';
import 'package:reaprime/src/controllers/device_controller.dart';
import 'package:reaprime/src/controllers/display_controller.dart';
import 'package:reaprime/src/launcher/launcher_view.dart';
import 'package:reaprime/src/services/webview_compatibility_checker.dart';
import 'package:reaprime/src/services/webview_log_service.dart';
import 'package:reaprime/src/settings/settings_controller.dart';
import 'package:reaprime/src/skin_feature/simulated_webview_device.dart';
import 'package:reaprime/src/skin_feature/skin_view.dart';
import 'package:url_launcher_platform_interface/url_launcher_platform_interface.dart';

import '../../helpers/mock_de1_controller.dart';
import '../../helpers/mock_settings_service.dart';

class _WebViewPlatform extends InAppWebViewPlatform {
  final Future<String?> version;

  _WebViewPlatform(this.version, {this.unsupported = const {}});

  final Set<PlatformInAppWebViewControllerMethod> unsupported;

  @override
  PlatformInAppWebViewController createPlatformInAppWebViewControllerStatic() =>
      _StaticController(unsupported);

  @override
  PlatformInAppWebViewWidget createPlatformInAppWebViewWidget(
    PlatformInAppWebViewWidgetCreationParams params,
  ) => _WebView(params);

  @override
  PlatformWebViewEnvironment createPlatformWebViewEnvironmentStatic() =>
      _Environment(version);
}

class _Environment extends PlatformWebViewEnvironment {
  final Future<String?> version;

  _Environment(this.version)
    : super.implementation(const PlatformWebViewEnvironmentCreationParams());

  @override
  Future<String?> getAvailableVersion({String? browserExecutableFolder}) =>
      version;
}

class _WebView extends PlatformInAppWebViewWidget {
  _WebView(super.params) : super.implementation();

  @override
  Widget build(BuildContext context) => const SizedBox.expand();

  @override
  T controllerFromPlatform<T>(PlatformInAppWebViewController controller) =>
      InAppWebViewController.fromPlatform(platform: controller) as T;

  @override
  void dispose() {}
}

class _Controller extends PlatformInAppWebViewController {
  _Controller()
    : super.implementation(
        const PlatformInAppWebViewControllerCreationParams(id: 1),
      );
}

class _StaticController extends _Controller {
  _StaticController(this.unsupported);

  final Set<PlatformInAppWebViewControllerMethod> unsupported;

  @override
  bool isMethodSupported(
    PlatformInAppWebViewControllerMethod method, {
    TargetPlatform? platform,
  }) => !unsupported.contains(method);

  @override
  Future<void> clearAllCache({bool includeDiskFiles = true}) async {}
}

class _TimerController extends _Controller {
  final calls = <String>[];
  Future<void> Function()? onPauseTimers;
  Future<void> Function()? onResumeTimers;

  @override
  Future<void> pause() async => calls.add('pause');

  @override
  Future<void> resume() async => calls.add('resume');

  @override
  Future<void> pauseTimers() async {
    calls.add('pauseTimers');
    await onPauseTimers?.call();
  }

  @override
  Future<void> resumeTimers() async {
    calls.add('resumeTimers');
    await onResumeTimers?.call();
  }

  @override
  Future<void> loadUrl({
    required URLRequest urlRequest,
    Uri? iosAllowingReadAccessTo,
    WebUri? allowingReadAccessTo,
  }) async => calls.add('load:${urlRequest.url}');
}

class _UrlLauncher extends Fake
    with MockPlatformInterfaceMixin
    implements UrlLauncherPlatform {
  final void Function(Uri, PreferredLaunchMode) record;
  final bool launchResult;

  _UrlLauncher(this.record, {this.launchResult = true});

  @override
  Future<bool> canLaunch(String url) async => true;

  @override
  Future<bool> launchUrl(String url, LaunchOptions options) async {
    record(Uri.parse(url), options.mode);
    return launchResult;
  }

  @override
  Future<bool> supportsMode(PreferredLaunchMode mode) async => true;
}

Future<void> _pumpSkin(
  WidgetTester tester, {
  Future<CompatibilityResult> Function()? checkCompatibility,
  Set<PlatformInAppWebViewControllerMethod> unsupported = const {},
  Widget Function(SkinView)? wrap,
}) async {
  final previous = InAppWebViewPlatform.instance;
  InAppWebViewPlatform.instance = _WebViewPlatform(
    Future.value('test'),
    unsupported: unsupported,
  );
  WebViewCompatibilityChecker.clearCache();
  final settings = SettingsController(MockSettingsService());
  final logs = WebViewLogService(logDirectoryPath: '.');
  final display = DisplayController(
    de1Controller: MockDe1Controller(controller: DeviceController(const [])),
    settingsController: settings,
    setBrightness: (_) async {},
    resetBrightness: () async {},
    enableWakeLock: () async {},
    disableWakeLock: () async {},
    platformSupport: const DisplayPlatformSupport(
      brightness: false,
      wakeLock: false,
    ),
  );
  addTearDown(() {
    display.dispose();
    settings.dispose();
    logs.dispose();
    WebViewCompatibilityChecker.clearCache();
    if (previous != null) InAppWebViewPlatform.instance = previous;
  });
  final skin = SkinView(
    settingsController: settings,
    webViewLogService: logs,
    deviceIp: '127.0.0.1',
    displayController: display,
    port: 24800,
    checkCompatibility:
        checkCompatibility ?? WebViewCompatibilityChecker.checkCompatibility,
  );
  await tester.pumpWidget(
    MaterialApp(
      routes: {
        LauncherView.routeName: (_) => const Scaffold(body: Text('Dashboard')),
      },
      home: wrap?.call(skin) ?? skin,
    ),
  );
  await tester.pump();
  await tester.pump();
}

PlatformInAppWebViewWidgetCreationParams _params(WidgetTester tester) =>
    tester.widget<InAppWebView>(find.byType(InAppWebView)).platform.params;

List<LogRecord> _recordSkinLogs() {
  final records = <LogRecord>[];
  final subscription = Logger('SkinView').onRecord.listen(records.add);
  addTearDown(subscription.cancel);
  return records;
}

void _lifecycle(WidgetTester tester, AppLifecycleState state) {
  final observer =
      tester.state(find.byType(SkinView)) as WidgetsBindingObserver;
  observer.didChangeAppLifecycleState(state);
}

Future<_TimerController> _createTimerView(WidgetTester tester) async {
  final controller = _TimerController();
  _params(tester).onWebViewCreated!(
    InAppWebViewController.fromPlatform(platform: controller),
  );
  await tester.pump();
  controller.calls.clear();
  return controller;
}

void main() {
  final controller = InAppWebViewController.fromPlatform(
    platform: _Controller(),
  );
  final url = WebUri('http://localhost:24800/');
  final windows = TargetPlatformVariant.only(TargetPlatform.windows);

  for (final action in ['Open in Browser', 'Go to Dashboard']) {
    testWidgets('Windows timeout recovery: $action', (tester) async {
      final previous = UrlLauncherPlatform.instance;
      Uri? launched;
      PreferredLaunchMode? mode;
      UrlLauncherPlatform.instance = _UrlLauncher((uri, launchMode) {
        launched = uri;
        mode = launchMode;
      });
      addTearDown(() => UrlLauncherPlatform.instance = previous);
      await _pumpSkin(tester);
      await tester.pump(const Duration(seconds: 30));
      await tester.tap(find.text(action));
      await tester.pumpAndSettle();

      expect(find.text('Dashboard'), findsOneWidget);
      if (action == 'Open in Browser') {
        expect(launched?.origin, 'http://localhost:3000');
        expect(mode, PreferredLaunchMode.externalApplication);
      } else {
        expect(launched, isNull);
      }
      await tester.pumpWidget(const SizedBox.shrink());
    }, variant: windows);
  }

  testWidgets('failed browser launch keeps the timeout recovery screen', (
    tester,
  ) async {
    final previous = UrlLauncherPlatform.instance;
    UrlLauncherPlatform.instance = _UrlLauncher((_, _) {}, launchResult: false);
    addTearDown(() => UrlLauncherPlatform.instance = previous);
    await _pumpSkin(tester);
    await tester.pump(const Duration(seconds: 30));
    await tester.tap(find.text('Open in Browser'));
    await tester.pumpAndSettle();

    expect(find.text('Dashboard'), findsNothing);
    expect(find.text('WebView Error'), findsOneWidget);
    expect(find.textContaining('Unable to open browser'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
  }, variant: windows);

  for (final loaded in [false, true]) {
    testWidgets('replacement starts fresh after loaded=$loaded', (
      tester,
    ) async {
      final previous = simulatedWebViewDevice.value;
      addTearDown(() => simulatedWebViewDevice.value = previous);
      await _pumpSkin(tester);
      final oldParams = _params(tester);
      oldParams.onWebViewCreated!(controller);
      if (loaded) oldParams.onLoadStop!(controller, url);
      await tester.pump();

      simulatedWebViewDevice.value = SimulatedWebViewDevice.teclastP80X;
      await tester.pump();
      final replacement = _params(tester);
      expect(replacement, isNot(same(oldParams)));
      await tester.pump(const Duration(seconds: 30));
      expect(
        find.textContaining('embedded browser did not start'),
        findsOneWidget,
      );

      oldParams.onWebViewCreated!(controller);
      oldParams.onLoadStop!(controller, url);
      oldParams.onReceivedError!(
        controller,
        WebResourceRequest(url: url, isForMainFrame: true),
        WebResourceError(
          type: WebResourceErrorType.UNKNOWN,
          description: 'old',
        ),
      );
      await tester.pump();
      expect(
        find.textContaining('embedded browser did not start'),
        findsOneWidget,
      );

      replacement.onWebViewCreated!(controller);
      replacement.onLoadStop!(controller, url);
      await tester.pump();
      expect(find.text('WebView Error'), findsNothing);
      await tester.pumpWidget(const SizedBox.shrink());
    }, variant: windows);
  }

  testWidgets('Windows creation timeout retains the view and offers recovery', (
    tester,
  ) async {
    await _pumpSkin(tester);
    await tester.pump(const Duration(seconds: 29));
    expect(find.byType(CircularProgressIndicator), findsOneWidget);

    await tester.pump(const Duration(seconds: 1));
    expect(find.text('WebView Error'), findsOneWidget);
    expect(
      find.textContaining('embedded browser did not start'),
      findsOneWidget,
    );
    expect(find.text('Open in Browser'), findsOneWidget);
    expect(find.text('Go to Dashboard'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(find.byType(InAppWebView), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
  }, variant: windows);

  testWidgets(
    'Windows timeout distinguishes a created view from a loaded page',
    (tester) async {
      await _pumpSkin(tester);
      _params(tester).onWebViewCreated!(controller);
      _params(tester).onLoadStart!(controller, url);
      await tester.pump(const Duration(seconds: 30));

      expect(
        find.textContaining('skin did not finish loading'),
        findsOneWidget,
      );
      expect(find.byType(CircularProgressIndicator), findsNothing);
      await tester.pumpWidget(const SizedBox.shrink());
    },
    variant: windows,
  );

  testWidgets('successful Windows load cancels the timeout', (tester) async {
    await _pumpSkin(tester);
    _params(tester).onLoadStop!(controller, url);
    await tester.pump(const Duration(seconds: 31));

    expect(find.text('WebView Error'), findsNothing);
    expect(find.byType(CircularProgressIndicator), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
  }, variant: windows);

  testWidgets('a late Windows load recovers without recreating the view', (
    tester,
  ) async {
    await _pumpSkin(tester);
    final params = _params(tester);
    final view = tester.element(find.byType(InAppWebView));
    await tester.pump(const Duration(seconds: 30));
    expect(find.text('WebView Error'), findsOneWidget);
    expect(tester.element(find.byType(InAppWebView)), same(view));

    params.onWebViewCreated!(controller);
    params.onLoadStart!(controller, url);
    await tester.pump();
    expect(find.text('WebView Error'), findsOneWidget);
    params.onLoadStop!(controller, url);
    await tester.pump();
    expect(find.text('WebView Error'), findsNothing);
    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(find.byType(InAppWebView), findsOneWidget);
    expect(tester.element(find.byType(InAppWebView)), same(view));
    await tester.pumpWidget(const SizedBox.shrink());
  }, variant: windows);

  testWidgets('a main-frame error is not overwritten by the Windows timeout', (
    tester,
  ) async {
    await _pumpSkin(tester);
    _params(tester).onReceivedError!(
      controller,
      WebResourceRequest(url: url, isForMainFrame: true),
      WebResourceError(
        type: WebResourceErrorType.UNKNOWN,
        description: 'connection refused',
      ),
    );
    await tester.pump(const Duration(seconds: 31));

    expect(
      find.text('Failed to load skin: connection refused'),
      findsOneWidget,
    );
    expect(find.textContaining('30 seconds'), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
  }, variant: windows);

  testWidgets('disposing the Windows view cancels its startup timeout', (
    tester,
  ) async {
    await _pumpSkin(tester);
    final params = _params(tester);
    await tester.pumpWidget(const SizedBox.shrink());
    params.onWebViewCreated!(controller);
    params.onLoadStart!(controller, url);
    params.onLoadStop!(controller, url);
    await tester.pump(const Duration(seconds: 31));
    expect(tester.takeException(), isNull);
  }, variant: windows);

  testWidgets(
    'a compatibility probe can finish after the view closes',
    (tester) async {
      final compatibility = Completer<CompatibilityResult>();
      var checks = 0;
      await _pumpSkin(
        tester,
        checkCompatibility: () {
          checks++;
          return compatibility.future;
        },
      );
      expect(checks, 1);
      expect(find.text('Checking device compatibility...'), findsOneWidget);
      expect(find.byType(InAppWebView), findsNothing);
      await tester.pumpWidget(const SizedBox.shrink());
      compatibility.complete(const CompatibilityResult.compatible());
      await tester.pump();
      expect(tester.takeException(), isNull);
      expect(find.byType(InAppWebView), findsNothing);
    },
    variant: TargetPlatformVariant({
      TargetPlatform.windows,
      TargetPlatform.android,
      TargetPlatform.iOS,
    }),
  );

  testWidgets('Windows startup errors fit a small window', (tester) async {
    tester.view.physicalSize = const Size(360, 320);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await _pumpSkin(tester);
    await tester.pump(const Duration(seconds: 30));

    expect(find.text('WebView Error'), findsOneWidget);
    expect(
      tester.getRect(find.text('Go to Dashboard')).bottom,
      lessThanOrEqualTo(320),
    );
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  }, variant: windows);

  final mobile = TargetPlatformVariant({
    TargetPlatform.android,
    TargetPlatform.iOS,
  });

  for (final exit in ['resume', 'dispose']) {
    for (final failure in ['unsupported', 'missing plugin', 'platform error']) {
      testWidgets('timer pause $failure followed by $exit is balanced', (
        tester,
      ) async {
        final records = _recordSkinLogs();
        await _pumpSkin(
          tester,
          checkCompatibility: () async =>
              const CompatibilityResult.compatible(),
          unsupported: failure == 'unsupported' ? {.pauseTimers} : {},
        );
        final controller = await _createTimerView(tester);
        final pause = Completer<void>();
        controller.onPauseTimers = () => pause.future;
        _lifecycle(tester, AppLifecycleState.paused);
        await tester.pump();
        expect(
          controller.calls.where((call) => call == 'pauseTimers').length,
          failure == 'unsupported' ? 0 : 1,
        );
        if (failure != 'unsupported') {
          pause.completeError(
            failure == 'missing plugin'
                ? MissingPluginException('pause unavailable')
                : PlatformException(code: 'pause-failed'),
          );
          await tester.pump();
          expect(tester.takeException(), isNull);
          expect(
            records.where((record) => record.level == Level.SEVERE),
            contains(
              isA<LogRecord>().having(
                (record) => record.error,
                'bridge error',
                failure == 'missing plugin'
                    ? isA<MissingPluginException>()
                    : isA<PlatformException>(),
              ),
            ),
          );
        }
        if (exit == 'resume') {
          _lifecycle(tester, AppLifecycleState.resumed);
          await tester.pump();
        }
        await tester.pumpWidget(const SizedBox.shrink());
        expect(
          records.where((record) => record.message.startsWith('Balanced')),
          isEmpty,
        );
        expect(
          controller.calls.where((call) => call == 'resumeTimers').length,
          exit == 'resume' ? 1 : 0,
        );
      }, variant: mobile);
    }
  }

  for (final exit in ['resume', 'dispose']) {
    testWidgets('pending successful pause is balanced on $exit', (
      tester,
    ) async {
      final records = _recordSkinLogs();
      await _pumpSkin(
        tester,
        checkCompatibility: () async => const CompatibilityResult.compatible(),
      );
      final controller = await _createTimerView(tester);
      final pause = Completer<void>();
      controller.onPauseTimers = () => pause.future;
      _lifecycle(tester, AppLifecycleState.paused);
      await tester.pump();
      expect(controller.calls, contains('pauseTimers'));
      if (exit == 'resume') {
        _lifecycle(tester, AppLifecycleState.resumed);
      } else {
        await tester.pumpWidget(const SizedBox.shrink());
      }
      await tester.pump();
      expect(controller.calls, isNot(contains('resumeTimers')));
      pause.complete();
      await tester.pump();
      expect(
        controller.calls.where((call) => call == 'resumeTimers').length,
        1,
      );
      expect(tester.takeException(), isNull);
      if (exit == 'resume') await tester.pumpWidget(const SizedBox.shrink());
      expect(records.where((record) => record.level == Level.SEVERE), isEmpty);
    }, variant: mobile);
  }

  for (final recovery in ['dispose', 'onWebViewCreated']) {
    for (final failure in ['unsupported', 'missing plugin', 'platform error']) {
      testWidgets('failed resume $failure retains timer debt for $recovery', (
        tester,
      ) async {
        final unsupported = <PlatformInAppWebViewControllerMethod>{};
        final records = _recordSkinLogs();
        await _pumpSkin(
          tester,
          checkCompatibility: () async =>
              const CompatibilityResult.compatible(),
          unsupported: unsupported,
        );
        final controller = await _createTimerView(tester);
        _lifecycle(tester, AppLifecycleState.paused);
        await tester.pump();
        if (failure == 'unsupported') {
          unsupported.add(.resumeTimers);
        } else {
          controller.onResumeTimers = () async {
            await Future<void>.value();
            if (failure == 'missing plugin') {
              throw MissingPluginException('resume unavailable');
            }
            throw PlatformException(code: 'resume-failed');
          };
        }
        _lifecycle(tester, AppLifecycleState.resumed);
        await tester.pump();
        expect(tester.takeException(), isNull);
        expect(
          records.where((record) => record.message.startsWith('Balanced')),
          isEmpty,
        );
        expect(
          records.where((record) => record.level == Level.SEVERE),
          hasLength(failure == 'unsupported' ? 0 : 1),
        );
        if (recovery == 'dispose') {
          unsupported.clear();
          controller.onResumeTimers = null;
        }
        await tester.pumpWidget(const SizedBox.shrink());
        expect(
          records.where((record) => record.message.startsWith('Balanced')),
          hasLength(recovery == 'dispose' ? 1 : 0),
        );
        final afterDispose = controller.calls
            .where((call) => call == 'resumeTimers')
            .length;
        await _pumpSkin(
          tester,
          checkCompatibility: () async =>
              const CompatibilityResult.compatible(),
        );
        await _createTimerView(tester);
        await tester.pumpWidget(const SizedBox.shrink());
        expect(
          controller.calls.where((call) => call == 'resumeTimers'),
          hasLength(afterDispose),
        );
        expect(
          records.where(
            (record) =>
                record.message == 'Balanced WebView timer pause in $recovery',
          ),
          hasLength(1),
        );
      }, variant: mobile);
    }
  }

  testWidgets('a queued pause is discarded after the lifecycle resumes', (
    tester,
  ) async {
    await _pumpSkin(
      tester,
      checkCompatibility: () async => const CompatibilityResult.compatible(),
    );
    final controller = await _createTimerView(tester);
    final resume = Completer<void>();
    controller.onResumeTimers = () => resume.future;
    _lifecycle(tester, AppLifecycleState.resumed);
    await tester.pump();
    _lifecycle(tester, AppLifecycleState.paused);
    _lifecycle(tester, AppLifecycleState.resumed);
    resume.complete();
    await tester.pump();
    expect(controller.calls, isNot(contains('pauseTimers')));
    await tester.pumpWidget(const SizedBox.shrink());
  }, variant: mobile);

  testWidgets('a disposed view cannot overtake a new SkinView timer pause', (
    tester,
  ) async {
    final records = _recordSkinLogs();
    await _pumpSkin(
      tester,
      checkCompatibility: () async => const CompatibilityResult.compatible(),
    );
    final old = await _createTimerView(tester);
    final pause = Completer<void>();
    old.onPauseTimers = () => pause.future;
    _lifecycle(tester, AppLifecycleState.paused);
    await tester.pump();
    await tester.pumpWidget(const SizedBox.shrink());
    await _pumpSkin(
      tester,
      checkCompatibility: () async => const CompatibilityResult.compatible(),
    );
    final replacement = await _createTimerView(tester);
    _lifecycle(tester, AppLifecycleState.paused);
    await tester.pump();
    expect(replacement.calls, isNot(contains('pauseTimers')));
    pause.complete();
    await tester.pump();
    expect(replacement.calls, contains('pauseTimers'));
    records.clear();
    await tester.pumpWidget(const SizedBox.shrink());
    expect(
      records.where(
        (record) => record.message == 'Balanced WebView timer pause in dispose',
      ),
      hasLength(1),
    );
  }, variant: mobile);

  testWidgets('late old view disposal cannot resume a replacement pause', (
    tester,
  ) async {
    final records = _recordSkinLogs();
    final views = ValueNotifier((old: true, replacement: false));
    addTearDown(views.dispose);
    await _pumpSkin(
      tester,
      checkCompatibility: () async => const CompatibilityResult.compatible(),
      wrap: (skin) => ValueListenableBuilder(
        valueListenable: views,
        builder: (context, visible, _) => Stack(
          children: [
            if (visible.old)
              KeyedSubtree(key: const ValueKey('old'), child: skin),
            if (visible.replacement)
              KeyedSubtree(key: const ValueKey('replacement'), child: skin),
          ],
        ),
      ),
    );
    final old = await _createTimerView(tester);
    views.value = (old: true, replacement: true);
    await tester.pump();
    await tester.pump();
    final replacement = _TimerController();
    final params = tester
        .widget<InAppWebView>(find.byType(InAppWebView).last)
        .platform
        .params;
    params.onWebViewCreated!(
      InAppWebViewController.fromPlatform(platform: replacement),
    );
    await tester.pump();
    final observer =
        tester.state(find.byType(SkinView).last) as WidgetsBindingObserver;
    observer.didChangeAppLifecycleState(AppLifecycleState.paused);
    await tester.pump();
    expect(replacement.calls, ['resumeTimers', 'pause', 'pauseTimers']);
    views.value = (old: false, replacement: true);
    await tester.pump();
    expect(old.calls, isNot(contains('resumeTimers')));
    expect(replacement.calls, ['resumeTimers', 'pause', 'pauseTimers']);
    records.clear();
    await tester.pumpWidget(const SizedBox.shrink());
    expect(
      replacement.calls.where((call) => call == 'resumeTimers'),
      hasLength(2),
    );
    expect(
      records.where(
        (record) => record.message == 'Balanced WebView timer pause in dispose',
      ),
      hasLength(1),
    );
  }, variant: mobile);

  testWidgets('renderer recovery balances timers and creates a fresh view', (
    tester,
  ) async {
    await _pumpSkin(
      tester,
      checkCompatibility: () async => const CompatibilityResult.compatible(),
    );
    final old = await _createTimerView(tester);
    _lifecycle(tester, AppLifecycleState.paused);
    await tester.pump();
    _params(tester).onRenderProcessGone!(
      InAppWebViewController.fromPlatform(platform: old),
      RenderProcessGoneDetail(didCrash: true),
    );
    await tester.pump();
    expect(find.text('Reloading skin...'), findsOneWidget);
    expect(old.calls, contains('resumeTimers'));
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.byType(InAppWebView), findsOneWidget);
    final replacement = await _createTimerView(tester);
    _params(tester).onLoadStop!(
      InAppWebViewController.fromPlatform(platform: replacement),
      url,
    );
    await tester.pump();
    expect(find.text('Reloading skin...'), findsNothing);
    expect(find.byType(CircularProgressIndicator), findsNothing);
    _lifecycle(tester, AppLifecycleState.resumed);
    await tester.pump();
    await tester.pumpWidget(const SizedBox.shrink());
    expect(tester.takeException(), isNull);
  }, variant: mobile);

  testWidgets('successful background blanks after ten minutes and reloads', (
    tester,
  ) async {
    await _pumpSkin(
      tester,
      checkCompatibility: () async => const CompatibilityResult.compatible(),
    );
    final controller = await _createTimerView(tester);
    _lifecycle(tester, AppLifecycleState.paused);
    await tester.pump(const Duration(minutes: 9));
    expect(controller.calls, ['pause', 'pauseTimers']);
    await tester.pump(const Duration(minutes: 1));
    expect(controller.calls.last, 'load:about:blank');
    _lifecycle(tester, AppLifecycleState.resumed);
    await tester.pump();
    expect(controller.calls, containsAll(['resume', 'resumeTimers']));
    expect(
      controller.calls.where(
        (call) => call.startsWith('load:http://localhost:24800/'),
      ),
      hasLength(1),
    );
    await tester.pumpWidget(const SizedBox.shrink());
  }, variant: mobile);

  testWidgets('stale resume cannot clear a replacement timer pause', (
    tester,
  ) async {
    final previous = simulatedWebViewDevice.value;
    addTearDown(() => simulatedWebViewDevice.value = previous);
    final records = _recordSkinLogs();
    await _pumpSkin(
      tester,
      checkCompatibility: () async => const CompatibilityResult.compatible(),
    );
    final old = await _createTimerView(tester);
    final resume = Completer<void>();
    old.onResumeTimers = () => resume.future;
    _lifecycle(tester, AppLifecycleState.resumed);
    await tester.pump();
    expect(old.calls, contains('resumeTimers'));
    simulatedWebViewDevice.value = SimulatedWebViewDevice.teclastP80X;
    await tester.pump();
    final replacement = await _createTimerView(tester);
    _lifecycle(tester, AppLifecycleState.paused);
    await tester.pump();
    resume.complete();
    await tester.pump();
    expect(replacement.calls, contains('pauseTimers'));
    records.clear();
    await tester.pumpWidget(const SizedBox.shrink());
    expect(
      replacement.calls.where((call) => call == 'resumeTimers'),
      hasLength(2),
    );
    expect(
      records.where(
        (record) => record.message == 'Balanced WebView timer pause in dispose',
      ),
      hasLength(1),
    );
  }, variant: mobile);

  testWidgets('stale pause finishes before replacement timer work', (
    tester,
  ) async {
    final previous = simulatedWebViewDevice.value;
    addTearDown(() => simulatedWebViewDevice.value = previous);
    await _pumpSkin(
      tester,
      checkCompatibility: () async => const CompatibilityResult.compatible(),
    );
    final old = await _createTimerView(tester);
    final pause = Completer<void>();
    old.onPauseTimers = () => pause.future;
    _lifecycle(tester, AppLifecycleState.paused);
    await tester.pump();
    expect(old.calls, contains('pauseTimers'));
    simulatedWebViewDevice.value = SimulatedWebViewDevice.teclastP80X;
    await tester.pump();
    final replacement = await _createTimerView(tester);
    _lifecycle(tester, AppLifecycleState.paused);
    await tester.pump();
    expect(replacement.calls, isNot(contains('pauseTimers')));
    pause.complete();
    await tester.pump();
    expect(old.calls, isNot(contains('resumeTimers')));
    expect(replacement.calls, contains('pauseTimers'));
    await tester.pumpWidget(const SizedBox.shrink());
    expect(
      replacement.calls.where((call) => call == 'resumeTimers'),
      hasLength(2),
    );
  }, variant: mobile);

  testWidgets('other platforms do not acquire a Windows startup timeout', (
    tester,
  ) async {
    await _pumpSkin(tester);
    await tester.pump(const Duration(seconds: 31));

    expect(find.text('WebView Error'), findsNothing);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
  }, variant: TargetPlatformVariant.only(TargetPlatform.android));
}
