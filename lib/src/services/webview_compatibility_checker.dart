import 'dart:async';
import 'dart:io';

import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:logging/logging.dart';

class CompatibilityResult {
  final bool isCompatible;
  final String reason;
  final CompatibilityIssue? issue;

  const CompatibilityResult({
    required this.isCompatible,
    required this.reason,
    this.issue,
  });

  const CompatibilityResult.compatible()
    : isCompatible = true,
      reason = 'WebView is compatible',
      issue = null;

  const CompatibilityResult.incompatible(this.reason, this.issue)
    : isCompatible = false;
}

enum CompatibilityIssue {
  knownProblematicDevice,
  oldAndroidVersion,
  webViewRenderingFailed,
  webViewNotAvailable,
  webView2RuntimeMissing,
}

class WebViewCompatibilityChecker {
  static final _log = Logger('WebViewCompatibilityChecker');
  static CompatibilityResult? _cachedResult;

  static const _problematicManufacturerSettleDelay = Duration(
    milliseconds: 500,
  );

  static Future<CompatibilityResult> checkCompatibility({
    bool forceRecheck = false,
  }) async {
    if (_cachedResult != null && !forceRecheck) {
      _log.fine('Using cached compatibility result: ${_cachedResult!.reason}');
      return _cachedResult!;
    }

    if (Platform.isWindows) {
      _cachedResult = await _checkWindowsWebView2Runtime();
      return _cachedResult!;
    }

    if (!Platform.isAndroid) {
      _log.info('Non-Android platform - WebView is compatible');
      _cachedResult = const CompatibilityResult.compatible();
      return _cachedResult!;
    }

    _log.info('Starting WebView compatibility check...');

    final deviceCheckResult = await _checkDeviceInfo();
    if (!deviceCheckResult.isCompatible) {
      _cachedResult = deviceCheckResult;
      return _cachedResult!;
    }

    try {
      final androidInfo = await DeviceInfoPlugin().androidInfo;
      final manufacturer = androidInfo.manufacturer.toLowerCase();
      if (_isProblematicManufacturer(manufacturer)) {
        _log.info(
          'Problematic manufacturer ($manufacturer) — delaying '
          'WebView test by '
          '${_problematicManufacturerSettleDelay.inMilliseconds}ms '
          'to let BLE traffic settle.',
        );
        await Future.delayed(_problematicManufacturerSettleDelay);
      }
    } catch (e, st) {
      _log.warning('Pre-WebView-test delay probe failed, continuing', e, st);
    }

    final runtimeCheckResult = await _testWebViewRendering();
    _cachedResult = runtimeCheckResult;
    return _cachedResult!;
  }

  static Future<CompatibilityResult> _checkWindowsWebView2Runtime() async {
    _log.info('Checking WebView2 Runtime availability on Windows...');
    try {
      final version = await WebViewEnvironment.getAvailableVersion().timeout(
        const Duration(seconds: 5),
        onTimeout: () => null,
      );
      if (version == null) {
        _log.warning('WebView2 Runtime not found on this system');
        return CompatibilityResult.incompatible(
          'Microsoft Edge WebView2 Runtime is not installed. '
          'Install it from https://go.microsoft.com/fwlink/p/?LinkId=2124703',
          CompatibilityIssue.webView2RuntimeMissing,
        );
      }
      _log.info('WebView2 Runtime available: $version');
      return const CompatibilityResult.compatible();
    } catch (e, stackTrace) {
      _log.severe('Failed to probe WebView2 Runtime', e, stackTrace);
      return CompatibilityResult.incompatible(
        'Could not verify WebView2 Runtime: $e',
        CompatibilityIssue.webView2RuntimeMissing,
      );
    }
  }

  static Future<CompatibilityResult> _checkDeviceInfo() async {
    try {
      final deviceInfo = DeviceInfoPlugin();
      final androidInfo = await deviceInfo.androidInfo;

      final manufacturer = androidInfo.manufacturer.toLowerCase();
      final model = androidInfo.model.toLowerCase();
      final sdkInt = androidInfo.version.sdkInt;
      final androidVersion = androidInfo.version.release;

      _log.info(
        'Device info - Manufacturer: $manufacturer, Model: $model, '
        'Android: $androidVersion (SDK $sdkInt)',
      );

      if (_isProblematicManufacturer(manufacturer)) {
        _log.warning(
          'Device manufacturer $manufacturer has had WebView issues in the past. '
          'Proceeding to runtime test.',
        );
      }

      if (_isProblematicModel(model)) {
        _log.warning(
          'Device model $model has had WebView issues in the past. '
          'Proceeding to runtime test.',
        );
      }

      if (sdkInt < 29) {
        final reason =
            'Android version too old for stable WebView: $androidVersion (SDK $sdkInt)';
        _log.warning(reason);
        return CompatibilityResult.incompatible(
          reason,
          CompatibilityIssue.oldAndroidVersion,
        );
      }

      _log.info('Device info check passed');
      return const CompatibilityResult.compatible();
    } catch (e, stackTrace) {
      _log.severe('Failed to get device info', e, stackTrace);
      return CompatibilityResult.incompatible(
        'Unable to determine device compatibility: $e',
        CompatibilityIssue.webViewNotAvailable,
      );
    }
  }

