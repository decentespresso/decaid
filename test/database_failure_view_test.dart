import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/database_failure_view.dart';

Widget host(Widget child) => MaterialApp(home: child);

void main() {
  testWidgets('explains the database could not be opened and data was kept', (
    tester,
  ) async {
    await tester.pumpWidget(
      host(
        const DatabaseFailureView(
          logFilePath: '/tmp/support/log.txt',
          detail: 'StateError: incompatible column',
        ),
      ),
    );

    expect(find.textContaining('could not be safely opened'), findsOneWidget);
    expect(find.textContaining('left in place'), findsOneWidget);
    expect(
      find.textContaining('StateError: incompatible column'),
      findsOneWidget,
    );
    expect(find.textContaining('/tmp/support/log.txt'), findsOneWidget);
  });

  testWidgets('offers no destructive reset or retry action', (tester) async {
    await tester.pumpWidget(
      host(const DatabaseFailureView(logFilePath: '/tmp/support/log.txt')),
    );

    expect(find.byType(TextButton), findsNothing);
    expect(find.byType(FilledButton), findsNothing);
    expect(find.byType(OutlinedButton), findsNothing);
    expect(find.textContaining('reset'), findsNothing);
    expect(find.textContaining('delete'), findsNothing);
    expect(find.textContaining('retry'), findsNothing);
  });

  testWidgets('DatabaseFailureApp renders a database-independent home', (
    tester,
  ) async {
    await tester.pumpWidget(
      const DatabaseFailureApp(logFilePath: '/tmp/support/log.txt'),
    );

    expect(find.textContaining('could not be safely opened'), findsOneWidget);
    expect(find.textContaining('left in place'), findsOneWidget);
  });

  testWidgets('all content is reachable on a compact screen with large text', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 568);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    const textScaler = TextScaler.linear(2);
    const viewPadding = EdgeInsets.all(24);
    await tester.pumpWidget(
      MaterialApp(
        home: MediaQuery(
          data: const MediaQueryData(
            textScaler: textScaler,
            padding: viewPadding,
          ),
          child: const DatabaseFailureView(
            logFilePath: '/data/user/0/net.tadel.reaprime/files/logs/log.txt',
            detail: 'StateError',
          ),
        ),
      ),
    );

    expect(tester.takeException(), isNull);
    expect(find.textContaining('could not be safely opened'), findsOneWidget);
    expect(find.byType(SingleChildScrollView), findsOneWidget);
    await tester.scrollUntilVisible(
      find.textContaining('assisted repair'),
      200,
      scrollable: find.descendant(
        of: find.byType(SingleChildScrollView),
        matching: find.byType(Scrollable),
      ),
    );
    expect(find.textContaining('assisted repair'), findsOneWidget);
    expect(find.textContaining('left in place'), findsOneWidget);
  });
}
