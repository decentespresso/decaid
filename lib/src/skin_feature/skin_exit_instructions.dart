import 'package:flutter/foundation.dart';

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
