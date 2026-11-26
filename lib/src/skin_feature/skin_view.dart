import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:ui' show AppExitResponse, AppExitType;

import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../notifications/notification_actions.dart';
import '../notifications/notification_center.dart';
import '../notifications/notification_overlay.dart';

import 'package:flutter/services.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:logging/logging.dart';
import 'package:reaprime/src/controllers/display_controller.dart';
import 'package:reaprime/src/home_feature/widgets/quick_settings_widget.dart';
import 'package:reaprime/src/launcher/launcher_view.dart';
import 'package:reaprime/src/services/telemetry/boot_timing.dart';
import 'package:reaprime/src/services/webview_compatibility_checker.dart';
import 'package:reaprime/src/services/webview_log_service.dart';
import 'package:reaprime/src/settings/settings_controller.dart';
import 'package:reaprime/src/skin_feature/simulated_webview_device.dart';
import 'package:reaprime/src/skin_feature/skin_camera_permission.dart';
import 'package:reaprime/src/skin_feature/skin_camera_platform.dart';
import 'package:reaprime/src/skin_feature/skin_camera_webview_access.dart';
import 'package:reaprime/src/skin_feature/skin_exit_instructions.dart';
import 'package:reaprime/src/skin_feature/skin_switch_coordinator.dart';
import 'package:reaprime/src/skin_feature/skin_user_scripts.dart';
import 'package:reaprime/src/skin_feature/skin_webview_composition.dart';
import 'package:reaprime/src/skin_feature/skin_webview_diagnostics.dart';
import 'package:reaprime/src/skin_feature/skin_webview_startup.dart';
import 'package:reaprime/src/webui_support/webui_service.dart';
import 'package:url_launcher/url_launcher.dart';

export 'package:reaprime/src/skin_feature/skin_exit_instructions.dart';

enum SkinNavDecision {
  exitDashboard,
  exitApp,
  switchSkin,
  allow,
  openExternal,
  block,
}

SkinNavDecision classifySkinNavigation(Uri? url, {int skinPort = 3000}) {
  if (url == null) return SkinNavDecision.block;
  if (url.host == 'localhost' && url.path.startsWith('/__decent/')) {
    if (url.path == skinSwitchPath &&
        url.scheme == 'http' &&
        url.port == skinPort &&
        skinPort != 3000 &&
        url.userInfo.isEmpty &&
        (url.queryParameters['id'] ?? '').isNotEmpty) {
      return SkinNavDecision.switchSkin;
    }
    if (url.path == skinExitAppPath &&
        url.scheme == 'http' &&
        url.port == skinPort &&
        url.userInfo.isEmpty &&
        !url.hasFragment &&
        url.queryParametersAll.length == 1 &&
        url.queryParametersAll['nonce']?.length == 1 &&
        url.queryParameters['nonce']!.isNotEmpty) {
      return SkinNavDecision.exitApp;
    }
    return url.toString() == skinExitDashboardUrlForPort(skinPort)
        ? SkinNavDecision.exitDashboard
        : SkinNavDecision.block;
  }
  if (url.scheme == 'http' &&
      url.host == 'localhost' &&
      (url.port == skinPort ||
          url.port == 3000 ||
          (url.port == 8080 && url.path.startsWith('/api/v1/plugins/')))) {
    return SkinNavDecision.allow;
  }
  if (url.scheme == 'https' || url.scheme == 'http') {
    return SkinNavDecision.openExternal;
  }
  return SkinNavDecision.block;
}

bool shouldShowSkinLoadError(bool? isForMainFrame) => isForMainFrame != false;

/// Trust for the switch hook. The nonce is injected into the main frame only
/// (`buildSkinUserScripts`), so a cross-origin subframe that navigates the top
/// frame to the switch URL cannot supply it, and a retired generation's URL
/// carries the wrong one.
bool isTrustedSkinSwitchRequest({
  required Uri? target,
  required bool isForMainFrame,
  required Uri? topLevelUri,
  required int skinPort,
  required String expectedNonce,
}) {
  return expectedNonce.isNotEmpty &&
      (target?.queryParameters['nonce'] ?? '') == expectedNonce &&
      isTrustedSkinPageRequest(
        isForMainFrame: isForMainFrame,
        topLevelUri: topLevelUri,
        skinPort: skinPort,
      );
}

bool isTrustedSkinPageRequest({
  required bool isForMainFrame,
  required Uri? topLevelUri,
  required int skinPort,
}) {
  return isForMainFrame &&
      topLevelUri != null &&
      topLevelUri.scheme == 'http' &&
      topLevelUri.host == 'localhost' &&
      topLevelUri.port == skinPort &&
      topLevelUri.userInfo.isEmpty;
}

