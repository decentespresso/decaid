import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/notifications/notification_center.dart';
import 'package:reaprime/src/notifications/native_notification.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  late SharedPreferences preferences;
  late NotificationCenter center;

  NativeNotification notice({
    String source = 'plugin',
    String id = 'condition',
    String message = 'Needs attention',
    NotificationNamespace namespace = NotificationNamespace.plugin,
    List<NotificationAction> actions = const [],
  }) => NativeNotification(
    namespace: namespace,
    sourceId: source,
    sourceName: source,
    id: id,
    message: message,
    actions: actions,
  );

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    preferences = await SharedPreferences.getInstance();
    center = NotificationCenter(preferences: preferences);
  });

  tearDown(() => center.dispose());

  test(
    'retains ordering, content, actions and read status across reconstruction',
    () async {
      await center.publish(
        notice(
          actions: [
            NotificationAction(
              id: 'help',
              label: 'Help',
              type: NotificationActionType.openExternalUrl,
              url: Uri.parse('https://example.com/help'),
            ),
          ],
        ),
      );
      await center.publish(notice(source: 'second'));
      await center.markRead(center.value);
      final restored = NotificationCenter(preferences: preferences);
      addTearDown(restored.dispose);
      expect(restored.value.map((entry) => entry.sourceId), [
        'plugin',
        'second',
      ]);
      expect(restored.unreadCount, 0);
      expect(restored.value.first.actions.single.url!.host, 'example.com');
      expect(restored.isConfirmed(restored.value.first), isFalse);
    },
  );

  test(
    'identical publications retain read state and position after restart',
    () async {
      await center.publish(notice());
      await center.publish(notice(source: 'second'));
      await center.markRead(center.value);
      final restored = NotificationCenter(preferences: preferences);
      addTearDown(restored.dispose);
      await restored.publish(notice());
      expect(restored.unreadCount, 0);
      expect(restored.value.first.sourceId, 'plugin');
      await restored.publish(notice(message: 'Changed'));
      expect(restored.unreadCount, 1);
      expect(restored.value.first.sourceId, 'plugin');
    },
  );

  test('opening marks only the captured content revisions read', () async {
    await center.publish(notice());
    final openingSnapshot = center.value;
    await center.publish(notice(message: 'Changed while opening'));
    await center.publish(notice(source: 'arrival'));
    await center.markRead(openingSnapshot);
    expect(center.unreadCount, 2);
    await center.markRead(center.value);
    expect(center.unreadCount, 0);
    await center.publish(notice(source: 'later'));
    expect(center.unreadCount, 1);
  });

  test('action changes mark a read notice unread', () async {
    await center.publish(notice());
    await center.markRead(center.value);
    await center.publish(
      notice(
        actions: [
          const NotificationAction(
            id: 'account',
            label: 'Sign In',
            type: NotificationActionType.openDecentAccount,
          ),
        ],
      ),
    );
    expect(center.unreadCount, 1);
  });

  test(
    'read changes preserve bindings but retirement invalidates stale actions',
    () async {
      final phases = <String>[];
      final binding = NotificationBinding(
        onAction: (_, phase) => phases.add(phase),
      );
      await center.publish(notice(), binding: binding);
      final ticket = center.activation(center.value.single);
      await center.markRead(center.value);
      expect(center.isCurrent(ticket), isTrue);
      center.retireSource(NotificationNamespace.plugin, 'plugin');
      expect(center.value, hasLength(1));
      expect(center.isConfirmed(center.value.single), isFalse);
      expect(center.isCurrent(ticket), isFalse);
      await center.publish(
        notice(),
        binding: NotificationBinding(onAction: (_, phase) => phases.add(phase)),
      );
      expect(center.isCurrent(ticket), isFalse);
      expect(center.unreadCount, 0);
    },
  );

  test(
    'user removal is durable, once-only and programmatic removal is silent',
    () async {
      final dismissals = <String>[];
      final binding = NotificationBinding(
        onDismissed: (entry) async => dismissals.add(entry.id),
      );
      await center.publish(notice(), binding: binding);
      final current = center.value.single;
      await center.dismissByUser(current);
      await center.dismissByUser(current);
      expect(dismissals, ['condition']);
      await center.publish(notice(), binding: binding);
      await center.removeSource(NotificationNamespace.plugin, 'plugin');
      expect(dismissals, ['condition']);
      final restored = NotificationCenter(preferences: preferences);
      addTearDown(restored.dispose);
      expect(restored.value, isEmpty);
    },
  );

  test('failed saves preserve publication, read and dismissal state', () async {
    var fail = false;
    final failing = NotificationCenter(save: (_) async => !fail);
    addTearDown(failing.dispose);
    await failing.publish(notice());
    final previous = failing.value;
    fail = true;
    await expectLater(
      failing.publish(notice(source: 'second')),
      throwsA(isA<NotificationStorageException>()),
    );
    await expectLater(
      failing.markRead(previous),
      throwsA(isA<NotificationStorageException>()),
    );
    await expectLater(
      failing.dismissByUser(previous.single),
      throwsA(isA<NotificationStorageException>()),
    );
    expect(failing.value, same(previous));
    expect(failing.unreadCount, 1);
    expect(failing.error, isNotNull);
    fail = false;
    await failing.markRead(previous);
    expect(failing.unreadCount, 0);
    expect(failing.error, isNull);
  });

  test(
    'corrupt or unknown snapshots are preserved and block destructive writes',
    () async {
      for (final raw in [
        'not JSON',
        '{"version":999,"notices":[]}',
        '{"version":1,"notices":[{}]}',
      ]) {
        await preferences.setString(NotificationCenter.storageKey, raw);
        final restored = NotificationCenter(preferences: preferences);
        expect(restored.error, isNotNull);
        await expectLater(
          restored.publish(notice()),
          throwsA(isA<NotificationStorageException>()),
        );
        expect(preferences.getString(NotificationCenter.storageKey), raw);
        restored.dispose();
      }
    },
  );

  test('serializes storage and exposes no unsaved mutations', () async {
    final saved = <Completer<bool>>[];
    final delayed = NotificationCenter(
      save: (_) {
        final completion = Completer<bool>();
        saved.add(completion);
        return completion.future;
      },
    );
    addTearDown(delayed.dispose);
    final first = delayed.publish(notice());
    final second = delayed.publish(notice(source: 'second'));
    await Future<void>.delayed(Duration.zero);
    expect(saved, hasLength(1));
    expect(delayed.value, isEmpty);
    saved.first.complete(true);
    await first;
    await Future<void>.delayed(Duration.zero);
    expect(delayed.value, hasLength(1));
    expect(saved, hasLength(2));
    saved.last.complete(true);
    await second;
    expect(delayed.value, hasLength(2));
  });

  test(
    'plugin saturation reserves the host entry and recovers after removal',
    () async {
      for (var source = 0; source < 4; source++) {
        for (var id = 0; id < 5; id++) {
          await center.publish(notice(source: '$source', id: '$id'));
        }
      }
      await expectLater(
        center.publish(notice(source: 'fifth')),
        throwsA(isA<NotificationCapacityException>()),
      );
      await center.publish(
        notice(source: 'updates', namespace: NotificationNamespace.host),
      );
      expect(center.value, hasLength(21));
      await center.removeSource(NotificationNamespace.plugin, '0');
      await center.publish(notice(source: 'fifth'));
      expect(center.value, hasLength(17));
    },
  );

  test('host and plugin IDs cannot collide', () async {
    await center.publish(notice(source: 'updates'));
    await center.publish(
      notice(source: 'updates', namespace: NotificationNamespace.host),
    );
    await center.removeSource(NotificationNamespace.plugin, 'updates');
    expect(center.value.single.namespace, NotificationNamespace.host);
  });

  test(
    'replacement content and its action binding become visible together',
    () async {
      final phases = <String>[];
      const action = NotificationAction(
        id: 'account',
        label: 'Sign In',
        type: NotificationActionType.openDecentAccount,
      );
      await center.publish(
        notice(actions: [action]),
        binding: NotificationBinding(onAction: (_, _) => phases.add('old')),
      );
      center.addListener(() {
        final current = center.value.single;
        if (current.message == 'Changed') {
          center.reportAction(
            center.activation(current),
            current.actions.single,
            'activated',
          );
        }
      });
      await center.publish(
        notice(message: 'Changed', actions: [action]),
        binding: NotificationBinding(onAction: (_, _) => phases.add('new')),
      );
      expect(phases, ['new']);
    },
  );
}
