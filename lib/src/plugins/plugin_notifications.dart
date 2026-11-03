import '../notifications/native_notification.dart';

NativeNotification parsePluginNotification({
  required String pluginId,
  required String pluginName,
  required dynamic payload,
  required bool canOpenAccount,
}) {
  if (payload is! Map) throw const FormatException('Invalid notification');
  final rawAction = payload['action'];
  final NotificationAction? action;
  if (rawAction == null) {
    action = null;
  } else {
    if (rawAction is! Map) {
      throw const FormatException('Invalid notification action');
    }
    final type = rawAction['type'];
    if (type != 'openExternalUrl' &&
        !(type == 'openDecentAccount' && canOpenAccount)) {
      throw const FormatException('Notification action is not permitted');
    }
    action = NotificationAction.fromJson(Map<String, dynamic>.from(rawAction));
  }
  return NativeNotification(
    namespace: NotificationNamespace.plugin,
    sourceId: notificationText(pluginId, 128),
    sourceName: notificationText(pluginName, 256),
    id: notificationText(payload['id'], 128),
    message: notificationText(payload['message'], 600),
    actions: action == null ? const [] : [action],
  );
}
