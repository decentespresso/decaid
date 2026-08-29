import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/build_info.dart';
import 'package:reaprime/src/controllers/device_controller.dart';
import 'package:reaprime/src/launcher/widgets/status_bar.dart';
import 'package:reaprime/src/webui_support/webui_service.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

import '../helpers/mock_de1_controller.dart';
import '../helpers/mock_scale_controller.dart';

void main() {
  testWidgets('shows the local fork provenance marker', (tester) async {
    final de1Controller = MockDe1Controller(controller: DeviceController([]));
    final scaleController = MockScaleController();

    await tester.pumpWidget(
      ShadApp(
        home: Scaffold(
          body: StatusBar(
            de1Controller: de1Controller,
            scaleController: scaleController,
            webUIService: WebUIService(),
          ),
        ),
      ),
    );
    await tester.pump();

    expect(
      find.text('LOCAL FORK · ${BuildInfo.branch}@${BuildInfo.commitShort}'),
      findsOneWidget,
    );
  });
}