class SkinViewHost extends StatefulWidget {
  const SkinViewHost({
    super.key,
    required this.serveGeneration,
    required this.port,
    required this.builder,
    this.failure,
    this.onFailureShown,
  });

  final ValueListenable<int> serveGeneration;
  final int Function() port;
  final Widget Function(int port) builder;
  final ValueListenable<String?>? failure;
  final VoidCallback? onFailureShown;

  @override
  State<SkinViewHost> createState() => _SkinViewHostState();
}

class _SkinViewHostState extends State<SkinViewHost> {
  @override
  void initState() {
    super.initState();
    widget.failure?.addListener(_reportFailure);
    if (widget.failure?.value != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _reportFailure());
    }
  }

  @override
  void dispose() {
    widget.failure?.removeListener(_reportFailure);
    super.dispose();
  }

  void _reportFailure() {
    final message = widget.failure?.value;
    if (message == null || !mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message), duration: const Duration(seconds: 5)),
    );
    widget.onFailureShown?.call();
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<int>(
      valueListenable: widget.serveGeneration,
      builder: (context, generation, _) {
        final port = widget.port();
        return KeyedSubtree(
          key: ValueKey('skin-$generation-$port'),
          child: widget.builder(port),
        );
      },
    );
  }
}

class SkinExitCoordinator {
  bool _inProgress = false;

  bool get inProgress => _inProgress;

  bool tryStart({
    required Uri? target,
    required bool isForMainFrame,
    required Uri? topLevelUri,
    int skinPort = 3000,
  }) {
    if (_inProgress ||
        target?.toString() != skinExitDashboardUrlForPort(skinPort) ||
        !isTrustedSkinPageRequest(
          isForMainFrame: isForMainFrame,
          topLevelUri: topLevelUri,
          skinPort: skinPort,
        )) {
      return false;
    }
    _inProgress = true;
    return true;
  }
}

const _appLifecycleChannel = MethodChannel('app/lifecycle');

Future<bool> exitAppFromSkin() async {
  if (Platform.isAndroid) {
    return await _appLifecycleChannel.invokeMethod<bool>('moveTaskToBack') ??
        false;
  }
  if (Platform.isMacOS || Platform.isWindows || Platform.isLinux) {
    final response = await ServicesBinding.instance.exitApplication(
      AppExitType.cancelable,
    );
    return response == AppExitResponse.exit;
  }
  return false;
}

String _generateSwitchNonce() {
  final random = Random.secure();
  return base64Url.encode(List<int>.generate(24, (_) => random.nextInt(256)));
}

class SkinView extends StatefulWidget {
  const SkinView({
    super.key,
    required this.settingsController,
    required this.webViewLogService,
    required this.deviceIp,
    required this.displayController,
    this.webView,
    required this.port,
    this.cameraTarget,
    this.onResumeListeners,
    this.onRetryListeners,
    this.onSwitchSkin,
    this.notificationCenter,
    this.notificationActions,
    this.checkCompatibility = WebViewCompatibilityChecker.checkCompatibility,
  });

  final SettingsController settingsController;
  final WebViewLogService webViewLogService;
  final String deviceIp;
  final DisplayController displayController;
  @visibleForTesting
  final Widget? webView;
  final int port;
  final SkinCameraTarget? Function()? cameraTarget;
  final Future<bool> Function()? onResumeListeners;
  final Future<bool> Function()? onRetryListeners;
  final Future<SkinSwitchOutcome> Function(String skinId)? onSwitchSkin;
  final NotificationCenter? notificationCenter;
  final NotificationActions? notificationActions;
  final Future<CompatibilityResult> Function() checkCompatibility;

  static const routeName = '/skin';

  static Future<T?> open<T>(NavigatorState navigator) {
    navigator.pushNamedAndRemoveUntil(LauncherView.routeName, (_) => false);
    return navigator.pushNamed<T>(routeName);
  }

  @override
  State<SkinView> createState() => _SkinViewState();
}

class _SkinViewState extends State<SkinView> with WidgetsBindingObserver {
  final _log = Logger('SkinView');
  bool _isLoading = true;
  bool _isCheckingCompatibility = true;
  String? _errorMessage;
  CompatibilityResult? _compatibilityResult;
  bool _rendererCrashed = false;
  bool _listenersReady = false;

  // ponytail: one embedded skin route exists at a time, so a process-wide
  // count is enough to tell a generation replacement from leaving the skin.
  static int _activeViews = 0;

  static bool _globalTimersPaused = false;
  // Native timers are process-global: an unresolved call must finish before
  // any generation advances; abandoning it could apply a late global side effect.
  static Future<void>? _timerOperations;
  static Object? _timerViewAttempt;

  Object _timerLifecycle = Object();
  int _pendingTimerPauses = 0;

