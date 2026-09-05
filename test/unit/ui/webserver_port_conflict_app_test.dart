import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/ui/webserver_port_conflict_app.dart';

void main() {
  testWidgets('names the port and offers both actions', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: WebServerPortConflictScreen(
          port: 8080,
          probe: (_) async => false,
        ),
      ),
    );

    expect(find.text('Another Decaid app is running'), findsOneWidget);
    expect(find.textContaining('Port 8080 is already in use'), findsOneWidget);
    expect(find.text('Check again'), findsOneWidget);
    expect(find.text('Close this app'), findsOneWidget);
  });

  testWidgets('says the port is still in use when the probe says so', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: WebServerPortConflictScreen(
          port: 8080,
          probe: (_) async => false,
        ),
      ),
    );
    await tester.tap(find.text('Check again'));
    await tester.pumpAndSettle();

    expect(find.textContaining('is still in use'), findsOneWidget);
  });

  testWidgets('says the port is free when the probe says so', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: WebServerPortConflictScreen(port: 8080, probe: (_) async => true),
      ),
    );
    await tester.tap(find.text('Check again'));
    await tester.pumpAndSettle();

    expect(find.textContaining('is free now'), findsOneWidget);
  });

  testWidgets('asks about the port it was given', (tester) async {
    final asked = <int>[];
    await tester.pumpWidget(
      MaterialApp(
        home: WebServerPortConflictScreen(
          port: 4001,
          probe: (p) async {
            asked.add(p);
            return false;
          },
        ),
      ),
    );
    await tester.tap(find.text('Check again'));
    await tester.pumpAndSettle();

    expect(asked, [4001]);
  });
}
