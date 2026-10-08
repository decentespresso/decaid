import 'dart:collection';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:reaprime/build_info.dart';
import 'package:reaprime/src/skin_feature/simulated_webview_device.dart';

UnmodifiableListView<UserScript> buildSkinUserScripts(
  SimulatedWebViewDevice? simulatedDevice, {
  required bool enableSimulatedWebViews,
}) {
  return UnmodifiableListView<UserScript>([
    _hostIdentityScript(),
    ...?_simulatedDeviceScripts(simulatedDevice, enableSimulatedWebViews),
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
  bool enableSimulatedWebViews,
) {
  final isDesktop = Platform.isMacOS || Platform.isWindows || Platform.isLinux;
  if (!enableSimulatedWebViews || !isDesktop || simulatedDevice == null) {
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