  InAppWebViewController? _webViewController;
  Object _webViewAttempt = Object();
  Object? _controllerAttempt;
  bool _retryInProgress = false;
  final String _switchNonce = _generateSwitchNonce();
  final _skinExitCoordinator = SkinExitCoordinator();
  bool _appExitInProgress = false;
  Uri? _mainFrameUri;
  Object? _resumeAttempt;
  late final _camera = SkinCameraWebViewAccess(
    context: () => mounted ? context : null,
    currentTarget: () {
      final target = widget.cameraTarget?.call();
      return target?.port == widget.port ? target : null;
    },
  );

  bool _didShowExit = false;

  String get _skinUrl =>
      'http://localhost:${widget.port}/?_=${DateTime.now().millisecondsSinceEpoch}';

  @override
  void initState() {
    super.initState();
    _activeViews++;
    WidgetsBinding.instance.addObserver(this);
    simulatedWebViewDevice.addListener(_resetWebView);
    if (Platform.isAndroid || Platform.isIOS) {
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    }
    _checkCompatibilityAndInit();
  }

  @override
  void dispose() {
    _log.fine("disposing");
    _resumeAttempt = Object();
    _webViewAttempt = Object();
    _activeViews--;
    final isLeavingSkin = _activeViews == 0;
    if (supportsSkinCamera) _camera.dispose();
    if (isLeavingSkin) {
      unawaited(widget.displayController.setBrightness(100));
    }
    _blankPageTimer?.cancel();
    _blankPageTimer = null;
    _balanceWebViewTimers('dispose');
    WidgetsBinding.instance.removeObserver(this);
    simulatedWebViewDevice.removeListener(_resetWebView);
    if (isLeavingSkin && Platform.isAndroid) {
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    }
    super.dispose();
  }

  Timer? _blankPageTimer;
  bool _didBlank = false;

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (defaultTargetPlatform != TargetPlatform.android &&
        defaultTargetPlatform != TargetPlatform.iOS) {
      return;
    }

