import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:logging/logging.dart';
import 'package:reaprime/build_info.dart';
import 'package:reaprime/src/controllers/display_controller.dart';
import 'package:reaprime/src/home_feature/widgets/quick_settings_widget.dart';
import 'package:reaprime/src/launcher/launcher_view.dart';
import 'package:reaprime/src/services/telemetry/boot_timing.dart';
import 'package:reaprime/src/services/webview_compatibility_checker.dart';
import 'package:reaprime/src/services/webview_log_service.dart';
import 'package:reaprime/src/settings/settings_controller.dart';
import 'package:reaprime/src/skin_feature/simulated_webview_device.dart';
import 'package:reaprime/src/webui_support/webui_service.dart';
import 'package:url_launcher/url_launcher.dart';

enum SkinNavDecision { exitDashboard, allow, openExternal, block }

String skinExitInstructions(TargetPlatform platform) {
  const purpose = 'Dashboard contains app settings and skin selection.';
  final navigation = switch (platform) {
    TargetPlatform.android =>
      'Swipe inward from either screen edge to open it. With button '
          'navigation, reveal the navigation bar and tap Back.',
    TargetPlatform.iOS => 'Swipe right from the left screen edge to open it.',
    TargetPlatform.macOS =>
      'Press ⌘D or use View → Back to Dashboard to open it.',
    TargetPlatform.windows =>
      'Use the Dashboard button in the top-right corner to open it.',
    TargetPlatform.linux ||
    TargetPlatform.fuchsia => 'Use system back navigation to open it.',
  };
  return '$purpose $navigation';
}

SkinNavDecision classifySkinNavigation(Uri? url) {
  if (url == null) return SkinNavDecision.block;
  if (url.host == 'localhost' && url.path.startsWith('/__decent/')) {
    return url.toString() == skinExitDashboardUrl
        ? SkinNavDecision.exitDashboard
        : SkinNavDecision.block;
  }
  if (url.scheme == 'http' &&
      url.host == 'localhost' &&
      (url.port == 3000 ||
          (url.port == 8080 && url.path.startsWith('/api/v1/plugins/')))) {
    return SkinNavDecision.allow;
  }
  if (url.scheme == 'https' || url.scheme == 'http') {
    return SkinNavDecision.openExternal;
  }
  return SkinNavDecision.block;
}

bool shouldShowSkinLoadError(bool? isForMainFrame) => isForMainFrame != false;

class SkinExitCoordinator {
  bool _inProgress = false;

  bool get inProgress => _inProgress;

  bool tryStart({
    required Uri? target,
    required bool isForMainFrame,
    required Uri? topLevelUri,
  }) {
    if (_inProgress ||
        !isForMainFrame ||
        target?.toString() != skinExitDashboardUrl ||
        topLevelUri == null ||
        topLevelUri.scheme != 'http' ||
        topLevelUri.host != 'localhost' ||
        topLevelUri.port != 3000 ||
        topLevelUri.userInfo.isNotEmpty) {
      return false;
    }
    _inProgress = true;
    return true;
  }
}

class SkinView extends StatefulWidget {
  const SkinView({
    super.key,
    required this.settingsController,
    required this.webViewLogService,
    required this.deviceIp,
    required this.displayController,
    this.webView,
  });

  final SettingsController settingsController;
  final WebViewLogService webViewLogService;
  final String deviceIp;
  final DisplayController displayController;
  @visibleForTesting
  final Widget? webView;

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

  static bool _globalTimersPaused = false;

  InAppWebViewController? _webViewController;
  final _skinExitCoordinator = SkinExitCoordinator();
  Uri? _mainFrameUri;

  bool _didShowExit = false;

