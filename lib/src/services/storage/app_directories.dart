import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

const String newOwnerRecoveryDirectoryName = 'new-owner-recovery';

class AppDirectories {
  AppDirectories._();

  static bool get isDesktop => const {
    TargetPlatform.macOS,
    TargetPlatform.windows,
    TargetPlatform.linux,
  }.contains(defaultTargetPlatform);

  static Future<String> get support async => isDesktop
      ? (await getApplicationSupportDirectory()).path
      : (await getApplicationDocumentsDirectory()).path;

  static Future<String> get temp async => (await getTemporaryDirectory()).path;

  static Future<String> get hive async => p.join(await support, 'store');

  static Future<String> get driftFile async =>
      p.join(await support, 'streamline_bridge.sqlite');

  static Future<String> get logs async =>
      isDesktop ? p.join(await support, 'logs') : await support;

  static Future<String> get plugins async => p.join(await support, 'plugins');

  static Future<String> get webUi async => p.join(await support, 'web-ui');

  /// Owned new-owner recovery namespace.
  ///
  /// It holds the recovery marker, the advisory lock and each owning process's
  /// claim file, stays separate from every user-data directory so a future
  /// app-data cleanup can exclude it, and is not preserved by an OS app-data
  /// clear or uninstall.
  static Future<String> get newOwnerRecovery async =>
      p.join(await support, newOwnerRecoveryDirectoryName);
}
