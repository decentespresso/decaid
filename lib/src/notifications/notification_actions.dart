import 'package:flutter/widgets.dart';
import 'package:logging/logging.dart';
import 'package:url_launcher/url_launcher.dart';

import '../services/update_check_service.dart';
import 'native_notification.dart';
import 'notification_center.dart';

class NotificationActions extends ChangeNotifier with WidgetsBindingObserver {
  NotificationActions({
    required this.center,
    required this.onOpenAccount,
    this.updateCheckService,
    Future<bool> Function(Uri)? launch,
  }) : _launch =
           launch ??
           ((url) => launchUrl(url, mode: LaunchMode.externalApplication)) {
    WidgetsBinding.instance.addObserver(this);
  }

  final NotificationCenter center;
  final VoidCallback onOpenAccount;
  final UpdateCheckService? updateCheckService;
  final Future<bool> Function(Uri) _launch;
  List<(NotificationActivation, NotificationAction)> _pendingReturns = const [];
  bool _leftApplication = false;
  bool _returnedDuringLaunch = false;
  bool _launching = false;
  bool _disposed = false;
  NotificationActivation? _failed;

  bool get busy => _launching;
  String? errorFor(NativeNotification notice) =>
      _failed?.notice.key == notice.key && center.isCurrent(_failed!)
      ? 'Could not open notification action'
      : null;

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) {
      _leftApplication = true;
    } else if (_leftApplication) {
      _leftApplication = false;
      if (_launching) {
        _returnedDuringLaunch = true;
      } else {
        _reportReturns();
      }
    }
  }

  void _reportReturns() {
    final pending = _pendingReturns;
    _pendingReturns = const [];
    for (final (activation, action) in pending) {
      center.reportAction(activation, action, 'returned');
    }
  }

  Future<void> activate(
    NativeNotification notice,
    NotificationAction action, {
    Future<void> Function()? beforeDownload,
  }) async {
    final activation = center.activation(notice);
    if (_disposed ||
        _launching ||
        !center.isCurrent(activation) ||
        !notice.actions.contains(action)) {
      return;
    }
    _launching = true;
    _failed = null;
    notifyListeners();
    try {
      if (action.type == NotificationActionType.openDecentAccount) {
        onOpenAccount();
        center.reportAction(activation, action, 'activated');
      } else if (action.type == NotificationActionType.downloadUpdate) {
        await beforeDownload?.call();
        if (_disposed || !center.isCurrent(activation)) return;
        await activation.binding?.onActivate?.call(action);
      } else {
        _leftApplication = false;
        _returnedDuringLaunch = false;
        _pendingReturns = _pendingReturns
            .where(
              (pending) =>
                  pending.$1.notice.key != notice.key &&
                  center.isCurrent(pending.$1),
            )
            .toList();
        center.reportAction(activation, action, 'activated');
        final opened = await _launch(action.url!);
        if (!opened) throw StateError('External browser is unavailable');
        if (!_disposed && center.isCurrent(activation)) {
          _pendingReturns = [..._pendingReturns, (activation, action)];
        }
      }
    } catch (error, stackTrace) {
      if (!_disposed) {
        center.reportAction(activation, action, 'failed');
        _failed = activation;
        Logger(
          'NotificationActions',
        ).warning('Could not open notification action', error, stackTrace);
      }
    } finally {
      if (!_disposed) {
        if (_returnedDuringLaunch) _reportReturns();
        _launching = false;
        notifyListeners();
      }
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _pendingReturns = const [];
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }
}
