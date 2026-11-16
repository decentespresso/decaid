import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/app.dart';
import 'package:reaprime/src/settings/settings_controller.dart';
import 'package:reaprime/src/webui_support/webui_service.dart';
import 'package:reaprime/src/webui_support/webui_storage.dart';

import '../helpers/mock_settings_service.dart';

class _Storage extends WebUIStorage {
  _Storage() : super(SettingsController(MockSettingsService()));

  @override
  WebUISkin get defaultSkin =>
      WebUISkin(id: 'local', name: 'Local', path: '/local');
}

class _Service extends WebUIService {
  final ready = Completer<void>();

  @override
  Future<void> serveFolderAtPath(String path, {int port = 3000}) =>
      ready.future;
}

void main() {
  for (final restart in [false, true]) {
    testWidgets(
      'late startup serving cannot open skin after owner ${restart ? 'restart' : 'disposal'}',
      (tester) async {
        BuildContext? owner;
        var opens = 0;
        final navigatorKey = GlobalKey<NavigatorState>();
        Widget app(Key key) => MaterialApp(
          navigatorKey: navigatorKey,
          home: Builder(
            key: key,
            builder: (context) {
              owner = context;
              return const SizedBox();
            },
          ),
        );
        await tester.pumpWidget(app(UniqueKey()));
        final oldOwner = owner!;
        final navigator = navigatorKey.currentState!;
        final service = _Service();
        final opening = openStartupSkin(
          service: service,
          storage: _Storage(),
          isCurrent: () =>
              oldOwner.mounted &&
              navigator.mounted &&
              identical(navigator, navigatorKey.currentState),
          openSkin: () => opens++,
        );
        if (restart) {
          await tester.pumpWidget(app(UniqueKey()));
        } else {
          await tester.pumpWidget(const SizedBox());
        }
        expect(oldOwner.mounted, isFalse);
        service.ready.complete();
        await opening;
        expect(opens, 0);
        await tester.pumpWidget(const SizedBox());
      },
    );
  }

  test('active startup owner opens skin when serving completes', () async {
    final service = _Service();
    var opens = 0;
    final opening = openStartupSkin(
      service: service,
      storage: _Storage(),
      isCurrent: () => true,
      openSkin: () => opens++,
    );
    expect(opens, 0);
    service.ready.complete();
    await opening;
    expect(opens, 1);
  });
}
