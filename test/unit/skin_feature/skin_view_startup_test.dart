import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:logging/logging.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';
import 'package:reaprime/src/controllers/device_controller.dart';
import 'package:reaprime/src/controllers/display_controller.dart';
import 'package:reaprime/src/launcher/launcher_view.dart';
import 'package:reaprime/src/services/listener_recovery_coordinator.dart';
import 'package:reaprime/src/services/webserver/api_listener.dart';
import 'package:reaprime/src/services/webview_compatibility_checker.dart';
import 'package:reaprime/src/services/webview_log_service.dart';
import 'package:reaprime/src/settings/settings_controller.dart';
import 'package:reaprime/src/skin_feature/simulated_webview_device.dart';
import 'package:reaprime/src/skin_feature/skin_view.dart';
import 'package:reaprime/src/skin_feature/skin_switch_coordinator.dart';
import 'package:reaprime/src/webui_support/webui_service.dart';
import 'package:shelf/shelf.dart' as shelf;
import 'package:url_launcher_platform_interface/url_launcher_platform_interface.dart';

import '../../helpers/mock_de1_controller.dart';
import '../../helpers/mock_settings_service.dart';

class _RealHttpOverrides extends HttpOverrides {}

Future<HttpServer> _bindUnhealthyListener(int port) async {
  final server = await HttpServer.bind('0.0.0.0', port);
  server.listen((request) async {
    await request.drain<void>();
    request.response.statusCode = HttpStatus.serviceUnavailable;
    await request.response.close();
  });
  return server;
}

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
  Widget build(BuildContext context) => const _NativeView();

  @override
  T controllerFromPlatform<T>(PlatformInAppWebViewController controller) =>
      InAppWebViewController.fromPlatform(platform: controller) as T;

  @override
  void dispose() {
    onDispose?.call();
  }

  VoidCallback? onDispose;
}

class _NativeView extends StatefulWidget {
  const _NativeView();

  @override
  State<_NativeView> createState() => _NativeViewState();
}

class _NativeViewState extends State<_NativeView> {
  _TimerController? controller;

  @override
  Widget build(BuildContext context) => const SizedBox.expand();

  @override
  void dispose() {
    controller?.dispose();
    super.dispose();
  }
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
  bool disposed = false;

  @override
  void dispose({bool isKeepAlive = false}) {
    if (!isKeepAlive) disposed = true;
  }

  Iterable<String> callsTo(String method) =>
      calls.where((call) => call == method);
  Future<void> Function()? onLoad;
  Future<void> Function()? onPause;
  Future<void> Function()? onResume;
  Future<void> Function()? onPauseTimers;
  Future<void> Function()? onResumeTimers;

  @override
  Future<void> pause() async {
    calls.add('pause');
    await onPause?.call();
  }

  @override
  Future<void> resume() async {
    calls.add('resume');
    await onResume?.call();
  }

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
  }) async {
    if (disposed) throw StateError('load on removed native view');
    calls.add('load:${urlRequest.url}');
    await onLoad?.call();
  }
}

void _expectSkinReload(_TimerController controller, {int port = 24800}) {
  final loads = controller.calls.where((call) => call.startsWith('load:'));
  expect(loads, hasLength(1));
  _expectSkinUri(Uri.parse(loads.single.substring('load:'.length)), port: port);
}

