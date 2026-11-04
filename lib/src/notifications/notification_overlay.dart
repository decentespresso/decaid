import 'dart:async';

import 'package:flutter/material.dart';
import 'package:shadcn_ui/shadcn_ui.dart';
import '../launcher/widgets/destination_card.dart';

import 'native_notification.dart';
import 'notification_actions.dart';
import 'notification_center.dart';
import 'notification_update_check.dart';
import 'update_notifications.dart';

Future<void> showNotifications(
  BuildContext context,
  NotificationCenter center,
  NotificationActions actions, {
  bool unreadOnly = false,
  Future<void> Function()? onOpenCenter,
}) async {
  final snapshot = center.value
      .where((notice) => !unreadOnly || !notice.read)
      .toList();
  unawaited(center.markRead(snapshot).catchError((Object _) {}));
  await showShadDialog<void>(
    context: context,
    barrierLabel: 'Close notification list',
    builder: (dialogContext) => NotificationOverlay(
      center: center,
      actions: actions,
      unreadSnapshot: unreadOnly ? snapshot : null,
      onOpenCenter: () async {
        final route = ModalRoute.of(dialogContext);
        Navigator.of(dialogContext).pop();
        await route?.completed;
        if (!context.mounted) return;
        if (onOpenCenter != null) {
          await onOpenCenter();
        } else {
          await showNotifications(context, center, actions);
        }
      },
    ),
  );
}

class NotificationOverlay extends StatelessWidget {
  const NotificationOverlay({
    super.key,
    required this.center,
    required this.actions,
    this.unreadSnapshot,
    this.onOpenCenter,
  });

  final NotificationCenter center;
  final NotificationActions actions;
  final List<NativeNotification>? unreadSnapshot;
  final VoidCallback? onOpenCenter;

