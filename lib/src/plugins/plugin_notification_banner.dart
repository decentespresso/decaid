import 'package:flutter/material.dart';
import 'package:logging/logging.dart';
import 'package:shadcn_ui/shadcn_ui.dart' show LucideIcons;
import 'package:url_launcher/url_launcher.dart';

import 'plugin_notifications.dart';

class PluginNotificationBanner extends StatefulWidget {
  const PluginNotificationBanner({
    super.key,
    required this.center,
    required this.onOpenAccount,
    required this.child,
  });

  final PluginNotificationCenter center;
  final VoidCallback onOpenAccount;
  final Widget child;

  @override
  State<PluginNotificationBanner> createState() =>
      _PluginNotificationBannerState();
}

class _PluginNotificationBannerState extends State<PluginNotificationBanner>
    with WidgetsBindingObserver {
  List<PluginNotification> _pendingReturns = const [];
  bool _leftApplication = false;
  bool _launching = false;
  bool _returnedDuringLaunch = false;
  PluginNotification? _failedNotice;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didUpdateWidget(PluginNotificationBanner oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.center != widget.center) _pendingReturns = const [];
  }

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
    for (final notice in pending) {
      if (widget.center.isCurrent(notice)) notice.reportAction('returned');
    }
  }

  Future<void> _activate(PluginNotification notice) async {
    if (_launching || !widget.center.isCurrent(notice)) return;
    final action = notice.action;
    if (action == null) return;
    if (action.type == PluginNotificationActionType.openDecentAccount) {
      widget.onOpenAccount();
      notice.reportAction('activated');
      return;
    }
    setState(() {
      _launching = true;
      _failedNotice = null;
    });
    _leftApplication = false;
    _returnedDuringLaunch = false;
    _pendingReturns = _pendingReturns
        .where((entry) => entry != notice && widget.center.isCurrent(entry))
        .toList();
    notice.reportAction('activated');
    try {
      final opened = await launchUrl(
        action.url!,
        mode: LaunchMode.externalApplication,
      );
      if (!opened) throw StateError('External browser is unavailable');
      if (mounted && widget.center.isCurrent(notice)) {
        _pendingReturns = [..._pendingReturns, notice];
      }
    } catch (error, stackTrace) {
      notice.reportAction('failed');
      if (mounted) setState(() => _failedNotice = notice);
      Logger(
        'PluginNotificationBanner',
      ).warning('Could not open plugin notification link', error, stackTrace);
    } finally {
      if (mounted && _returnedDuringLaunch) _reportReturns();
      if (mounted) setState(() => _launching = false);
    }
  }

  Widget _notice(PluginNotification notice) {
    final action = notice.action;
    return Semantics(
      liveRegion: true,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 8, 8),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '${notice.pluginName} (${notice.pluginId})',
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontWeight: FontWeight.bold),
                  ),
                  Text(notice.message),
                  if (action?.url != null)
                    Text(
                      action!.url!.host,
                      style: const TextStyle(fontSize: 12),
                    ),
                  if (_failedNotice == notice)
                    const Text('Could not open link'),
                  if (action != null)
                    TextButton.icon(
                      onPressed: _launching ? null : () => _activate(notice),
                      icon: Icon(
                        action.type ==
                                PluginNotificationActionType.openDecentAccount
                            ? LucideIcons.user
                            : LucideIcons.externalLink,
                      ),
                      label: Text(action.label, softWrap: true),
                    ),
                ],
              ),
            ),
            IconButton(
              tooltip: 'Dismiss notification from ${notice.pluginName}',
              onPressed: () => widget.center.dismissByUser(notice),
              icon: const Icon(LucideIcons.x),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) =>
      ValueListenableBuilder<List<PluginNotification>>(
        valueListenable: widget.center,
        child: widget.child,
        builder: (context, notices, child) => Column(
          children: [
            if (notices.isNotEmpty)
              ConstrainedBox(
                constraints: BoxConstraints(
                  maxHeight: MediaQuery.sizeOf(context).height * 0.4,
                ),
                child: Overlay.wrap(
                  alwaysSizeToContent: true,
                  clipBehavior: Clip.none,
                  child: Material(
                    color: Theme.of(context).colorScheme.surfaceContainerHigh,
                    child: SafeArea(
                      bottom: false,
                      child: ListView.separated(
                        shrinkWrap: true,
                        primary: false,
                        itemCount: notices.length,
                        itemBuilder: (context, index) =>
                            _notice(notices[index]),
                        separatorBuilder: (context, index) =>
                            const Divider(height: 1),
                      ),
                    ),
                  ),
                ),
              ),
            Expanded(child: child!),
          ],
        ),
      );

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }
}
