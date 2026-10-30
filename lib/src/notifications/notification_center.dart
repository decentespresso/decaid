import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'native_notification.dart';

class NotificationCapacityException implements Exception {}

class NotificationStorageException implements Exception {
  const NotificationStorageException();
}

class NotificationCenter extends ValueNotifier<List<NativeNotification>> {
  NotificationCenter({
    SharedPreferences? preferences,
    Future<bool> Function(String)? save,
  }) : _save = save ?? ((snapshot) => _persist(preferences, snapshot)),
       super(const []) {
    try {
      final raw = preferences?.getString(storageKey);
      if (raw == null) return;
      final data = jsonDecode(raw) as Map<String, dynamic>;
      if (data['version'] != 1) {
        throw const FormatException('Unknown notification snapshot');
      }
      final notices = (data['notices'] as List)
          .map(
            (entry) => NativeNotification.fromJson(
              Map<String, dynamic>.from(entry as Map),
            ),
          )
          .toList();
      if (notices.map((notice) => notice.key).toSet().length !=
              notices.length ||
          notices
                  .where(
                    (notice) => notice.namespace == NotificationNamespace.host,
                  )
                  .length >
              1 ||
          notices
                  .where(
                    (notice) =>
                        notice.namespace == NotificationNamespace.plugin,
                  )
                  .length >
              20 ||
          notices.any(
            (notice) =>
                notice.namespace == NotificationNamespace.plugin &&
                notices
                        .where(
                          (entry) =>
                              entry.namespace == notice.namespace &&
                              entry.sourceId == notice.sourceId,
                        )
                        .length >
                    5,
          )) {
        throw const FormatException('Invalid notification snapshot capacity');
      }
      value = List.unmodifiable(notices);
      _revision = notices.fold(
        0,
        (highest, notice) =>
            notice.revision > highest ? notice.revision : highest,
      );
    } catch (_) {
      _restoreFailed = true;
      _error =
          'Saved notifications could not be loaded. Stored data was preserved.';
    }
  }

  static const storageKey = 'private.notificationCenter.v1';
  static Future<bool> _persist(
    SharedPreferences? preferences,
    String snapshot,
  ) async {
    if (preferences == null) return true;
    try {
      final saved = await preferences.setString(storageKey, snapshot);
      if (!saved) await preferences.reload();
      return saved;
    } catch (_) {
      await preferences.reload();
      rethrow;
    }
  }

  final Future<bool> Function(String) _save;
  Map<(NotificationNamespace, String, String), NotificationBinding> _bindings =
      {};
  Future<void> _queue = Future.value();
  bool _restoreFailed = false;
  int _revision = 0;
  String? _error;

  String? get error => _error;
  int get unreadCount => value.where((notice) => !notice.read).length;
  Future<void> get settled => _queue;

  Future<void> _serialize(Future<void> Function() operation) {
    final next = _queue.then((_) => operation());
    _queue = next.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return next;
  }

  Future<void> _commit(
    List<NativeNotification> notices, {
    VoidCallback? onSaved,
  }) async {
    try {
      if (_restoreFailed ||
          !await _save(
            jsonEncode({
              'version': 1,
              'notices': notices.map((notice) => notice.toJson()).toList(),
            }),
          )) {
        throw const NotificationStorageException();
      }
    } catch (_) {
      _error ??= 'Notifications could not be saved. Please try again.';
      notifyListeners();
      throw const NotificationStorageException();
    }
    _error = null;
    onSaved?.call();
    value = List.unmodifiable(notices);
  }