  static Future<CompatibilityResult> _testWebViewRendering() async {
    _log.info('Starting runtime WebView test...');

    try {
      final completer = Completer<CompatibilityResult>();
      HeadlessInAppWebView? headlessWebView;

      final testHtml = '''
        <!DOCTYPE html>
        <html>
        <head>
          <meta name="viewport" content="width=device-width, initial-scale=1.0">
          <style>
            body { margin: 0; padding: 20px; font-family: sans-serif; }
            #test { background: linear-gradient(45deg, #667eea 0%, #764ba2 100%); 
                    color: white; padding: 20px; border-radius: 8px; }
          </style>
        </head>
        <body>
          <div id="test">WebView Test</div>
          <script>
            // Test JavaScript execution
            window.testResult = document.getElementById('test') ? 'ok' : 'fail';
          </script>
        </body>
        </html>
      ''';

      headlessWebView = HeadlessInAppWebView(
        initialData: InAppWebViewInitialData(data: testHtml),
        initialSettings: InAppWebViewSettings(
          javaScriptEnabled: true,
          transparentBackground: false,
        ),
        onLoadStop: (controller, url) async {
          _log.fine('Headless WebView loaded, testing JavaScript...');
          try {
            final jsResult = await controller.evaluateJavascript(
              source: 'window.testResult',
            );

            if (jsResult != 'ok') {
              _log.warning('JavaScript execution test failed: $jsResult');
              completer.complete(
                CompatibilityResult.incompatible(
                  'WebView JavaScript execution failed',
                  CompatibilityIssue.webViewRenderingFailed,
                ),
              );
              await headlessWebView?.dispose();
              return;
            }

            final domTest = await controller.evaluateJavascript(
              source: '''
                (function() {
                  try {
                    const elem = document.getElementById('test');
                    return elem && elem.textContent === 'WebView Test' ? 'ok' : 'fail';
                  } catch(e) {
                    return 'error: ' + e.message;
                  }
                })()
              ''',
            );

            if (domTest != 'ok') {
              _log.warning('DOM access test failed: $domTest');
              completer.complete(
                CompatibilityResult.incompatible(
                  'WebView DOM manipulation failed',
                  CompatibilityIssue.webViewRenderingFailed,
                ),
              );
              await headlessWebView?.dispose();
              return;
            }

            final cssTest = await controller.evaluateJavascript(
              source: '''
                (function() {
                  try {
                    const elem = document.getElementById('test');
                    const style = window.getComputedStyle(elem);
                    return style.background.includes('gradient') || 
                           style.backgroundImage.includes('gradient') ? 'ok' : 'fail';
                  } catch(e) {
                    return 'error: ' + e.message;
                  }
                })()
              ''',
            );

            if (cssTest != 'ok') {
              _log.warning('CSS rendering test failed: $cssTest');
              completer.complete(
                CompatibilityResult.incompatible(
                  'WebView CSS rendering may be unreliable',
                  CompatibilityIssue.webViewRenderingFailed,
                ),
              );
              await headlessWebView?.dispose();
              return;
            }

            _log.info('Runtime WebView test passed - all checks OK');
            completer.complete(const CompatibilityResult.compatible());
            await headlessWebView?.dispose();
          } catch (e, stackTrace) {
            _log.severe('Error during WebView testing', e, stackTrace);
            completer.complete(
              CompatibilityResult.incompatible(
                'WebView test error: $e',
                CompatibilityIssue.webViewRenderingFailed,
              ),
            );
            await headlessWebView?.dispose();
          }
        },
        onReceivedError: (controller, request, error) {
          _log.warning('WebView error during test: ${error.description}');
          completer.complete(
            CompatibilityResult.incompatible(
              'WebView failed to load: ${error.description}',
              CompatibilityIssue.webViewRenderingFailed,
            ),
          );
          headlessWebView?.dispose();
        },
        onReceivedHttpError: (controller, request, errorResponse) {
          _log.warning('HTTP error during test: ${errorResponse.statusCode}');
          completer.complete(
            CompatibilityResult.incompatible(
              'WebView HTTP error: ${errorResponse.statusCode}',
              CompatibilityIssue.webViewRenderingFailed,
            ),
          );
          headlessWebView?.dispose();
        },
      );

      await headlessWebView.run();

      return await completer.future.timeout(
        const Duration(seconds: 10),
        onTimeout: () {
          _log.warning('WebView test timed out');
          headlessWebView?.dispose();
          return CompatibilityResult.incompatible(
            'WebView test timed out - may be too slow on this device',
            CompatibilityIssue.webViewRenderingFailed,
          );
        },
      );
    } catch (e, stackTrace) {
      _log.severe('Failed to run WebView test', e, stackTrace);
      return CompatibilityResult.incompatible(
        'WebView test failed: $e',
        CompatibilityIssue.webViewNotAvailable,
      );
    }
  }

  static bool _isProblematicManufacturer(String manufacturer) {
    final problematic = ['teclast', 'allwinner', 'rockchip'];

    for (final brand in problematic) {
      if (manufacturer.contains(brand)) {
        return true;
      }
    }

    return false;
  }

  static bool _isProblematicModel(String model) {
    final problematic = ['p80', 'p20', 'p10', 'm40'];

    for (final modelPattern in problematic) {
      if (model.contains(modelPattern)) {
        return true;
      }
    }

    if (model.contains('mt') && model.length > 3) {
      final mtIndex = model.indexOf('mt');
      if (mtIndex >= 0 && mtIndex + 2 < model.length) {
        final afterMt = model.substring(mtIndex + 2);
        if (afterMt.isNotEmpty &&
            afterMt[0].codeUnitAt(0) >= '0'.codeUnitAt(0) &&
            afterMt[0].codeUnitAt(0) <= '9'.codeUnitAt(0)) {
          _log.warning('Possible MediaTek chipset detected in model: $model');
        }
      }
    }

    return false;
  }

  static void clearCache() {
    _log.fine('Clearing compatibility cache');
    _cachedResult = null;
  }
}
