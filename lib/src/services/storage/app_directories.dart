import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// Resolves platform-appropriate directories for application-managed data.
///
/// On desktop, internal state lives under Application Support so Decent files
/// never appear in user Documents. On mobile, the Documents directory is
/// already the app-private sandbox and is kept as-is.
class AppDirectories {
  AppDirectories._();

  static bool get isDesktop {
    switch (defaultTargetPlatform) {
      case TargetPlatform.macOS:
      case TargetPlatform.windows:
      case TargetPlatform.linux:
        return true;
      case TargetPlatform.android:
      case TargetPlatform.iOS:
      case TargetPlatform.fuchsia:
        return false;
    }
  }

  static Future<String> get support async => isDesktop
      ? (await getApplicationSupportDirectory()).path
      : (await getApplicationDocumentsDirectory()).path;

  static Future<String> get temp async => (await getTemporaryDirectory()).path;

  static Future<String> get hive async => p.join(await support, 'store');

  /// Directory containing `log.txt` and `webview_console.log`.
  ///
  /// Desktop uses a dedicated `logs` subdirectory; mobile keeps logs at the
  /// support root so the existing layout is unchanged.
  static Future<String> get logs async =>
      isDesktop ? p.join(await support, 'logs') : await support;

  static Future<String> get plugins async => p.join(await support, 'plugins');

  static Future<String> get webUi async => p.join(await support, 'web-ui');
}
