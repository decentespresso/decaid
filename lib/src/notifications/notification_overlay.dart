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
  NotificationActions actions,
) async {
  final snapshot = center.value;
  unawaited(center.markRead(snapshot).catchError((Object _) {}));
  await showShadDialog<void>(
    context: context,
    barrierLabel: 'Close notification list',
    builder: (context) => NotificationOverlay(center: center, actions: actions),
  );
}

class NotificationOverlay extends StatelessWidget {
  const NotificationOverlay({
    super.key,
    required this.center,
    required this.actions,
  });

  final NotificationCenter center;
  final NotificationActions actions;

  @override
  Widget build(BuildContext context) {
    final available =
        MediaQuery.sizeOf(context).height -
        MediaQuery.paddingOf(context).vertical -
        MediaQuery.viewInsetsOf(context).vertical;
    return ShadDialog(
      scrollable: false,
      constraints: BoxConstraints(maxWidth: 720, maxHeight: available * .85),
      title: Row(
        children: [
          const Expanded(
            child: Text('Notifications', textAlign: TextAlign.start),
          ),
          ListenableBuilder(
            listenable: center,
            builder: (context, _) => IconButton(
              tooltip: 'Dismiss all notifications',
              onPressed: center.value.isEmpty
                  ? null
                  : () => unawaited(
                      Future.forEach(
                        center.value,
                        center.dismissByUser,
                      ).catchError((Object _) {}),
                    ),
              icon: const Icon(LucideIcons.trash2),
            ),
          ),
          IconButton(
            tooltip: MaterialLocalizations.of(context).closeButtonTooltip,
            onPressed: () => Navigator.of(context).pop(),
            icon: const Icon(LucideIcons.x),
          ),
        ],
      ),
      closeIcon: const SizedBox.shrink(),
      child: ListenableBuilder(
        listenable: Listenable.merge([center, actions]),
        builder: (context, _) => SizedBox(
          width: 656,
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
                child: center.value.isEmpty
                    ? const Padding(
                        padding: EdgeInsets.symmetric(vertical: 32),
                        child: Text('No notifications'),
                      )
                    : ListView.separated(
                        shrinkWrap: true,
                        itemCount: center.value.length,
                        separatorBuilder: (_, _) => const Divider(height: 24),
                        itemBuilder: (context, index) => _NotificationRow(
                          notice: center.value[index],
                          center: center,
                          actions: actions,
                        ),
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _NotificationRow extends StatelessWidget {
  const _NotificationRow({
    required this.notice,
    required this.center,
    required this.actions,
  });

  final NativeNotification notice;
  final NotificationCenter center;
  final NotificationActions actions;

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
            if (!center.isConfirmed(notice))
              const Padding(
                padding: EdgeInsets.only(top: 8),
                child: Text('Awaiting confirmation'),
              ),
            if (actions.errorFor(notice) case final error?) Text(error),
            if (_isAppUpdate && !center.isConfirmed(notice))
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: NotificationUpdateCheck(
                  service: actions.updateCheckService,
                ),
              )
            else ...[
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
      IconButton(
        tooltip: _isAppUpdate
            ? 'Skip version ${notice.id}'
            : 'Dismiss notification',
        onPressed: () =>
            unawaited(center.dismissByUser(notice).catchError((Object _) {})),
        icon: const Icon(LucideIcons.trash2, size: 20),
      ),
    ],
  );
}

class NotificationBell extends StatelessWidget {
  const NotificationBell({
    super.key,
    required this.center,
    required this.actions,
  });

  final NotificationCenter center;
  final NotificationActions actions;

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
                onPressed: () => showNotifications(context, center, actions),
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