void _expectSkinUri(Uri uri, {int port = 24800}) {
  expect(uri.scheme, 'http');
  expect(uri.host, 'localhost');
  expect(uri.port, port);
  expect(uri.path, '/');
  expect(uri.queryParameters.keys, ['_']);
  expect(int.tryParse(uri.queryParameters['_']!), isNotNull);
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
  Future<bool> Function()? onResumeListeners,
  Future<bool> Function()? onRetryListeners,
  Future<SkinSwitchOutcome> Function(String)? onSwitchSkin,
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
    onResumeListeners: onResumeListeners,
    onRetryListeners: onRetryListeners,
    onSwitchSkin: onSwitchSkin,
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

Future<_TimerController> _pumpTimerView(
  WidgetTester tester, {
  Set<PlatformInAppWebViewControllerMethod> unsupported = const {},
}) async {
  await _pumpSkin(
    tester,
    checkCompatibility: () async => const CompatibilityResult.compatible(),
    unsupported: unsupported,
  );
  return _createTimerView(tester);
}

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

Object _bridgeError(String failure) => switch (failure) {
  'unimplemented' => UnimplementedError('bridge unavailable'),
  'missing plugin' => MissingPluginException('bridge unavailable'),
  'platform error' => PlatformException(code: 'bridge-failed'),
  _ => throw ArgumentError.value(failure),
};

void _expectBridgeError(List<LogRecord> records, String failure) {
  final errors = records.where((record) => record.error != null);
  expect(errors, hasLength(1));
  expect(
    errors.single.level,
    failure == 'unimplemented' ? Level.WARNING : Level.SEVERE,
  );
  expect(
    errors.single.message,
    failure == 'unimplemented' ? 'Unimplemented: ' : 'Unexpected: ',
  );
  expect(errors.single.error.runtimeType, _bridgeError(failure).runtimeType);
}

void _expectBalance(List<LogRecord> records, int count, [String? where]) {
  expect(
    records.where(
      (record) => where == null
          ? record.message.startsWith('Balanced')
          : record.message == 'Balanced WebView timer pause in $where',
    ),
    hasLength(count),
  );
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

  testWidgets(
    'listener readiness gates initial skin creation and resume reload',
    (tester) async {
      final ready = Completer<bool>();
      final resumeReady = Completer<bool>();
      var calls = 0;
      var waitForResume = false;
      await _pumpSkin(
        tester,
        onResumeListeners: () {
          calls++;
          if (!ready.isCompleted) return ready.future;
          if (waitForResume) return resumeReady.future;
          return Future.value(false);
        },
      );
      expect(find.byType(InAppWebView), findsNothing);

      ready.complete(false);
      await tester.pump();
      expect(find.byType(InAppWebView), findsOneWidget);
      expect(calls, 1);
      _expectSkinUri(_params(tester).initialUrlRequest!.url!);

      final controller = _TimerController();
      _params(tester).onWebViewCreated!(
        InAppWebViewController.fromPlatform(platform: controller),
      );
      waitForResume = true;
      _lifecycle(tester, AppLifecycleState.resumed);
      await tester.pump();
      expect(
        controller.calls.where((call) => call.startsWith('load:')),
        isEmpty,
      );
      expect(calls, 2);
      resumeReady.complete(true);
      await tester.pump();
      _expectSkinReload(controller);
      await tester.pumpWidget(const SizedBox.shrink());
    },
    variant: mobile,
  );

  testWidgets(
    'host adopts replacement port after retrying a partial listener recovery',
    (tester) async {
      const entryPort = 3024;
      const bound = Duration(seconds: 15);
      Future<T?> network<T>(Future<T> Function() action) => tester.runAsync(
        () => HttpOverrides.runWithHttpOverrides(
          action,
          _RealHttpOverrides(),
        ).timeout(bound),
      );
      final previousResolver = WebUIService.resolveWifiIP;
      WebUIService.resolveWifiIP = () async => 'localhost';
      addTearDown(() => WebUIService.resolveWifiIP = previousResolver);
      final webUI = WebUIService(listLocalAddresses: () async => const []);
      final api = ApiListener(
        handler: (_) => shelf.Response.ok(
          '{}',
          headers: {'content-type': 'application/json'},
        ),
        port: 0,
      );
      final recovery = ListenerRecoveryCoordinator(
        apiListener: api,
        webUIService: webUI,
        maxAttempts: 2,
        retryDelay: Duration.zero,
      );
      Directory? directory;
      HttpServer? skinSquatter;
      HttpServer? entrySquatter;
      Future<bool>? pendingRetry;
      try {
        await network(() async {
          final skin = await Directory.systemTemp.createTemp('host_recovery');
          directory = skin;
          await File('${skin.path}/index.html').writeAsString('skin');
          await webUI.serveFolderAtPath(skin.path, port: entryPort);
          await api.start();
        });
        final oldPort = webUI.port;
        final generation = webUI.serveGeneration.value;
        await _pumpSkin(
          tester,
          checkCompatibility: () async =>
              const CompatibilityResult.compatible(),
          onRetryListeners: () {
            final pending = network(recovery.retry).then((result) => result!);
            pendingRetry = pending;
            return pending;
          },
          wrap: (skin) => SkinViewHost(
            serveGeneration: webUI.serveGeneration,
            port: () => webUI.port,
            builder: (port) => SkinView(
              settingsController: skin.settingsController,
              webViewLogService: skin.webViewLogService,
              deviceIp: skin.deviceIp,
              displayController: skin.displayController,
              port: port,
              onRetryListeners: skin.onRetryListeners,
              checkCompatibility: skin.checkCompatibility,
            ),
          ),
        );
        _expectSkinUri(_params(tester).initialUrlRequest!.url!, port: oldPort);
        final oldController = await _createTimerView(tester);
        final oldView = tester.element(find.byType(InAppWebView));
        final oldNative = tester.state<_NativeViewState>(
          find.byType(_NativeView),
        );
        oldNative.controller = oldController;

        await network(() async {
          await webUI.closeListenersForTesting();
          expect(webUI.isServing, isTrue);
          skinSquatter = await _bindUnhealthyListener(oldPort);
          entrySquatter = await _bindUnhealthyListener(entryPort);
          await expectLater(
            recovery.onResumed().timeout(bound),
            throwsA(isA<SocketException>()),
          );
        });
        final replacementPort = webUI.port;
        expect(replacementPort, isNot(oldPort));
        expect(recovery.failure.value, isNotNull);
        expect(webUI.serveGeneration.value, generation);
        await tester.pump();
        expect(tester.widget<SkinView>(find.byType(SkinView)).port, oldPort);
        expect(tester.element(find.byType(InAppWebView)), same(oldView));

        _params(tester).onReceivedError!(
          InAppWebViewController.fromPlatform(platform: oldController),
          WebResourceRequest(
            url: WebUri('http://localhost:$oldPort/'),
            isForMainFrame: true,
          ),
          WebResourceError(
            type: WebResourceErrorType.CANNOT_CONNECT_TO_HOST,
            description: 'listener recovery failed',
          ),
        );
        await tester.pump();
        expect(find.text('Retry').hitTestable(), findsOneWidget);
        expect(
          tester.state<_NativeViewState>(find.byType(_NativeView)),
          same(oldNative),
        );
        expect(oldController.disposed, isFalse);
        await network(() async {
          await entrySquatter!.close(force: true);
          entrySquatter = null;
        });
        await tester.tap(find.text('Retry'));
        expect(pendingRetry, isNotNull);
        await pendingRetry!;
        pendingRetry = null;
        await tester.pump();
        await network(() async {
          expect(recovery.failure.value, isNull);
          expect(await api.checkHealth(), isTrue);
          expect(await webUI.checkHealth(), isTrue);
        });
        await tester.pump();

        expect(webUI.port, replacementPort);
        expect(
          tester.widget<SkinView>(find.byType(SkinView)).port,
          replacementPort,
        );
        expect(webUI.serveGeneration.value, generation + 1);
        expect(tester.element(find.byType(InAppWebView)), isNot(same(oldView)));
        expect(oldNative.mounted, isFalse);
        expect(oldController.disposed, isTrue);
        await expectLater(
          oldController.loadUrl(
            urlRequest: URLRequest(url: WebUri('http://localhost:$oldPort/')),
          ),
          throwsStateError,
        );
        _expectSkinUri(
          _params(tester).initialUrlRequest!.url!,
          port: replacementPort,
        );
        final replacementController = await _createTimerView(tester);
        tester.state<_NativeViewState>(find.byType(_NativeView)).controller =
            replacementController;
        _params(tester).onReceivedError!(
          InAppWebViewController.fromPlatform(platform: replacementController),
          WebResourceRequest(
            url: WebUri('http://localhost:$replacementPort/'),
            isForMainFrame: true,
          ),
          WebResourceError(
            type: WebResourceErrorType.CANNOT_CONNECT_TO_HOST,
            description: 'retry navigation',
          ),
        );
        await tester.pump();
        await tester.tap(find.text('Retry'));
        expect(pendingRetry, isNotNull);
        await pendingRetry!;
        pendingRetry = null;
        await tester.pump();
        _expectSkinReload(replacementController, port: replacementPort);
        expect(webUI.serveGeneration.value, generation + 1);
        expect(tester.takeException(), isNull);
      } finally {
        await pendingRetry?.catchError((Object _) => false);
        await tester.pumpWidget(const SizedBox.shrink());
        recovery.dispose();
        await network(() async {
          await api.stop();
          await webUI.stopServing();
          await entrySquatter?.close(force: true);
          await skinSquatter?.close(force: true);
          if (directory != null) await directory!.delete(recursive: true);
        });
      }
    },
    variant: mobile,
  );

  testWidgets('pending listener resume cannot lose dispose timer balancing', (
    tester,
  ) async {
    final ready = Completer<bool>();
    var calls = 0;
    await _pumpSkin(
      tester,
      onResumeListeners: () {
        calls++;
        return calls == 1 ? Future.value(false) : ready.future;
      },
    );
    final controller = await _createTimerView(tester);
    final pause = Completer<void>();
    controller.onPauseTimers = () => pause.future;
    _lifecycle(tester, AppLifecycleState.paused);
    await tester.pump();
    _lifecycle(tester, AppLifecycleState.resumed);
    await tester.pump();
    expect(calls, 2);
    expect(controller.callsTo('resumeTimers'), isEmpty);
    await tester.pumpWidget(const SizedBox.shrink());
    pause.complete();
    await tester.pump();
    expect(controller.callsTo('resumeTimers'), hasLength(1));
    ready.complete(true);
    await tester.pump();
    expect(controller.callsTo('resume'), isEmpty);
    expect(controller.calls.where((call) => call.startsWith('load:')), isEmpty);
    expect(tester.takeException(), isNull);
  }, variant: mobile);

  testWidgets('listener bind failure offers a persistent retry', (
    tester,
  ) async {
    await _pumpSkin(
      tester,
      onResumeListeners: () async => throw StateError('bind failed'),
      onRetryListeners: () async => false,
    );
    await tester.pump();
    expect(
      find.textContaining('Failed to recover skin server'),
      findsOneWidget,
    );
    expect(find.text('Retry'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
  }, variant: mobile);

  testWidgets('retry failure then healthy retry reloads the current skin', (
    tester,
  ) async {
    var retries = 0;
    await _pumpSkin(
      tester,
      onRetryListeners: () async {
        retries++;
        if (retries == 1) throw StateError('still unavailable');
        return false;
      },
    );
    final controller = _TimerController();
    _params(tester).onWebViewCreated!(
      InAppWebViewController.fromPlatform(platform: controller),
    );
    final nativeView =
        tester.widget<InAppWebView>(find.byType(InAppWebView)).platform
            as _WebView;
    nativeView.onDispose = () => controller.disposed = true;
    _params(tester).onReceivedError!(
      InAppWebViewController.fromPlatform(platform: controller),
      WebResourceRequest(url: url, isForMainFrame: true),
      WebResourceError(
        type: WebResourceErrorType.CANNOT_CONNECT_TO_HOST,
        description: 'connection refused',
      ),
    );
    await tester.pump();
    expect(find.byType(InAppWebView), findsOneWidget);
    expect(controller.disposed, isFalse);
    expect(find.text('Retry').hitTestable(), findsOneWidget);
    await tester.tap(find.text('Retry'));
    await tester.pump();
    expect(retries, 1);
    expect(
      find.textContaining('Failed to recover skin server'),
      findsOneWidget,
    );
    expect(find.text('Retry').hitTestable(), findsOneWidget);
    await tester.tap(find.text('Retry'));
    await tester.pump();
    expect(retries, 2);
    _expectSkinReload(controller);
    await tester.pumpWidget(const SizedBox.shrink());
  }, variant: mobile);

  for (final outcome in [
    SkinSwitchOutcome.unchanged,
    SkinSwitchOutcome.unknownSkin,
    SkinSwitchOutcome.busy,
  ]) {
    testWidgets('surviving view callbacks remain live after ${outcome.name}', (
      tester,
    ) async {
      var switches = 0;
      await _pumpSkin(
        tester,
        onSwitchSkin: (_) async {
          switches++;
          return outcome;
        },
      );
      final params = _params(tester);
      final controller = InAppWebViewController.fromPlatform(
        platform: _TimerController(),
      );
      params.onWebViewCreated!(controller);
      params.onLoadStart!(controller, url);
      final script = params.initialUserScripts!.first.source;
      final nonce = RegExp(r'value: "([^"]+)"').firstMatch(script)!.group(1)!;
      final switchUrl = WebUri(
        'http://localhost:24800/__decent/switch-skin?id=other&nonce=$nonce',
      );
      await params.shouldOverrideUrlLoading!(
        controller,
        NavigationAction(
          request: URLRequest(url: switchUrl),
          isForMainFrame: true,
        ),
      );
      await tester.pump();
      expect(switches, 1);
      await params.shouldOverrideUrlLoading!(
        controller,
        NavigationAction(
          request: URLRequest(url: switchUrl),
          isForMainFrame: true,
        ),
      );
      await tester.pump();
      expect(switches, 2);
      expect(
        await params.shouldOverrideUrlLoading!(
          controller,
          NavigationAction(request: URLRequest(url: url), isForMainFrame: true),
        ),
        NavigationActionPolicy.ALLOW,
      );
      params.onReceivedError!(
        controller,
        WebResourceRequest(url: url, isForMainFrame: true),
        WebResourceError(
          type: WebResourceErrorType.CANNOT_CONNECT_TO_HOST,
          description: 'live callback',
        ),
      );
      await tester.pump();
      expect(find.textContaining('live callback'), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
    }, variant: mobile);
  }

  testWidgets(
    'retry navigation failure remains actionable without retry storms',
    (tester) async {
      var retries = 0;
      await _pumpSkin(
        tester,
        onRetryListeners: () async {
          retries++;
          return true;
        },
      );
      final controller = await _createTimerView(tester);
      final native = InAppWebViewController.fromPlatform(platform: controller);
      _params(tester).onReceivedError!(
        native,
        WebResourceRequest(url: url, isForMainFrame: true),
        WebResourceError(
          type: WebResourceErrorType.CANNOT_CONNECT_TO_HOST,
          description: 'offline',
        ),
      );
      await tester.pump();
      controller.onLoad = () async => throw StateError('navigation failed');
      await tester.tap(find.text('Retry'));
      await tester.pump();
      expect(tester.takeException(), isNull);
      expect(retries, 1);
      expect(find.textContaining('Failed to reload skin'), findsOneWidget);
      expect(find.text('Retry').hitTestable(), findsOneWidget);
      controller.onLoad = null;
      await tester.tap(find.text('Retry'));
      await tester.pump();
      expect(retries, 2);
      expect(find.text('Retry'), findsNothing);
      await tester.pumpWidget(const SizedBox.shrink());
    },
    variant: mobile,
  );

  testWidgets('actual recreation rejects retired native callbacks', (
    tester,
  ) async {
    final previous = simulatedWebViewDevice.value;
    addTearDown(() => simulatedWebViewDevice.value = previous);
    await _pumpSkin(tester);
    final old = _params(tester);
    final controller = InAppWebViewController.fromPlatform(
      platform: _TimerController(),
    );
    old.onWebViewCreated!(controller);
    simulatedWebViewDevice.value = SimulatedWebViewDevice.teclastP80X;
    await tester.pump();
    old.onReceivedError!(
      controller,
      WebResourceRequest(url: url, isForMainFrame: true),
      WebResourceError(
        type: WebResourceErrorType.CANNOT_CONNECT_TO_HOST,
        description: 'retired callback',
      ),
    );
    expect(
      await old.shouldOverrideUrlLoading!(
        controller,
        NavigationAction(request: URLRequest(url: url), isForMainFrame: true),
      ),
      NavigationActionPolicy.CANCEL,
    );
    await tester.pump();
    expect(find.textContaining('retired callback'), findsNothing);
    expect(find.byType(InAppWebView), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
  }, variant: mobile);

  testWidgets('stale listener readiness is ignored after recreation', (
    tester,
  ) async {
    final previous = simulatedWebViewDevice.value;
    addTearDown(() => simulatedWebViewDevice.value = previous);
    final firstReset = Completer<bool>();
    final secondReset = Completer<bool>();
    var calls = 0;
    await _pumpSkin(
      tester,
      onResumeListeners: () {
        calls++;
        return switch (calls) {
          1 => Future.value(false),
          2 => firstReset.future,
          _ => secondReset.future,
        };
      },
    );
    expect(find.byType(InAppWebView), findsOneWidget);

    simulatedWebViewDevice.value = SimulatedWebViewDevice.teclastP80X;
    await tester.pump();
    expect(find.byType(InAppWebView), findsNothing);
    simulatedWebViewDevice.value = SimulatedWebViewDevice.teclastP85Pro;
    await tester.pump();

    firstReset.complete(false);
    await tester.pump();
    expect(find.byType(InAppWebView), findsNothing);
    secondReset.complete(false);
    await tester.pump();
    expect(calls, 3);
    expect(find.byType(InAppWebView), findsOneWidget);
    _expectSkinUri(_params(tester).initialUrlRequest!.url!);
    await tester.pumpWidget(const SizedBox.shrink());
  }, variant: mobile);

  testWidgets('disposed listener readiness does not recreate the skin', (
    tester,
  ) async {
    final ready = Completer<bool>();
    await _pumpSkin(tester, onResumeListeners: () => ready.future);
    expect(find.byType(InAppWebView), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
    ready.complete(false);
    await tester.pump();
    expect(find.byType(InAppWebView), findsNothing);
    expect(tester.takeException(), isNull);
  }, variant: mobile);

  for (final operation in ['pause', 'resume']) {
    for (final failure in [
      'unimplemented',
      'missing plugin',
      'platform error',
    ]) {
      testWidgets('WebView $operation async $failure is caught', (
        tester,
      ) async {
        final records = _recordSkinLogs();
        final controller = await _pumpTimerView(tester);
        final completion = Completer<void>();
        if (operation == 'pause') {
          controller.onPause = () => completion.future;
        } else {
          controller.onResume = () => completion.future;
        }
        _lifecycle(
          tester,
          operation == 'pause'
              ? AppLifecycleState.paused
              : AppLifecycleState.resumed,
        );
        await tester.pump();
        expect(controller.calls, contains(operation));
        completion.completeError(_bridgeError(failure));
        await tester.pump();
        expect(tester.takeException(), isNull);
        _expectBridgeError(records, failure);
        await tester.pumpWidget(const SizedBox.shrink());
      }, variant: mobile);
    }
  }

  for (final exit in ['resume', 'dispose']) {
    for (final failure in ['unsupported', 'missing plugin', 'platform error']) {
      testWidgets('timer pause $failure followed by $exit is balanced', (
        tester,
      ) async {
        final records = _recordSkinLogs();
        final controller = await _pumpTimerView(
          tester,
          unsupported: failure == 'unsupported' ? {.pauseTimers} : {},
        );
        final pause = Completer<void>();
        controller.onPauseTimers = () => pause.future;
        _lifecycle(tester, AppLifecycleState.paused);
        await tester.pump();
        expect(
          controller.callsTo('pauseTimers').length,
          failure == 'unsupported' ? 0 : 1,
        );
        if (failure != 'unsupported') {
          pause.completeError(_bridgeError(failure));
          await tester.pump();
          expect(tester.takeException(), isNull);
          _expectBridgeError(records, failure);
        }
        if (exit == 'resume') {
          _lifecycle(tester, AppLifecycleState.resumed);
          await tester.pump();
        }
        await tester.pumpWidget(const SizedBox.shrink());
        _expectBalance(records, 0);
        expect(
          controller.callsTo('resumeTimers').length,
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
      final controller = await _pumpTimerView(tester);
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
      expect(controller.callsTo('resumeTimers').length, 1);
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
        final controller = await _pumpTimerView(
          tester,
          unsupported: unsupported,
        );
        _lifecycle(tester, AppLifecycleState.paused);
        await tester.pump();
        if (failure == 'unsupported') {
          unsupported.add(.resumeTimers);
        } else {
          controller.onResumeTimers = () async {
            await Future<void>.value();
            throw _bridgeError(failure);
          };
        }
        _lifecycle(tester, AppLifecycleState.resumed);
        await tester.pump();
        expect(tester.takeException(), isNull);
        _expectBalance(records, 0);
        if (failure != 'unsupported') _expectBridgeError(records, failure);
        expect(
          records.where((record) => record.level == Level.SEVERE),
          hasLength(failure == 'unsupported' ? 0 : 1),
        );
        if (recovery == 'dispose') {
          unsupported.clear();
          controller.onResumeTimers = null;
        }
        await tester.pumpWidget(const SizedBox.shrink());
        _expectBalance(records, recovery == 'dispose' ? 1 : 0);
        final afterDispose = controller.callsTo('resumeTimers').length;
        await _pumpTimerView(tester);
        await tester.pumpWidget(const SizedBox.shrink());
        expect(controller.callsTo('resumeTimers'), hasLength(afterDispose));
        _expectBalance(records, 1, recovery);
      }, variant: mobile);
    }
  }

  testWidgets('a queued pause is discarded after the lifecycle resumes', (
    tester,
  ) async {
    final controller = await _pumpTimerView(tester);
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
    final old = await _pumpTimerView(tester);
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
    _expectBalance(records, 1, 'dispose');
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
    expect(replacement.callsTo('resumeTimers'), hasLength(2));
    _expectBalance(records, 1, 'dispose');
  }, variant: mobile);

  testWidgets('renderer recovery balances timers and creates a fresh view', (
    tester,
  ) async {
    final old = await _pumpTimerView(tester);
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
    final controller = await _pumpTimerView(tester);
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
    final old = await _pumpTimerView(tester);
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
    expect(replacement.callsTo('resumeTimers'), hasLength(2));
    _expectBalance(records, 1, 'dispose');
  }, variant: mobile);

  testWidgets('stale pause finishes before replacement timer work', (
    tester,
  ) async {
    final previous = simulatedWebViewDevice.value;
    addTearDown(() => simulatedWebViewDevice.value = previous);
    final old = await _pumpTimerView(tester);
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
    expect(replacement.callsTo('resumeTimers'), hasLength(2));
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
