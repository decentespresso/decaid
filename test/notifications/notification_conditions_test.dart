import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/notifications/native_notification.dart';
import 'package:reaprime/src/notifications/notification_actions.dart';
import 'package:reaprime/src/notifications/notification_center.dart';
import 'package:reaprime/src/notifications/notification_overlay.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

void main() {
  late NotificationCenter center;
  late NotificationActions actions;

  setUp(() {
    center = NotificationCenter();
    actions = NotificationActions(center: center, onOpenAccount: () {});
  });

  tearDown(() {
    actions.dispose();
    center.dispose();
  });

  Future<void> publish(String id, String message) async {
    await TestWidgetsFlutterBinding.instance.runAsync(
      () => center.publish(
        NativeNotification(
          namespace: NotificationNamespace.plugin,
          sourceId: 'uploader',
          sourceName: 'Shot Upload',
          id: id,
          message: message,
        ),
      ),
    );
  }

  Future<void> mount(WidgetTester tester) async {
    await tester.pumpWidget(
      ShadApp(
        home: Scaffold(
          floatingActionButton: NotificationBell(
            center: center,
            actions: actions,
          ),
          body: SizedBox(
            width: 140,
            height: 140,
            child: NotificationDestination(center: center, actions: actions),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> tap(WidgetTester tester, Finder finder) async {
    await tester.runAsync(() async {
      await tester.tap(finder);
      await center.settled;
    });
    await tester.pumpAndSettle();
  }

  testWidgets(
    'compact snapshot survives reading and excludes already read conditions',
    (tester) async {
      await publish('old', 'Already read condition');
      await tester.runAsync(() => center.markRead(center.value));
      await publish('pause', 'Shot uploads paused');
      await mount(tester);
      await tap(tester, find.byType(FloatingActionButton));
      expect(center.unreadCount, 0);
      expect(find.byType(FloatingActionButton), findsNothing);
      expect(find.text('Shot uploads paused'), findsOneWidget);
      expect(find.text('Already read condition'), findsNothing);
      expect(find.text('Go to notification center'), findsOneWidget);
      expect(find.byIcon(LucideIcons.trash2), findsNothing);
      expect(center.value, hasLength(2));
      await tap(tester, find.byTooltip('Close'));
      await tap(tester, find.text('Notifications'));
      expect(find.text('Shot uploads paused'), findsOneWidget);
      expect(find.text('Already read condition'), findsOneWidget);
      expect(find.text('Go to notification center'), findsNothing);
      expect(find.byIcon(LucideIcons.trash2), findsNothing);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'new and revised arrivals stay unread outside the compact snapshot',
    (tester) async {
      await publish('pause', 'Original pause');
      await mount(tester);
      await tap(tester, find.byType(FloatingActionButton));
      await publish('new', 'New condition');
      await publish('pause', 'Changed pause');
      await tester.pumpAndSettle();
      expect(center.unreadCount, 2);
      expect(find.text('New condition'), findsNothing);
      expect(find.text('Changed pause'), findsNothing);
      await tap(tester, find.byTooltip('Close'));
      await tap(tester, find.byType(FloatingActionButton));
      expect(find.text('New condition'), findsOneWidget);
      expect(find.text('Changed pause'), findsOneWidget);
      expect(center.unreadCount, 0);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('compact view opens the full center without stacking dialogs', (
    tester,
  ) async {
    await publish('old', 'Older condition');
    await tester.runAsync(() => center.markRead(center.value));
    await publish('pause', 'Current pause');
    await mount(tester);
    await tap(tester, find.byType(FloatingActionButton));
    await tap(tester, find.text('Go to notification center'));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 400)),
    );
    await tester.pumpAndSettle();
    expect(find.byType(NotificationOverlay), findsOneWidget);
    expect(find.text('Older condition'), findsOneWidget);
    expect(find.text('Current pause'), findsOneWidget);
    expect(find.text('Go to notification center'), findsNothing);
    await tap(tester, find.byTooltip('Close'));
    expect(find.byType(NotificationOverlay), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
    'identical publication stays read and resolution permits a new occurrence',
    (tester) async {
      await publish('pause', 'Shot uploads paused');
      await mount(tester);
      await tap(tester, find.byType(FloatingActionButton));
      await tap(tester, find.byTooltip('Close'));
      await publish('pause', 'Shot uploads paused');
      await tester.pumpAndSettle();
      expect(find.byType(FloatingActionButton), findsNothing);
      await tester.runAsync(
        () => center.removeSource(
          NotificationNamespace.plugin,
          'uploader',
          'pause',
        ),
      );
      expect(center.value, isEmpty);
      await publish('pause', 'Shot uploads paused');
      await tester.pumpAndSettle();
      expect(center.unreadCount, 1);
      expect(find.byType(FloatingActionButton), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    },
  );
}
