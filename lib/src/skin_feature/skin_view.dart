import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
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
import 'package:reaprime/src/skin_feature/skin_user_scripts.dart';
import 'package:reaprime/src/skin_feature/skin_webview_composition.dart';
import 'package:reaprime/src/skin_feature/skin_webview_diagnostics.dart';
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
      'Open the Windows system menu from the window icon or by right-clicking '
          'the title bar, then choose Back to Dashboard.',
    TargetPlatform.linux ||
    TargetPlatform.fuchsia => 'Use system back navigation to open it.',
  };
  return '$purpose $navigation';
}

SkinNavDecision classifySkinNavigation(Uri? url, {int skinPort = 3000}) {
  if (url == null) return SkinNavDecision.block;
  if (url.host == 'localhost' && url.path.startsWith('/__decent/')) {
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
        !isForMainFrame ||
        target?.toString() != skinExitDashboardUrlForPort(skinPort) ||
        topLevelUri == null ||
        topLevelUri.scheme != 'http' ||
        topLevelUri.host != 'localhost' ||
        topLevelUri.port != skinPort ||
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
    required this.port,
  });

  final SettingsController settingsController;
  final WebViewLogService webViewLogService;
  final String deviceIp;
  final DisplayController displayController;
  @visibleForTesting
  final Widget? webView;
  final int port;

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
      'http://localhost:${widget.port}/?_=${DateTime.now().millisecondsSinceEpoch}';

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
    return SkinWebViewComposition(
      settings: widget.settingsController,
      platform: defaultTargetPlatform,
      builder: (context, texture) =>
          ValueListenableBuilder<SimulatedWebViewDevice?>(
            valueListenable: simulatedWebViewDevice,
            builder: (context, simulatedDevice, _) {
              return Stack(
                clipBehavior: Platform.isAndroid ? Clip.none : Clip.hardEdge,
                children: [
                  Positioned.fill(
                    right: Platform.isAndroid ? -1 : 0,
                    bottom: Platform.isAndroid ? -1 : 0,
                    child: _buildWebView(simulatedDevice, texture),
                  ),
                  if (_isLoading)
                    const Center(child: CircularProgressIndicator()),
                ],
              );
            },
          ),
    );
  }

  Widget _buildWebView(SimulatedWebViewDevice? simulatedDevice, bool texture) {
    if (widget.webView != null) return widget.webView!;
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
      ),
      onWebViewCreated: (controller) {
        _log.info('InAppWebView created');
        _webViewController = controller;
        if (Platform.isAndroid) {
          unawaited(_logRenderingDiagnostics(controller, texture));
        }
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
            request.url.toString() ==
                skinExitDashboardUrlForPort(widget.port)) {
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
}
