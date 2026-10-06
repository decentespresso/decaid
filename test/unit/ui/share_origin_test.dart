import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/ui/share_origin.dart';

void main() {
  testWidgets('share origin matches the initiating rendered widget', (
    tester,
  ) async {
    final key = GlobalKey();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(child: SizedBox(key: key, width: 120, height: 40)),
        ),
      ),
    );
    final origin = shareOriginFor(key.currentContext!);
    expect(origin, tester.getRect(find.byKey(key)));
    expect(origin.isEmpty, isFalse);
  });

  testWidgets('share origin clips partially offscreen widget to the view', (
    tester,
  ) async {
    final key = GlobalKey();
    await tester.pumpWidget(
      MaterialApp(
        home: Stack(
          children: [
            Positioned(
              left: -20,
              top: 10,
              child: SizedBox(key: key, width: 120, height: 40),
            ),
          ],
        ),
      ),
    );
    expect(
      shareOriginFor(key.currentContext!),
      const Rect.fromLTWH(0, 10, 100, 40),
    );
  });

  testWidgets('empty or offscreen bounds cannot become a share origin', (
    tester,
  ) async {
    final key = GlobalKey();
    await tester.pumpWidget(
      MaterialApp(
        home: Stack(
          children: [
            Positioned(
              left: -200,
              top: 10,
              child: SizedBox(key: key, width: 120, height: 40),
            ),
          ],
        ),
      ),
    );
    expect(() => shareOriginFor(key.currentContext!), throwsStateError);
    await tester.pumpWidget(
      MaterialApp(
        home: Center(child: SizedBox(key: key, width: 0, height: 0)),
      ),
    );
    expect(() => shareOriginFor(key.currentContext!), throwsStateError);
  });
}