  @override
  Widget build(BuildContext context) {
    final available =
        MediaQuery.sizeOf(context).height -
        MediaQuery.paddingOf(context).vertical -
        MediaQuery.viewInsetsOf(context).vertical;
    return ShadDialog(
      scrollable: false,
      constraints: BoxConstraints(
        maxWidth: unreadSnapshot == null ? 720 : 480,
        maxHeight: available * .85,
      ),
      title: Row(
        children: [
          const Expanded(
            child: Text('Notifications', textAlign: TextAlign.start),
          ),
          IconButton(
            tooltip: MaterialLocalizations.of(context).closeButtonTooltip,
            onPressed: () => Navigator.of(context).pop(),
            icon: const Icon(LucideIcons.x),
          ),
        ],
      ),
      actions: unreadSnapshot == null
          ? const []
          : [
              ShadButton.outline(
                height: 48,
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 14,
                ),
                onPressed: onOpenCenter,
                leading: const Icon(LucideIcons.arrowRight, size: 16),
                child: const Flexible(child: Text('Go to notification center')),
              ),
            ],
      closeIcon: const SizedBox.shrink(),
      child: ListenableBuilder(
        listenable: Listenable.merge([center, actions]),
        builder: (context, _) {
          final notices = unreadSnapshot == null
              ? center.value
              : unreadSnapshot!
                    .where(
                      (notice) => center.value.any(
                        (current) =>
                            current.key == notice.key &&
                            current.revision == notice.revision,
                      ),
                    )
                    .toList();
          return SizedBox(
            width: unreadSnapshot == null ? 656 : 416,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (center.error != null)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 12),
                    child: Text(
                      center.error!,
                      style: TextStyle(
                        color: ShadTheme.of(context).colorScheme.destructive,
                      ),
                    ),
                  ),
                Flexible(
                  child: notices.isEmpty
                      ? const Padding(
                          padding: EdgeInsets.symmetric(vertical: 32),
                          child: Text('No notifications'),
                        )
                      : ListView.separated(
                          shrinkWrap: true,
                          itemCount: notices.length,
                          separatorBuilder: (_, _) => const Divider(height: 24),
                          itemBuilder: (context, index) => _NotificationRow(
                            notice: notices[index],
                            center: center,
                            actions: actions,
                            compact: unreadSnapshot != null,
                          ),
                        ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}

class _NotificationRow extends StatelessWidget {
  const _NotificationRow({
    required this.notice,
    required this.center,
    required this.actions,
    required this.compact,
  });

  final NativeNotification notice;
  final NotificationCenter center;
  final NotificationActions actions;
  final bool compact;

  Future<void> _closeForDownload(BuildContext context) async {
    final route = ModalRoute.of(context);
    Navigator.of(context).pop();
    await route?.completed;
  }

  bool get _isAppUpdate =>
      notice.namespace == NotificationNamespace.host &&
      notice.sourceId == UpdateNotifications.sourceId;

  @override
  Widget build(BuildContext context) => Row(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Expanded(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              notice.namespace == NotificationNamespace.plugin
                  ? '${notice.sourceName} (${notice.sourceId})'
                  : notice.sourceName,
              style: ShadTheme.of(context).textTheme.small,
            ),
            const SizedBox(height: 8),
            Text(notice.message),
            if (!compact && !center.isConfirmed(notice))
              const Padding(
                padding: EdgeInsets.only(top: 8),
                child: Text('Awaiting confirmation'),
              ),
            if (!compact && actions.errorFor(notice) != null)
              Text(actions.errorFor(notice)!),
            if (!compact && _isAppUpdate && !center.isConfirmed(notice))
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: NotificationUpdateCheck(
                  service: actions.updateCheckService,
                ),
              )
            else if (!compact) ...[
              for (final action in notice.actions)
                if (action.url != null)
                  Text(
                    action.url!.host,
                    style: ShadTheme.of(context).textTheme.muted,
                  ),
              if (notice.actions.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: notice.actions
                        .map(
                          (action) => ShadButton.outline(
                            height: 0,
                            padding: const EdgeInsets.symmetric(
                              horizontal: 12,
                              vertical: 14,
                            ),
                            enabled:
                                center.isConfirmed(notice) && !actions.busy,
                            onPressed: () => actions.activate(
                              notice,
                              action,
                              beforeDownload: () => _closeForDownload(context),
                            ),
                            leading: Icon(switch (action.type) {
                              NotificationActionType.openDecentAccount =>
                                LucideIcons.user,
                              NotificationActionType.openExternalUrl =>
                                LucideIcons.externalLink,
                              NotificationActionType.downloadUpdate =>
                                LucideIcons.download,
                              NotificationActionType.skipUpdate =>
                                LucideIcons.skipForward,
                            }, size: 16),
                            child: Flexible(child: Text(action.label)),
                          ),
                        )
                        .toList(),
                  ),
                ),
            ],
          ],
        ),
      ),
    ],
  );
}

class NotificationBell extends StatelessWidget {
  const NotificationBell({
    super.key,
    required this.center,
    required this.actions,
    this.onOpenCenter,
  });

  final NotificationCenter center;
  final NotificationActions actions;
  final Future<void> Function()? onOpenCenter;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: center,
    builder: (context, _) => center.unreadCount == 0
        ? const SizedBox.shrink()
        : SafeArea(
            minimum: const EdgeInsets.only(bottom: 64),
            child: Badge.count(
              count: center.unreadCount,
              child: FloatingActionButton(
                shape: const CircleBorder(),
                tooltip: 'Notifications (${center.unreadCount} unread)',
                onPressed: () => showNotifications(
                  context,
                  center,
                  actions,
                  unreadOnly: true,
                  onOpenCenter: onOpenCenter,
                ),
                child: const Icon(LucideIcons.bell),
              ),
            ),
          ),
  );
}

class NotificationDestination extends StatelessWidget {
  const NotificationDestination({
    super.key,
    required this.center,
    required this.actions,
  });

  final NotificationCenter center;
  final NotificationActions actions;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: center,
    builder: (context, _) => DestinationCard(
      icon: LucideIcons.bell,
      label: 'Notifications',
      badge: center.unreadCount > 0 ? '${center.unreadCount}' : null,
      onTap: () => showNotifications(context, center, actions),
    ),
  );
}
