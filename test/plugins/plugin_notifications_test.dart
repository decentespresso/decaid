import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/plugins/plugin_notifications.dart';

void main() {
  test(
    'validates plugin text, one approved action and credential-free HTTPS',
    () {
      final invalid = <dynamic>[
        null,
        {'id': '', 'message': 'Message'},
        {'id': 'a', 'message': ''},
        {'id': 'a', 'message': 'x' * 601},
        {
          'id': 'a',
          'message': 'Message',
          'action': {'type': 'execute'},
        },
        for (final type in ['downloadUpdate', 'openDecentAccount'])
          {
            'id': 'a',
            'message': 'Message',
            'action': {'id': 'action', 'label': 'Open', 'type': type},
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
          () => parsePluginNotification(
            pluginId: 'first',
            pluginName: 'First',
            payload: payload,
            canOpenAccount: false,
          ),
          throwsFormatException,
        );
      }
    },
  );

  test('account actions also require the account proxy permission', () {
    final notice = parsePluginNotification(
      pluginId: 'first',
      pluginName: 'First',
      payload: {
        'id': 'account',
        'message': 'Sign in',
        'action': {
          'id': 'signIn',
          'label': 'Sign In',
          'type': 'openDecentAccount',
        },
      },
      canOpenAccount: true,
    );
    expect(notice.actions.single.id, 'signIn');
    expect(notice.sourceId, 'first');
  });
}
