import 'dart:async';

import 'package:logging/logging.dart';
import 'package:pub_semver/pub_semver.dart';
import 'package:reaprime/build_info.dart';

import '../services/android_updater.dart';
import '../services/app_update_state.dart';
import '../services/update_check_service.dart';
import 'native_notification.dart';
import 'notification_center.dart';

class UpdateNotifications {
  UpdateNotifications({
    required this.center,
    required this.service,
    required this.onDownload,
  }) {
    _pending = _restore();
    _subscription = service.updateState.listen((state) {
      _pending = _pending.then((_) => _synchronize(state)).catchError((
        Object error,
        StackTrace stackTrace,
      ) {
        Logger(
          'UpdateNotifications',
        ).warning('Could not update saved notification', error, stackTrace);
      });
    });
  }

  static const sourceId = 'app-update';
  final NotificationCenter center;
  final UpdateCheckService service;
  final Future<void> Function(UpdateInfo) onDownload;
  late final StreamSubscription<AppUpdateState> _subscription;
  Future<void> _pending = Future.value();
  bool _disposed = false;

  Future<void> get settled async {
    await Future<void>.delayed(Duration.zero);
    await _pending;
  }

  Future<void> _restore() async {
    final notices = center.value
        .where(
          (notice) =>
              notice.namespace == NotificationNamespace.host &&
              notice.sourceId == sourceId,
        )
        .toList();
    for (final notice in notices) {
      center.bind(
        notice,
        NotificationBinding(
          owner: (service, notice.id),
          confirmed: false,
          isAlive: () => !_disposed,
          onDismissed: (_) => service.skipVersion(notice.id),
        ),
      );
    }
    final skipped = await service.skippedVersion;
    for (final notice in notices) {
      final installed =
          Version.parse(notice.id) <= Version.parse(BuildInfo.version);
      if (installed || notice.id == skipped || !service.canCheck) {
        await center.removeSource(
          NotificationNamespace.host,
          sourceId,
          notice.id,
        );
      }
    }
  }

  Future<void> _synchronize(AppUpdateState state) async {
    if (_disposed) return;
    final update = service.availableUpdate;
    if (update == null) {
      if (service.hasCompletedCheck &&
          state.phase != AppUpdatePhase.checking &&
          state.phase != AppUpdatePhase.error) {
        await center.removeSource(NotificationNamespace.host, sourceId);
      }
      return;
    }
    final release = Uri.parse(service.getReleaseUrl(update)!);
    await center.publish(
      NativeNotification(
        namespace: NotificationNamespace.host,
        sourceId: sourceId,
        sourceName: 'Decaid',
        id: update.version,
        message: 'Update available: ${update.version}',
        actions: [
          NotificationAction(
            id: 'view',
            label: 'View',
            type: NotificationActionType.openExternalUrl,
            url: release,
          ),
          NotificationAction(
            id: 'download',
            label: 'Download',
            type: service.canInstall
                ? NotificationActionType.downloadUpdate
                : NotificationActionType.openExternalUrl,
            url: service.canInstall ? null : release,
          ),
        ],
      ),
      binding: NotificationBinding(
        owner: (service, update.version),
        isAlive: () => !_disposed,
        onActivate: (_) => onDownload(update),
        onDismissed: (_) => service.skipVersion(update.version),
      ),
    );
  }

  Future<void> dispose() async {
    _disposed = true;
    center.retireSource(NotificationNamespace.host, sourceId);
    await _subscription.cancel();
    await _pending;
  }
}
