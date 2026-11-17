import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/debug_feature/scale_debug_view.dart';
import 'package:reaprime/src/models/device/device.dart' as device;
import 'package:reaprime/src/models/device/scale.dart';
import 'package:shadcn_ui/shadcn_ui.dart' hide Scale;

import '../helpers/test_scale.dart';

class _FailingScale extends TestScale implements ScaleSnapshotHandoff {
  _FailingScale() : super(initialState: device.ConnectionState.discovered);

  var connectCalls = 0;
  var snapshotsActive = false;

  @override
  Future<void> onConnect() async {
    connectCalls++;
    if (connectCalls == 1) throw StateError('gatt status 133');
  }

  @override
  void activateSnapshots() => snapshotsActive = true;
}

void main() {
  testWidgets('failed connect is shown as a retryable state', (tester) async {
    final scale = _FailingScale();
    addTearDown(scale.dispose);
    final errors = <FlutterErrorDetails>[];
    final previous = FlutterError.onError;
    FlutterError.onError = errors.add;
    addTearDown(() => FlutterError.onError = previous);

    await tester.pumpWidget(ShadApp(home: ScaleDebugView(scale: scale)));
    await tester.pump();

    expect(errors, isEmpty);
    expect(find.text('Unable to connect to scale'), findsOneWidget);
    expect(find.text('Retry'), findsOneWidget);

    await tester.tap(find.text('Retry'));
    await tester.pump();

    expect(errors, isEmpty);
    expect(scale.connectCalls, 2);
    expect(scale.snapshotsActive, isTrue);
    expect(find.text('Unable to connect to scale'), findsNothing);
  });
}
