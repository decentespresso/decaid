import 'dart:async';

enum NotificationNamespace { plugin, host }

enum NotificationActionType {
  openDecentAccount,
  openExternalUrl,
  downloadUpdate,
}

class NotificationAction {
  const NotificationAction({
    required this.id,
    required this.label,
    required this.type,
    this.url,
  });

  final String id;
  final String label;
  final NotificationActionType type;
  final Uri? url;

  Map<String, dynamic> toJson() => {
    'id': id,
    'label': label,
    'type': type.name,
    if (url != null) 'url': url.toString(),
  };

  factory NotificationAction.fromJson(Map<String, dynamic> json) {
    final type = NotificationActionType.values.byName(json['type'] as String);
    final rawUrl = json['url'];
    if (type != NotificationActionType.openExternalUrl && rawUrl != null) {
      throw const FormatException('Unexpected notification URL');
    }
    final url = rawUrl == null
        ? null
        : Uri.parse(notificationText(rawUrl, 2048));
    if ((type == NotificationActionType.openExternalUrl && url == null) ||
        (url != null &&
            (url.scheme != 'https' ||
                !url.hasAuthority ||
                url.host.isEmpty ||
                url.userInfo.isNotEmpty))) {
      throw const FormatException(
        'Notification links require credential-free HTTPS',
      );
    }
    return NotificationAction(
      id: notificationText(json['id'], 128),
      label: notificationText(json['label'], 40),
      type: type,
      url: url,
    );
  }
}

class NativeNotification {
  NativeNotification({
    required this.namespace,
    required this.sourceId,
    required this.sourceName,
    required this.id,
    required this.message,
    List<NotificationAction> actions = const [],
    this.revision = 0,
    this.read = false,
  }) : actions = List.unmodifiable(actions);

  final NotificationNamespace namespace;
  final String sourceId;
  final String sourceName;
  final String id;
  final String message;
  final List<NotificationAction> actions;
  final int revision;
  final bool read;

  (NotificationNamespace, String, String) get key => (namespace, sourceId, id);

  NativeNotification withState({int? revision, bool? read}) =>
      NativeNotification(
        namespace: namespace,
        sourceId: sourceId,
        sourceName: sourceName,
        id: id,
        message: message,
        actions: actions,
        revision: revision ?? this.revision,
        read: read ?? this.read,
      );

  Map<String, dynamic> toJson() => {
    'namespace': namespace.name,
    'sourceId': sourceId,
    'sourceName': sourceName,
    'id': id,
    'message': message,
    'actions': actions.map((action) => action.toJson()).toList(),
    'revision': revision,
    'read': read,
  };

  factory NativeNotification.fromJson(Map<String, dynamic> json) {
    final namespace = NotificationNamespace.values.byName(
      json['namespace'] as String,
    );
    final revision = json['revision'];
    final read = json['read'];
    if (revision is! int || revision < 1 || read is! bool) {
      throw const FormatException('Invalid notification state');
    }
    final actions = (json['actions'] as List)
        .map(
          (action) => NotificationAction.fromJson(
            Map<String, dynamic>.from(action as Map),
          ),
        )
        .toList();
    if (namespace == NotificationNamespace.plugin &&
        (actions.length > 1 ||
            actions.any(
              (action) => action.type == NotificationActionType.downloadUpdate,
            ))) {
      throw const FormatException('Invalid plugin actions');
    }
    return NativeNotification(
      namespace: namespace,
      sourceId: notificationText(json['sourceId'], 128),
      sourceName: notificationText(json['sourceName'], 256),
      id: notificationText(json['id'], 128),
      message: notificationText(
        json['message'],
        namespace == NotificationNamespace.plugin ? 600 : 2048,
      ),
      actions: actions,
      revision: revision,
      read: read,
    );
  }
}

class NotificationBinding {
  NotificationBinding({
    this.owner,
    this.confirmed = true,
    this.onAction,
    this.onActivate,
    this.onDismissed,
    bool Function()? isAlive,
  }) : isAlive = isAlive ?? (() => true);

  final void Function(NotificationAction, String)? onAction;
  final Future<void> Function(NotificationAction)? onActivate;
  final Object? owner;
  final bool confirmed;
  final FutureOr<void> Function(NativeNotification)? onDismissed;
  final bool Function() isAlive;
}

class NotificationActivation {
  const NotificationActivation(this.notice, this.binding);

  final NativeNotification notice;
  final NotificationBinding? binding;
}

String notificationText(dynamic value, int maxLength) {
  if (value is! String ||
      value.trim().isEmpty ||
      value.length > maxLength ||
      RegExp(r'[\x00-\x08\x0b-\x1f\x7f]').hasMatch(value)) {
    throw const FormatException('Invalid notification text');
  }
  return value;
}
