import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/plugins/plugin_notifications.dart';

void main() {
  late PluginNotificationCenter center;
  final actions = <Map<String, dynamic>>[];
  final dismissals = <String>[];

  setUp(() {
    center = PluginNotificationCenter();
    actions.clear();
    dismissals.clear();
  });
  tearDown(() => center.dispose());

  void show(String plugin, String id, {Map<String, dynamic>? action}) {
    center.show(
      pluginId: plugin,
      pluginName: plugin,
      payload: {
        'id': id,
        'message': 'A condition needs attention',
        'action': action,
      },
      canOpenAccount: true,
      onAction: actions.add,
      onDismissed: (event) => dismissals.add('$plugin:${event['id']}'),
    );
  }

  test('updates and dismissals are scoped to the originating plugin', () {
    show('first', 'same');
    show('second', 'same');
    final old = center.value.first;
    show('first', 'same');
    expect(center.value.map((notice) => notice.pluginId), ['first', 'second']);
    expect(center.isCurrent(old), isFalse);
    center.dismissByUser(old);
    expect(center.value.length, 2);
    center.dismiss('first', 'same');
    expect(center.value.single.pluginId, 'second');
    center.dismiss('second');
    expect(center.value, isEmpty);
    expect(dismissals, isEmpty);
  });

  test(
    'user dismissal removes the notice before reporting once without an action',
    () {
      show('first', 'same');
      show('second', 'same');
      final notice = center.value.first;
      center.addListener(() => expect(dismissals, isEmpty));
      center.dismissByUser(notice);
      expect(center.value.single.pluginId, 'second');
      expect(dismissals, ['first:same']);
      center.dismissByUser(notice);
      expect(dismissals, ['first:same']);
      expect(actions, isEmpty);
    },
  );

  test('queue limits do not evict existing plugin notifications', () {
    for (var plugin = 0; plugin < 5; plugin++) {
      for (var id = 0; id < 6; id++) {
        show('$plugin', '$id');
      }
    }
    expect(center.value.length, 20);
    expect(center.value.where((notice) => notice.pluginId == '0').length, 5);
    expect(center.value.where((notice) => notice.pluginId == '4'), isEmpty);
    show('0', '0');
    expect(center.value.length, 20);
    expect(center.value.first.id, '0');
  });

  test(
    'validates text, actions and HTTPS destinations at the host boundary',
    () {
      final invalid = <Map<String, dynamic>>[
        {'id': '', 'message': 'Message'},
        {'id': 'a', 'message': ''},
        {'id': 'a', 'message': 'x' * 601},
        {
          'id': 'a',
          'message': 'Message',
          'action': {'type': 'execute'},
        },
        for (final url in [
          'javascript:alert(1)',
          'file:///tmp/file',
          'http://example.com/',
          'https://user:secret@example.com/',
          'https:///relative',
        ])
          {
            'id': 'a',
            'message': 'Message',
            'action': {
              'id': 'link',
              'label': 'Open',
              'type': 'openExternalUrl',
              'url': url,
            },
          },
      ];
      for (final payload in invalid) {
        expect(
          () => center.show(
            pluginId: 'first',
            pluginName: 'First',
            payload: payload,
            canOpenAccount: true,
            onAction: actions.add,
          ),
          throwsFormatException,
        );
      }
      expect(center.value, isEmpty);
    },
  );

  test('opening account settings also requires account-proxy permission', () {
    expect(
      () => center.show(
        pluginId: 'first',
        pluginName: 'First',
        payload: {
          'id': 'a',
          'message': 'Message',
          'action': {
            'id': 'login',
            'label': 'Sign In',
            'type': 'openDecentAccount',
          },
        },
        canOpenAccount: false,
        onAction: actions.add,
      ),
      throwsFormatException,
    );
  });

  test('action events contain only plugin-local identifiers and phase', () {
    show(
      'first',
      'a',
      action: {
        'id': 'link',
        'label': 'Open',
        'type': 'openExternalUrl',
        'url': 'https://example.com/help',
      },
    );
    center.value.single.reportAction('returned');
    expect(actions.single, {
      'id': 'a',
      'actionId': 'link',
      'phase': 'returned',
    });
  });
}
