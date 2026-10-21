import 'package:flutter/foundation.dart';

enum PluginNotificationActionType { openDecentAccount, openExternalUrl }

class PluginNotificationAction {
  const PluginNotificationAction._(this.id, this.label, this.type, this.url);

  final String id;
  final String label;
  final PluginNotificationActionType type;
  final Uri? url;
}

class PluginNotification {
  const PluginNotification._({
    required this.pluginId,
    required this.pluginName,
    required this.id,
    required this.message,
    required this.action,
    required void Function(String) onAction,
    required VoidCallback onDismissed,
  }) : _onAction = onAction,
       _onDismissed = onDismissed;

  final String pluginId;
  final String pluginName;
  final String id;
  final String message;
  final PluginNotificationAction? action;
  final void Function(String) _onAction;
  final VoidCallback _onDismissed;

  void reportAction(String phase) => _onAction(phase);
}

class PluginNotificationCenter extends ValueNotifier<List<PluginNotification>> {
  PluginNotificationCenter() : super(const []);

  static String _text(dynamic value, int maxLength) {
    if (value is! String ||
        value.trim().isEmpty ||
        value.length > maxLength ||
        RegExp(r'[\x00-\x08\x0b-\x1f\x7f]').hasMatch(value)) {
      throw const FormatException('Invalid notification text');
    }
    return value;
  }

  static PluginNotificationAction? _action(dynamic value, bool canOpenAccount) {
    if (value == null) return null;
    if (value is! Map) {
      throw const FormatException('Invalid notification action');
    }
    final id = _text(value['id'], 128);
    final label = _text(value['label'], 40);
    final type = switch (value['type']) {
      'openDecentAccount' when canOpenAccount =>
        PluginNotificationActionType.openDecentAccount,
      'openExternalUrl' => PluginNotificationActionType.openExternalUrl,
      _ => throw const FormatException('Notification action is not permitted'),
    };
    Uri? url;
    if (type == PluginNotificationActionType.openExternalUrl) {
      url = Uri.tryParse(_text(value['url'], 2048));
      if (url == null ||
          url.scheme != 'https' ||
          !url.hasAuthority ||
          url.host.isEmpty ||
          url.userInfo.isNotEmpty) {
        throw const FormatException(
          'Notification links require HTTPS without credentials',
        );
      }
    }
    return PluginNotificationAction._(id, label, type, url);
  }

  void show({
    required String pluginId,
    required String pluginName,
    required dynamic payload,
    required bool canOpenAccount,
    required void Function(Map<String, dynamic>) onAction,
    void Function(Map<String, dynamic>)? onDismissed,
  }) {
    if (payload is! Map) throw const FormatException('Invalid notification');
    final id = _text(payload['id'], 128);
    final message = _text(payload['message'], 600);
    final action = _action(payload['action'], canOpenAccount);
    final index = value.indexWhere(
      (notice) => notice.pluginId == pluginId && notice.id == id,
    );
    if (index == -1 &&
        (value.length >= 20 ||
            value.where((notice) => notice.pluginId == pluginId).length >= 5)) {
      return;
    }
    late final PluginNotification notice;
    notice = PluginNotification._(
      pluginId: pluginId,
      pluginName: pluginName,
      id: id,
      message: message,
      action: action,
      onAction: (phase) {
        if (action == null || !isCurrent(notice)) return;
        onAction({'id': id, 'actionId': action.id, 'phase': phase});
      },
      onDismissed: () => onDismissed?.call({'id': id}),
    );
    value = List.unmodifiable(
      index < 0
          ? [...value, notice]
          : [
              for (var i = 0; i < value.length; i++)
                if (i == index) notice else value[i],
            ],
    );
  }

  bool isCurrent(PluginNotification notice) => value.contains(notice);

  void dismissByUser(PluginNotification notice) {
    if (!isCurrent(notice)) return;
    dismiss(notice.pluginId, notice.id);
    notice._onDismissed();
  }

  void dismiss(String pluginId, [String? id]) {
    value = List.unmodifiable(
      value.where(
        (notice) =>
            notice.pluginId != pluginId || (id != null && notice.id != id),
      ),
    );
  }
}