  Future<void> publish(
    NativeNotification incoming, {
    NotificationBinding? binding,
  }) => _serialize(() async {
    if (binding != null && !binding.isAlive()) return;
    var index = value.indexWhere((notice) => notice.key == incoming.key);
    if (index < 0 && incoming.namespace == NotificationNamespace.host) {
      index = value.indexWhere(
        (notice) =>
            notice.namespace == incoming.namespace &&
            notice.sourceId == incoming.sourceId,
      );
    }
    final previous = index < 0 ? null : value[index];
    if (previous == null) {
      final namespace = value.where(
        (notice) => notice.namespace == incoming.namespace,
      );
      if ((incoming.namespace == NotificationNamespace.host &&
              namespace.isNotEmpty) ||
          (incoming.namespace == NotificationNamespace.plugin &&
              (namespace.length >= 20 ||
                  namespace
                          .where(
                            (notice) => notice.sourceId == incoming.sourceId,
                          )
                          .length >=
                      5))) {
        throw NotificationCapacityException();
      }
    }
    final sameContent =
        previous != null &&
        previous.key == incoming.key &&
        previous.message == incoming.message &&
        listEquals(
          previous.actions
              .map((action) => jsonEncode(action.toJson()))
              .toList(),
          incoming.actions
              .map((action) => jsonEncode(action.toJson()))
              .toList(),
        );
    final notice = incoming.withState(
      revision: sameContent ? previous.revision : _revision + 1,
      read: sameContent && previous.read,
    );
    final notices = [
      if (index < 0) ...value,
      if (index < 0) notice,
      if (index >= 0)
        for (var i = 0; i < value.length; i++)
          if (i == index) notice else value[i],
    ];
    await _commit(
      notices,
      onSaved: () {
        if (notice.revision > _revision) _revision = notice.revision;
        final oldBinding = _bindings[notice.key];
        _bindings = {
          for (final entry in _bindings.entries)
            if (entry.key != notice.key &&
                notices.any((notice) => notice.key == entry.key))
              entry.key: entry.value,
          if (binding != null && binding.isAlive())
            notice.key:
                sameContent &&
                    oldBinding?.isAlive() == true &&
                    oldBinding?.confirmed == binding.confirmed &&
                    (identical(oldBinding, binding) ||
                        (binding.owner != null &&
                            oldBinding?.owner == binding.owner))
                ? oldBinding!
                : binding,
        };
      },
    );
  });

  Future<void> markRead(List<NativeNotification> snapshot) =>
      _serialize(() async {
        final revisions = {
          for (final notice in snapshot) notice.key: notice.revision,
        };
        final notices = value
            .map(
              (notice) => revisions[notice.key] == notice.revision
                  ? notice.withState(read: true)
                  : notice,
            )
            .toList();
        if (notices.every(
          (notice) =>
              notice.read ==
              value.firstWhere((entry) => entry.key == notice.key).read,
        )) {
          return;
        }
        await _commit(notices);
      });

  bool _matches(NativeNotification notice) => value.any(
    (entry) => entry.key == notice.key && entry.revision == notice.revision,
  );

  void bind(NativeNotification notice, NotificationBinding binding) {
    if (!_matches(notice) || !binding.isAlive()) return;
    _bindings = {..._bindings, notice.key: binding};
    notifyListeners();
  }

  bool isConfirmed(NativeNotification notice) =>
      _matches(notice) &&
      _bindings[notice.key]?.confirmed == true &&
      _bindings[notice.key]?.isAlive() == true;

  NotificationActivation activation(NativeNotification notice) =>
      NotificationActivation(notice, _bindings[notice.key]);

  bool isCurrent(NotificationActivation activation) =>
      isConfirmed(activation.notice) &&
      identical(_bindings[activation.notice.key], activation.binding);

  void reportAction(
    NotificationActivation activation,
    NotificationAction action,
    String phase,
  ) {
    if (isCurrent(activation)) {
      activation.binding!.onAction?.call(action, phase);
    }
  }

  void retireSource(NotificationNamespace namespace, String sourceId) {
    _bindings = Map.fromEntries(
      _bindings.entries.where(
        (entry) => entry.key.$1 != namespace || entry.key.$2 != sourceId,
      ),
    );
    notifyListeners();
  }

  Future<void> removeSource(
    NotificationNamespace namespace,
    String sourceId, [
    String? id,
  ]) => _serialize(() async {
    final removed = value
        .where(
          (notice) =>
              notice.namespace == namespace &&
              notice.sourceId == sourceId &&
              (id == null || notice.id == id),
        )
        .toList();
    if (removed.isEmpty) return;
    await _commit(value.where((notice) => !removed.contains(notice)).toList());
    _bindings = Map.fromEntries(
      _bindings.entries.where(
        (entry) => !removed.any((notice) => notice.key == entry.key),
      ),
    );
  });

  Future<void> dismissByUser(NativeNotification notice) => _serialize(() async {
    if (!_matches(notice)) return;
    final binding = _bindings[notice.key];
    await _commit(value.where((entry) => entry.key != notice.key).toList());
    _bindings = Map.fromEntries(
      _bindings.entries.where((entry) => entry.key != notice.key),
    );
    if (binding?.isAlive() == true) await binding!.onDismissed?.call(notice);
  });
}