  String get _skinUrl =>
      'http://localhost:3000/?_=${DateTime.now().millisecondsSinceEpoch}';

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    if (Platform.isAndroid || Platform.isIOS) {
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    }
    _checkCompatibilityAndInit();
  }

  @override
  void dispose() {
    _log.fine("disposing");
    unawaited(widget.displayController.setBrightness(100));
    _blankPageTimer?.cancel();
    _blankPageTimer = null;
    final controller = _webViewController;
    if (_globalTimersPaused && controller != null) {
      unawaited(_resumeWebViewTimers(controller, 'dispose'));
    }
    WidgetsBinding.instance.removeObserver(this);
    if (Platform.isAndroid) {
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    }
    super.dispose();
  }

  Timer? _blankPageTimer;
  bool _didBlank = false;

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (!(Platform.isAndroid || Platform.isIOS)) {
      return;
    }

    if (state == AppLifecycleState.paused) {
      if (_webViewController == null) return;
      _log.info('App backgrounded — pausing WebView and loading blank page');
      try {
        if (InAppWebViewController.isMethodSupported(.pause)) {
          _webViewController?.pause();
        }
      } on UnimplementedError catch (e) {
        _log.warning("Unimplemented: ", e);
      } catch (e, st) {
        _log.severe("Unexpected: ", e, st);
      }
      try {
        if (InAppWebViewController.isMethodSupported(.pauseTimers)) {
          _webViewController?.pauseTimers();
          _globalTimersPaused = true;
        }
      } on UnimplementedError catch (e) {
        _log.warning("Unimplemented: ", e);
      } catch (e, st) {
        _log.severe("Unexpected: ", e, st);
      }
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
      if (_webViewController == null) return;
      _log.info('App foregrounded — resuming WebView and reloading skin');
      unawaited(_resumeWebViewTimers(_webViewController!, 'resume'));
      try {
        if (InAppWebViewController.isMethodSupported(.resume)) {
          _webViewController?.resume();
        }
      } on UnimplementedError catch (e) {
        _log.warning("Unimplemented: ", e);
      } catch (e, st) {
        _log.severe("Unexpected: ", e, st);
      }
      if (_didBlank) {
        _didBlank = false;
        _webViewController?.loadUrl(
          urlRequest: URLRequest(url: WebUri(_skinUrl)),
        );
      }
    }
  }

  Future<void> _checkCompatibilityAndInit() async {
    if (widget.webView != null) {
      _isCheckingCompatibility = false;
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

    final result = await WebViewCompatibilityChecker.checkCompatibility();

    setState(() {
      _compatibilityResult = result;
      _isCheckingCompatibility = false;
    });

    if (result.isCompatible) {
      _log.info('WebView is compatible');
    } else {
      _log.warning('WebView is not compatible: ${result.reason}');
    }
  }

  InAppWebViewSettings _createSettings() {
    return InAppWebViewSettings(
      javaScriptEnabled: true,
      javaScriptCanOpenWindowsAutomatically: false,

      mediaPlaybackRequiresUserGesture: false,

      allowFileAccessFromFileURLs: false,
      allowUniversalAccessFromFileURLs: false,

      useShouldOverrideUrlLoading: true,

      browserAcceleratorKeysEnabled: !Platform.isWindows,

      cacheEnabled: false,

      supportZoom: false,
      builtInZoomControls: false,
      enableViewportScale: true,

      verticalScrollBarEnabled: false,
      horizontalScrollBarEnabled: false,

      userAgent: "Decent",

      rendererPriorityPolicy: RendererPriorityPolicy(
        rendererRequestedPriority: RendererPriority.RENDERER_PRIORITY_BOUND,
        waivedWhenNotVisible: false,
      ),
      useOnRenderProcessGone: true,
    );
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

  void _exitToDashboard() {
    Navigator.of(
      context,
    ).pushNamedAndRemoveUntil(LauncherView.routeName, (_) => false);
  }

  @override
  Widget build(BuildContext context) {
    final view = Scaffold(
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
              style: Theme.of(
                context,
              ).textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w500),
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
      final canLaunch = await canLaunchUrl(url);
      if (canLaunch) {
        await launchUrl(url, mode: LaunchMode.externalApplication);

        if (mounted) {
          _exitToDashboard();
        }
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

    if (_errorMessage != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24.0),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            spacing: 16,
            children: [
              const Icon(Icons.error_outline, size: 64, color: Colors.red),
              Text(
                'WebView Error',
                style: Theme.of(context).textTheme.headlineSmall,
              ),
              Text(
                _errorMessage!,
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodyMedium,
              ),
              const SizedBox(height: 16),
              ElevatedButton(
                onPressed: _exitToDashboard,
                child: const Text('Go to Dashboard'),
              ),
            ],
          ),
        ),
      );
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

    return _buildWebViewStack();
  }

  Widget _buildWebViewStack() {
    return ValueListenableBuilder<SimulatedWebViewDevice?>(
      valueListenable: simulatedWebViewDevice,
      builder: (context, simulatedDevice, _) {
        return Stack(
          clipBehavior: Platform.isAndroid ? Clip.none : Clip.hardEdge,
          children: [
            Positioned.fill(
              right: Platform.isAndroid ? -1 : 0,
              bottom: Platform.isAndroid ? -1 : 0,
              child: _buildWebView(simulatedDevice),
            ),
            if (_isLoading) const Center(child: CircularProgressIndicator()),
            if (defaultTargetPlatform == TargetPlatform.windows)
              Positioned(
                top: 8,
                right: 8,
                child: Material(
                  color: Theme.of(
                    context,
                  ).colorScheme.surfaceContainer.withValues(alpha: 0.9),
                  elevation: 2,
                  borderRadius: BorderRadius.circular(8),
                  child: IconButton(
                    tooltip: 'Open Dashboard',
                    onPressed: _exitToDashboard,
                    icon: const Icon(Icons.dashboard),
                    iconSize: 20,
                    constraints: const BoxConstraints.tightFor(
                      width: 40,
                      height: 40,
                    ),
                  ),
                ),
              ),
          ],
        );
      },
    );
  }

  Widget _buildWebView(SimulatedWebViewDevice? simulatedDevice) {
    if (widget.webView != null) return widget.webView!;
    return InAppWebView(
      key: ValueKey(simulatedDevice?.id ?? 'native-webview'),
      initialUrlRequest: URLRequest(url: WebUri(_skinUrl)),
      initialSettings: _createSettings(),
      initialUserScripts: _initialUserScripts(simulatedDevice),
      onWebViewCreated: (controller) {
        _log.info('InAppWebView created');
        _webViewController = controller;
        unawaited(_resumeWebViewTimers(controller, 'onWebViewCreated'));
      },
      onLoadStart: (controller, url) {
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
        if (_skinExitCoordinator.inProgress &&
            request.url.toString() == skinExitDashboardUrl) {
          return;
        }
        _log.warning(
          'WebView error - Code: ${error.type}, Description: ${error.description}',
        );
        if (!shouldShowSkinLoadError(request.isForMainFrame)) return;
        if (!mounted) return;
        setState(() {
          _isLoading = false;
          _errorMessage = 'Failed to load skin: ${error.description}';
        });
      },
      onReceivedHttpError: (controller, request, errorResponse) {
        _log.warning('HTTP error - Status: ${errorResponse.statusCode}');
      },
      shouldOverrideUrlLoading: (controller, navigationAction) async {
        final uri = navigationAction.request.url;
        switch (classifySkinNavigation(uri)) {
          case SkinNavDecision.exitDashboard:
            if (_skinExitCoordinator.tryStart(
              target: uri,
              isForMainFrame: navigationAction.isForMainFrame,
              topLevelUri: _mainFrameUri,
            )) {
              _log.info('Skin requested dashboard');
              if (mounted) _exitToDashboard();
            } else {
              _log.warning('Rejected skin dashboard request');
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
      onRenderProcessGone: (controller, detail) {
        _log.warning(
          'WebView renderer process gone — '
          'didCrash: ${detail.didCrash}, '
          'rendererPriorityAtExit: ${detail.rendererPriorityAtExit}',
        );
        _webViewController = null;
        setState(() {
          _rendererCrashed = true;
        });
        Future.delayed(const Duration(milliseconds: 500), () {
          if (mounted) {
            setState(() {
              _rendererCrashed = false;
            });
          }
        });
      },
    );
  }

  Future<void> _resumeWebViewTimers(
    InAppWebViewController controller,
    String where,
  ) async {
    final wasPaused = _globalTimersPaused;
    try {
      if (InAppWebViewController.isMethodSupported(.resumeTimers)) {
        await controller.resumeTimers();
        _globalTimersPaused = false;
        if (wasPaused) {
          _log.warning('Balanced WebView timer pause in $where');
        }
      }
    } on UnimplementedError catch (e) {
      _log.warning("Unimplemented: ", e);
    } catch (e, st) {
      _log.severe("Unexpected: ", e, st);
    }
  }

  UnmodifiableListView<UserScript> _initialUserScripts(
    SimulatedWebViewDevice? simulatedDevice,
  ) {
    return UnmodifiableListView<UserScript>([
      _hostIdentityScript(),
      ...?_simulatedDeviceScripts(simulatedDevice),
    ]);
  }

  UserScript _hostIdentityScript() {
    final payload = jsonEncode({
      'app': 'decent.app',
      'platform': Platform.operatingSystem,
      'version': BuildInfo.version,
      'build': BuildInfo.buildNumber,
      'commit': BuildInfo.commitShort,
    });
    return UserScript(
      source:
          '''
(function () {
  try {
    Object.defineProperty(window, '__DECENT_HOST__', {
      value: Object.freeze($payload),
      configurable: false,
      writable: false,
      enumerable: false
    });
  } catch (_) {}
})();
''',
      injectionTime: UserScriptInjectionTime.AT_DOCUMENT_START,
      contentWorld: ContentWorld.PAGE,
    );
  }

  UnmodifiableListView<UserScript>? _simulatedDeviceScripts(
    SimulatedWebViewDevice? simulatedDevice,
  ) {
    final isDesktop =
        Platform.isMacOS || Platform.isWindows || Platform.isLinux;
    if (!widget.settingsController.enableSimulatedWebViews ||
        !isDesktop ||
        simulatedDevice == null) {
      return null;
    }

    final dpr = simulatedDevice.devicePixelRatio.toStringAsFixed(6);
    final surfaceWidth = simulatedDevice.webViewSurfaceSize.width.toInt();
    final surfaceHeight = simulatedDevice.webViewSurfaceSize.height.toInt();
    final cssWidth = simulatedDevice.viewportSize.width.toStringAsFixed(3);
    final cssHeight = simulatedDevice.viewportSize.height.toStringAsFixed(3);
    final screenWidth = simulatedDevice.screenSize.width.toStringAsFixed(3);
    final screenHeight = simulatedDevice.screenSize.height.toStringAsFixed(3);
    final outerWidth = simulatedDevice.outerWidth.toStringAsFixed(3);
    final maxTouchPoints = simulatedDevice.maxTouchPoints;
    final platform = simulatedDevice.platform;

    return UnmodifiableListView<UserScript>([
      UserScript(
        source:
            '''
(function () {
  const define = (target, key, value) => {
    try {
      Object.defineProperty(target, key, {
        configurable: true,
        get: () => value
      });
    } catch (_) {}
  };

  define(window, 'devicePixelRatio', $dpr);
  define(window, 'innerWidth', $cssWidth);
  define(window, 'innerHeight', $cssHeight);
  define(window, 'outerWidth', $outerWidth);
  define(window, 'outerHeight', $cssHeight);
  define(window.screen, 'width', $screenWidth);
  define(window.screen, 'height', $screenHeight);
  define(window.screen, 'availWidth', $screenWidth);
  define(window.screen, 'availHeight', $screenHeight);
  define(navigator, 'maxTouchPoints', $maxTouchPoints);
  define(navigator, 'platform', '$platform');
  define(window, 'ontouchstart', null);
  define(document, 'ontouchstart', null);
  define(document.documentElement, 'ontouchstart', null);

  define(window.visualViewport, 'width', $surfaceWidth / $dpr);
  define(window.visualViewport, 'height', $surfaceHeight / $dpr);

  const nativeMatchMedia = window.matchMedia
    ? window.matchMedia.bind(window)
    : null;
  const touchMedia = new Map([
    ['(pointer:coarse)', true],
    ['(any-pointer:coarse)', true],
    ['(hover:none)', true],
    ['(any-hover:none)', true],
    ['(pointer:fine)', false],
    ['(any-pointer:fine)', false],
    ['(hover:hover)', false],
    ['(any-hover:hover)', false]
  ]);
  window.matchMedia = (query) => {
    const normalized = String(query).replace(/\\s+/g, '').toLowerCase();
    const simulatedMatch = touchMedia.get(normalized);
    const nativeResult = nativeMatchMedia ? nativeMatchMedia(query) : null;
    if (simulatedMatch === undefined) {
      return nativeResult;
    }
    return {
      matches: simulatedMatch,
      media: nativeResult ? nativeResult.media : String(query),
      onchange: null,
      addListener: nativeResult && nativeResult.addListener
        ? nativeResult.addListener.bind(nativeResult)
        : () => {},
      removeListener: nativeResult && nativeResult.removeListener
        ? nativeResult.removeListener.bind(nativeResult)
        : () => {},
      addEventListener: nativeResult && nativeResult.addEventListener
        ? nativeResult.addEventListener.bind(nativeResult)
        : () => {},
      removeEventListener: nativeResult && nativeResult.removeEventListener
        ? nativeResult.removeEventListener.bind(nativeResult)
        : () => {},
      dispatchEvent: nativeResult && nativeResult.dispatchEvent
        ? nativeResult.dispatchEvent.bind(nativeResult)
        : () => false
    };
  };
})();
''',
        injectionTime: UserScriptInjectionTime.AT_DOCUMENT_START,
        contentWorld: ContentWorld.PAGE,
      ),
    ]);
  }
}
