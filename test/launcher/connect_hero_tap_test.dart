import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/launcher/widgets/connect_device_hero_card.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

void main() {
  testWidgets('ConnectDeviceHeroCard fires onScan when tapped', (tester) async {
    var tapped = 0;
    await tester.pumpWidget(
      ShadApp(
        home: Scaffold(body: ConnectDeviceHeroCard(onScan: () => tapped++)),
      ),
    );

    expect(find.text('Connect your machine'), findsOneWidget);
    final scanButton = tester.widget<ShadButton>(
      find.ancestor(
        of: find.text('Scan for devices'),
        matching: find.byType(ShadButton),
      ),
    );
    expect(scanButton.size, ShadButtonSize.lg);
    expect(find.byIcon(LucideIcons.radar), findsOneWidget);
    expect(find.byType(FittedBox), findsNothing);

    await tester.tap(find.text('Scan for devices'));
    await tester.pump();

    expect(tapped, 1);
  });
}