    if (state == AppLifecycleState.paused) {
      _resumeAttempt = Object();
      if (_webViewController == null) return;
      _log.info('App backgrounded — pausing WebView and loading blank page');
      unawaited(_changeWebViewActivity(_webViewController!, pause: true));
      _timerLifecycle = Object();
      unawaited(
        _changeWebViewTimers(_webViewController!, 'pause', pause: true),
      );
      _didBlank = false;
      _blankPageTimer?.cancel();
      _blankPageTimer = Timer(Duration(minutes: 10), () {
        _webViewController?.loadUrl(
          urlRequest: URLRequest(url: WebUri('about:blank')),
        );
        _didBlank = true;
      });
    } else if (state == AppLifecycleState.resumed) {
      _blankPageTimer?.cancel();
      _blankPageTimer = null;
      final attempt = Object();
      _resumeAttempt = attempt;
      unawaited(_resumeAfterListeners(attempt));
    }
  }

  Future<void> _resumeAfterListeners(Object attempt) {
    final recover = widget.onResumeListeners;
    if (recover == null) {
      return _finishResume(attempt, recovered: false);
    }
    return _awaitResumeAfterListeners(attempt, recover);
  }

  Future<void> _awaitResumeAfterListeners(
    Object attempt,
    Future<bool> Function() recover,
  ) async {
    try {
      final recovered = await recover();
      if (!mounted || !identical(attempt, _resumeAttempt)) return;
      await _finishResume(attempt, recovered: recovered);
    } catch (error, stackTrace) {
      _log.warning(
        'Listener recovery failed while resuming skin',
        error,
        stackTrace,
      );
      if (!mounted || !identical(attempt, _resumeAttempt)) return;
      setState(() {
        _isLoading = false;
        _errorMessage = 'Failed to recover skin server: $error';
      });
    }
  }

  Future<void> _finishResume(Object attempt, {required bool recovered}) async {
    if (!mounted || !identical(attempt, _resumeAttempt)) return;
    final controller = _webViewController;
    if (controller == null) {
      if (!_listenersReady) {
        setState(() {
          _listenersReady = true;
          _isLoading = true;
          _errorMessage = null;
        });
      }
      return;
    }
    if (_errorMessage != null) {
      setState(() {
        _errorMessage = null;
        _isLoading = true;
      });
    }
    _log.info('App foregrounded — resuming WebView and reloading skin');
    _timerLifecycle = Object();
    unawaited(_changeWebViewTimers(controller, 'resume'));
    unawaited(_changeWebViewActivity(controller));
    if (recovered || _didBlank) {
      _didBlank = false;
      try {
        await controller.loadUrl(urlRequest: URLRequest(url: WebUri(_skinUrl)));
      } catch (error, stackTrace) {
        _log.warning('Failed to reload skin', error, stackTrace);
        if (!mounted || !identical(attempt, _resumeAttempt)) return;
        setState(() {
          _isLoading = false;
          _errorMessage = 'Failed to reload skin: $error';
        });
      }
    }
  }

  Future<void> _checkCompatibilityAndInit() async {
    if (widget.webView != null) {
      _isCheckingCompatibility = false;
      await _prepareListeners(_webViewAttempt);
      return;
    }
    _log.info('Checking WebView compatibility...');

    if (!Platform.isWindows) {
      try {
        await InAppWebViewController.clearAllCache();
        _log.fine('WebView cache cleared');
      } catch (e, st) {
        _log.warning('clearAllCache failed, continuing', e, st);
      }
    }

    final result = await widget.checkCompatibility();
    if (!mounted) return;

    setState(() {
      _compatibilityResult = result;
      _isCheckingCompatibility = false;
    });

    if (result.isCompatible) {
      _log.info('WebView is compatible');
      await _prepareListeners(_webViewAttempt);
    } else {
      _log.warning('WebView is not compatible: ${result.reason}');
    }
  }

  Future<void> _prepareListeners(Object attempt) {
    final recover = widget.onResumeListeners;
    if (recover == null) {
      _markListenersReady(attempt);
      return Future<void>.value();
    }
    return _awaitListenerPreparation(attempt, recover);
  }

  Future<void> _awaitListenerPreparation(
    Object attempt,
    Future<bool> Function() recover,
  ) async {
    try {
      await recover();
    } catch (error, stackTrace) {
      _log.warning(
        'Listener recovery failed while preparing skin',
        error,
        stackTrace,
      );
      if (!mounted || !identical(attempt, _webViewAttempt)) return;
      setState(() {
        _isLoading = false;
        _errorMessage = 'Failed to recover skin server: $error';
      });
      return;
    }
    _markListenersReady(attempt);
  }

  void _markListenersReady(Object attempt) {
    if (!mounted || !identical(attempt, _webViewAttempt)) return;
    setState(() {
      _listenersReady = true;
      _isLoading = true;
      _errorMessage = null;
    });
  }

  void _showExitInstructions() {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(skinExitInstructions(defaultTargetPlatform)),
        duration: const Duration(seconds: 10),
        behavior: SnackBarBehavior.floating,
        margin: const EdgeInsets.all(16),
        showCloseIcon: true,
        action: SnackBarAction(
          label: "Don't show again",
          onPressed: () {
            ScaffoldMessenger.of(context).hideCurrentSnackBar();
            unawaited(
              widget.settingsController.setShowSkinExitInstructions(false),
            );
          },
        ),
      ),
    );
  }

  Future<void> _requestSkinSwitch(String skinId) async {
    final handler = widget.onSwitchSkin;
    if (handler == null) {
      _log.warning('Skin switch to $skinId ignored: no handler wired');
      return;
    }
    _log.info('Skin requested switch to $skinId');
    _resumeAttempt = Object();
    final outcome = await handler(skinId);
    _log.info('Skin switch to $skinId: ${outcome.name}');
  }

  Future<void> _exitApp() async {
    _appExitInProgress = true;
    try {
      if (!await exitAppFromSkin()) {
        _log.info('Platform did not leave the app for skin exit request');
      }
    } catch (e, st) {
      _log.warning('Skin app exit failed', e, st);
    } finally {
      _appExitInProgress = false;
    }
  }

  void _exitToDashboard() {
    _resumeAttempt = Object();
    _webViewAttempt = Object();
    Navigator.of(context)
        .pushNamedAndRemoveUntil(LauncherView.routeName, (_) => false);
  }

  Future<void> _openNotificationCenter() async {
    final navigator = Navigator.of(context);
    final route = ModalRoute.of(context);
    final center = widget.notificationCenter!;
    final actions = widget.notificationActions!;
    _exitToDashboard();
    await route?.completed;
    if (navigator.mounted) {
      await showNotifications(navigator.context, center, actions);
    }
  }

  @override
  Widget build(BuildContext context) {
    final view = Scaffold(
      floatingActionButton:
          widget.notificationCenter != null &&
              widget.notificationActions != null
          ? NotificationBell(
              center: widget.notificationCenter!,
              actions: widget.notificationActions!,
              onOpenCenter: _openNotificationCenter,
            )
          : null,
      body: SafeArea(
        top: false,
        bottom: false,
        left: false,
        right: false,
        child: _buildBody(),
      ),
    );
    if (defaultTargetPlatform == TargetPlatform.iOS) return view;
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _exitToDashboard();
      },
      child: view,
    );
  }

  Widget _buildIncompatibilityMessage() {
    final result = _compatibilityResult!;

    IconData icon;
    Color iconColor;
    String title;
    String description;

    switch (result.issue) {
      case CompatibilityIssue.knownProblematicDevice:
        icon = Icons.tablet_android;
        iconColor = Colors.orange;
        title = 'WebView Not Supported';
        description =
            'Your device has known compatibility issues with the embedded web view.\n\n${result.reason}';
        break;
      case CompatibilityIssue.oldAndroidVersion:
        icon = Icons.phone_android;
        iconColor = Colors.orange;
        title = 'Android Version Too Old';
        description =
            'Your Android version does not support the required WebView features.\n\n${result.reason}';
        break;
      case CompatibilityIssue.webViewRenderingFailed:
        icon = Icons.warning;
        iconColor = Colors.red;
        title = 'WebView Test Failed';
        description =
            'The WebView compatibility test failed on your device.\n\n${result.reason}';
        break;
      case CompatibilityIssue.webViewNotAvailable:
        icon = Icons.error;
        iconColor = Colors.red;
        title = 'WebView Not Available';
        description =
            'Unable to initialize WebView on your device.\n\n${result.reason}';
        break;
      case CompatibilityIssue.webView2RuntimeMissing:
        icon = Icons.download;
        iconColor = Colors.orange;
        title = 'WebView2 Runtime Missing';
        description =
            'Microsoft Edge WebView2 Runtime is required to display the '
            'skin on Windows. Install it and restart the app.';
        break;
      default:
        icon = Icons.info;
        iconColor = Colors.blue;
        title = 'Compatibility Issue';
        description = result.reason;
    }

    return Center(
      child: Padding(
        padding: const EdgeInsets.all(8.0),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          spacing: 8,
          children: [
            Icon(icon, size: 48, color: iconColor),
            Text(
              title,
              style: Theme.of(context).textTheme.headlineSmall,
              textAlign: TextAlign.center,
            ),
            Text(
              description,
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodyMedium,
            ),
            const SizedBox(height: 8),
            const Divider(),
            Text(
              'You can use an external browser instead:',
              style: Theme.of(context).textTheme.bodyMedium
                  ?.copyWith(fontWeight: FontWeight.w500),
            ),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              spacing: 12,
              children: [
                ElevatedButton.icon(
                  onPressed: _openInExternalBrowser,
                  icon: const Icon(Icons.open_in_browser),
                  label: const Text('Open in Browser'),
                  style: ElevatedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 24,
                      vertical: 12,
                    ),
                  ),
                ),
                OutlinedButton.icon(
                  onPressed: _exitToDashboard,
                  icon: const Icon(Icons.dashboard),
                  label: const Text('Dashboard'),
                ),
                ElevatedButton.icon(
                  icon: const Icon(Icons.qr_code),
                  label: const Text('Show address'),
                  onPressed: () {
                    QuickSettingsWidget.showQRCodeDialog(
                      context,
                      widget.deviceIp,
                    );
                  },
                ),
                if (result.issue == CompatibilityIssue.webView2RuntimeMissing)
                  ElevatedButton.icon(
                    icon: const Icon(Icons.download),
                    label: const Text('Install WebView2'),
                    onPressed: () => launchUrl(
                      Uri.parse(
                        'https://go.microsoft.com/fwlink/p/?LinkId=2124703',
                      ),
                      mode: LaunchMode.externalApplication,
                    ),
                  ),
              ],
            ),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              spacing: 12,
              children: [
                TextButton(
                  onPressed: () async {
                    _log.info('Retrying compatibility check...');
                    setState(() {
                      _isCheckingCompatibility = true;
                      _compatibilityResult = null;
                    });
                    WebViewCompatibilityChecker.clearCache();
                    await _checkCompatibilityAndInit();
                  },
                  child: const Text('Retry Compatibility Check'),
                ),
                TextButton(
                  onPressed: () {
                    setState(() {
                      _compatibilityResult = null;
                    });
                    unawaited(_prepareListeners(_webViewAttempt));
                  },
                  child: const Text('Ignore and load anyway'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _launchExternal(Uri uri) async {
    try {
      if (await canLaunchUrl(uri)) {
        await launchUrl(uri, mode: LaunchMode.externalApplication);
      } else {
        _log.warning('Cannot launch external URL: $uri');
      }
    } catch (e, st) {
      _log.severe('Failed to launch external URL: $uri', e, st);
    }
  }

  Future<void> _openInExternalBrowser() async {
    final url = Uri.parse(
      'http://localhost:3000?_=${DateTime.now().millisecondsSinceEpoch}',
    );
    _log.info('Opening WebUI in external browser: $url');

    try {
      if (await canLaunchUrl(url) &&
          await launchUrl(url, mode: LaunchMode.externalApplication)) {
        if (mounted) _exitToDashboard();
      } else {
        _log.warning('Cannot launch URL: $url');
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(
                'Unable to open browser. Please open $url manually.',
              ),
              duration: const Duration(seconds: 5),
            ),
          );
        }
      }
    } catch (e, stackTrace) {
      _log.severe('Failed to open external browser', e, stackTrace);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error opening browser: $e'),
            duration: const Duration(seconds: 5),
          ),
        );
      }
    }
  }

  Widget _buildBody() {
    if (_isCheckingCompatibility) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          spacing: 16,
          children: [
            const CircularProgressIndicator(),
            Text(
              'Checking device compatibility...',
              style: Theme.of(context).textTheme.bodyLarge,
            ),
          ],
        ),
      );
    }

    if (_compatibilityResult != null && !_compatibilityResult!.isCompatible) {
      return _buildIncompatibilityMessage();
    }

    Widget? errorOverlay;
    if (_errorMessage != null) {
      errorOverlay = Column(
        children: [
          Expanded(
            child: SkinWebViewError(
              message: _errorMessage!,
              onOpenInBrowser: defaultTargetPlatform == TargetPlatform.windows
                  ? _openInExternalBrowser
                  : null,
              onDashboard: _exitToDashboard,
            ),
          ),
          if (widget.onRetryListeners != null)
            SafeArea(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: ElevatedButton(
                  onPressed: _retryInProgress
                      ? null
                      : () => unawaited(
                          _retryListeners(widget.onRetryListeners!),
                        ),
                  child: const Text('Retry'),
                ),
              ),
            ),
        ],
      );
    }

    if (!_listenersReady) {
      return errorOverlay ?? const Center(child: CircularProgressIndicator());
    }

    if (_rendererCrashed) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          spacing: 16,
          children: [
            const CircularProgressIndicator(),
            Text(
              'Reloading skin...',
              style: Theme.of(context).textTheme.bodyLarge,
            ),
          ],
        ),
      );
    }

    return Stack(
      children: [
        Positioned.fill(child: _buildWebViewStack()),
        if (errorOverlay != null)
          Positioned.fill(
            child: ColoredBox(
              color: Theme.of(context).scaffoldBackgroundColor,
              child: errorOverlay,
            ),
          ),
      ],
    );
  }

  Widget _buildWebViewStack() {
    return SkinWebViewComposition(
      settings: widget.settingsController,
      platform: defaultTargetPlatform,
      builder: (context, texture) =>
          ValueListenableBuilder<SimulatedWebViewDevice?>(
            valueListenable: simulatedWebViewDevice,
            builder: (context, simulatedDevice, _) {
              return SkinWebViewStartup(
                key: ValueKey(simulatedDevice?.id ?? 'native-webview'),
                platform: defaultTargetPlatform,
                isLoading: _isLoading,
                isCreated: _webViewController != null,
                skinId: widget.settingsController.defaultSkinId,
                port: widget.port,
                onOpenInBrowser: _openInExternalBrowser,
                onDashboard: _exitToDashboard,
                child: _buildWebView(simulatedDevice, texture),
              );
            },
          ),
    );
  }

  Widget _buildWebView(SimulatedWebViewDevice? simulatedDevice, bool texture) {
    if (widget.webView != null) return widget.webView!;
    final attempt = _webViewAttempt;
    bool isCurrentView() => mounted && identical(attempt, _webViewAttempt);
    return InAppWebView(
      key: ValueKey(simulatedDevice?.id ?? 'native-webview'),
      initialUrlRequest: URLRequest(url: WebUri(_skinUrl)),
      initialSettings: createSkinWebViewSettings(
        platform: defaultTargetPlatform,
        textureComposition: texture,
      ),
      initialUserScripts: buildSkinUserScripts(
        simulatedDevice,
        enableSimulatedWebViews:
            widget.settingsController.enableSimulatedWebViews,
        switchNonce: _switchNonce,
      ),
      onPermissionRequest: supportsSkinCamera
          ? _camera.onPermissionRequest
          : null,
      onPermissionRequestCanceled: Platform.isAndroid
          ? _camera.onPermissionRequestCanceled
          : null,
      onShowFileChooser: Platform.isAndroid ? _camera.onShowFileChooser : null,
      onWebViewCreated: (controller) {
        if (!isCurrentView()) return;
        if (supportsSkinCamera) _camera.invalidate();
        _log.info('InAppWebView created');
        _controllerAttempt = attempt;
        _timerViewAttempt = attempt;
        setState(() => _webViewController = controller);
        if (Platform.isAndroid) {
          unawaited(_logRenderingDiagnostics(controller, texture));
        }
        unawaited(_changeWebViewTimers(controller, 'onWebViewCreated'));
      },
      onLoadStart: (controller, url) {
        if (!isCurrentView()) return;
        if (supportsSkinCamera) _camera.invalidate();
        _log.info('Page started loading: $url');
        _mainFrameUri = url;
        BootTiming.mark('webview');
        BootTiming.complete();
        setState(() {
          _isLoading = true;
          _errorMessage = null;
        });
      },
      onLoadStop: (controller, url) async {
        if (!isCurrentView()) return;
        _log.info('Page finished loading: $url');
        setState(() {
          _isLoading = false;
        });

        if (mounted &&
            !_didShowExit &&
            widget.settingsController.showSkinExitInstructions) {
          _didShowExit = true;
          _showExitInstructions();
        }
      },
      onReceivedError: (controller, request, error) {
        if (request.url.host == 'localhost' &&
            request.url.port == widget.port &&
            request.url.path == skinExitAppPath) {
          return;
        }
        if (_skinExitCoordinator.inProgress &&
            request.url.toString() ==
                skinExitDashboardUrlForPort(widget.port)) {
          return;
        }
        _log.warning(
          'WebView error - Code: ${error.type}, Description: ${error.description}',
        );
        if (!shouldShowSkinLoadError(request.isForMainFrame)) return;
        if (!isCurrentView()) return;
        setState(() {
          _isLoading = false;
          _errorMessage = 'Failed to load skin: ${error.description}';
        });
      },
      onReceivedHttpError: (controller, request, errorResponse) {
        _log.warning('HTTP error - Status: ${errorResponse.statusCode}');
      },
      shouldOverrideUrlLoading: (controller, navigationAction) async {
        if (!isCurrentView()) return NavigationActionPolicy.CANCEL;
        final uri = navigationAction.request.url;
        switch (classifySkinNavigation(uri, skinPort: widget.port)) {
          case SkinNavDecision.exitDashboard:
            if (_skinExitCoordinator.tryStart(
              target: uri,
              isForMainFrame: navigationAction.isForMainFrame,
              topLevelUri: _mainFrameUri,
              skinPort: widget.port,
            )) {
              _log.info('Skin requested dashboard');
              if (mounted) _exitToDashboard();
            } else {
              _log.warning('Rejected skin dashboard request');
            }
            return NavigationActionPolicy.CANCEL;
          case SkinNavDecision.exitApp:
            if (!_appExitInProgress &&
                isTrustedSkinSwitchRequest(
                  target: uri,
                  isForMainFrame: navigationAction.isForMainFrame,
                  topLevelUri: _mainFrameUri,
                  skinPort: widget.port,
                  expectedNonce: _switchNonce,
                )) {
              _log.info('Skin requested app exit');
              unawaited(_exitApp());
            } else {
              _log.warning('Rejected skin app exit request');
            }
            return NavigationActionPolicy.CANCEL;
          case SkinNavDecision.switchSkin:
            if (isTrustedSkinSwitchRequest(
              target: uri,
              isForMainFrame: navigationAction.isForMainFrame,
              topLevelUri: _mainFrameUri,
              skinPort: widget.port,
              expectedNonce: _switchNonce,
            )) {
              unawaited(_requestSkinSwitch(uri!.queryParameters['id'] ?? ''));
            } else {
              _log.warning('Rejected skin switch request: $uri');
            }
            return NavigationActionPolicy.CANCEL;
          case SkinNavDecision.allow:
            _log.fine('Allowing navigation to: $uri');
            return NavigationActionPolicy.ALLOW;
          case SkinNavDecision.openExternal:
            _log.info('Opening external link in system browser: $uri');
            unawaited(_launchExternal(uri!));
            return NavigationActionPolicy.CANCEL;
          case SkinNavDecision.block:
            _log.info('Blocking navigation to: $uri');
            return NavigationActionPolicy.CANCEL;
        }
      },
      onConsoleMessage: (controller, consoleMessage) {
        final skinId = widget.settingsController.defaultSkinId;
        widget.webViewLogService.log(
          skinId,
          consoleMessage.messageLevel.toString(),
          consoleMessage.message,
        );
        _log.finest(
          'WebView Console [$skinId] [${consoleMessage.messageLevel}]: ${consoleMessage.message}',
        );
      },
      onWebContentProcessDidTerminate: Platform.isIOS || Platform.isMacOS
          ? (controller) => _camera.invalidate()
          : null,
      onRenderProcessGone: (controller, detail) {
        if (!isCurrentView()) return;
        if (supportsSkinCamera) _camera.invalidate();
        if (Platform.isAndroid) {
          widget.webViewLogService.log(
            widget.settingsController.defaultSkinId,
            'WARNING',
            jsonEncode({
              'event': 'rendererExit',
              'viewId': controller.getViewId().toString(),
              'requestedMode': skinCompositionName(texture),
              'didCrash': detail.didCrash,
              'rendererPriorityAtExit': detail.rendererPriorityAtExit
                  ?.toString(),
            }),
          );
        }
        _log.warning(
          'WebView renderer process gone — '
          'didCrash: ${detail.didCrash}, '
          'rendererPriorityAtExit: ${detail.rendererPriorityAtExit}',
        );
        _balanceWebViewTimers('renderer exit');
        _webViewController = null;
        setState(() {
          _rendererCrashed = true;
        });
        Future.delayed(const Duration(milliseconds: 500), () {
          if (isCurrentView()) _resetWebView();
        });
      },
    );
  }

  Future<void> _retryListeners(Future<bool> Function() retry) async {
    if (_retryInProgress) return;
    final attempt = _webViewAttempt;
    final resumeAttempt = Object();
    _resumeAttempt = resumeAttempt;
    setState(() => _retryInProgress = true);
    try {
      await retry();
      if (!mounted ||
          !identical(attempt, _webViewAttempt) ||
          !identical(resumeAttempt, _resumeAttempt)) {
        return;
      }
      setState(() {
        _listenersReady = true;
        _isLoading = true;
        _errorMessage = null;
      });
      await _finishResume(resumeAttempt, recovered: true);
    } catch (error) {
      if (!mounted ||
          !identical(attempt, _webViewAttempt) ||
          !identical(resumeAttempt, _resumeAttempt)) {
        return;
      }
      setState(() => _errorMessage = 'Failed to recover skin server: $error');
    } finally {
      if (mounted) setState(() => _retryInProgress = false);
    }
  }

  void _balanceWebViewTimers(String where) {
    final controller = _webViewController;
    if (controller != null &&
        (_globalTimersPaused || _pendingTimerPauses > 0)) {
      unawaited(_changeWebViewTimers(controller, where));
    }
  }

  void _resetWebView() {
    _balanceWebViewTimers('reset');
    final attempt = _webViewAttempt = Object();
    _resumeAttempt = Object();
    setState(() {
      _listenersReady = false;
      _webViewController = null;
      _isLoading = true;
      _errorMessage = null;
      _mainFrameUri = null;
      _rendererCrashed = false;
    });
    unawaited(_prepareListeners(attempt));
  }

  Future<void> _logRenderingDiagnostics(
    InAppWebViewController controller,
    bool texture,
  ) async {
    final skinId = widget.settingsController.defaultSkinId;
    final viewId = controller.getViewId().toString();
    final report = await readSkinRenderingDiagnostics(
      textureComposition: texture,
      readProvider: InAppWebViewController.getCurrentWebViewPackage,
      readSdk: () async =>
          (await DeviceInfoPlugin().androidInfo).version.sdkInt,
      readSettings: controller.getSettings,
    );
    if (!mounted || _webViewController != controller) return;
    final message = jsonEncode({
      'event': 'created',
      'viewId': viewId,
      ...report,
    });
    _log.info(message);
    widget.webViewLogService.log(skinId, 'INFO', message);
  }

  Future<void> _changeWebViewActivity(
    InAppWebViewController controller, {
    bool pause = false,
  }) async {
    try {
      if (pause) {
        if (InAppWebViewController.isMethodSupported(.pause)) {
          await controller.pause();
        }
      } else if (InAppWebViewController.isMethodSupported(.resume)) {
        await controller.resume();
      }
    } on UnimplementedError catch (e) {
      _log.warning("Unimplemented: ", e);
    } catch (e, st) {
      _log.severe("Unexpected: ", e, st);
    }
  }

  Future<void> _changeWebViewTimers(
    InAppWebViewController controller,
    String where, {
    bool pause = false,
  }) {
    final attempt = _controllerAttempt;
    final lifecycle = _timerLifecycle;
    bool isCurrentView() =>
        mounted &&
        identical(attempt, _webViewAttempt) &&
        _webViewController == controller &&
        identical(lifecycle, _timerLifecycle) &&
        identical(attempt, _timerViewAttempt);
    if (pause) _pendingTimerPauses++;
    Future<void> run() async {
      try {
        if (pause) {
          if (!isCurrentView()) return;
          if (InAppWebViewController.isMethodSupported(.pauseTimers)) {
            await controller.pauseTimers();
            _globalTimersPaused = true;
          }
        } else if (identical(attempt, _timerViewAttempt) &&
            InAppWebViewController.isMethodSupported(.resumeTimers)) {
          final wasPaused = _globalTimersPaused;
          await controller.resumeTimers();
          _globalTimersPaused = false;
          if (wasPaused && identical(attempt, _timerViewAttempt)) {
            _log.warning('Balanced WebView timer pause in $where');
          }
        }
      } on UnimplementedError catch (e) {
        _log.warning("Unimplemented: ", e);
      } catch (e, st) {
        _log.severe("Unexpected: ", e, st);
      } finally {
        if (pause) _pendingTimerPauses--;
      }
    }

    final operation = _timerOperations?.then((_) => run()) ?? run();
    _timerOperations = operation;
    unawaited(
      operation.then((_) {
        if (identical(_timerOperations, operation)) _timerOperations = null;
      }),
    );
    return operation;
  }
}
