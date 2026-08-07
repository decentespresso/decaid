import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/models/device/device.dart';
import 'package:reaprime/src/models/device/impl/mock_scale/mock_scale.dart';
import 'package:reaprime/src/models/device/scale.dart';

void main() {
  late MockScale scale;

  setUp(() {
    scale = MockScale();
  });

  group('MockScale controllable behavior', () {
    test('emits weight snapshots by default', () async {
      final snapshot = await scale.currentSnapshot.first.timeout(
        Duration(seconds: 2),
      );
      expect(snapshot, isA<ScaleSnapshot>());
      expect(snapshot.weight, isNotNull);
    });

    test('simulateDataStall stops weight emission', () async {
      // Verify data flowing first
      await scale.currentSnapshot.first.timeout(Duration(seconds: 2));

      scale.simulateDataStall();

      final completer = Completer<bool>();
      final sub = scale.currentSnapshot.listen((_) {
        if (!completer.isCompleted) completer.complete(false);
      });

      await Future.delayed(Duration(milliseconds: 600));
      if (!completer.isCompleted) completer.complete(true);

      final stalled = await completer.future;
      await sub.cancel();
      expect(stalled, isTrue, reason: 'Expected no snapshots during stall');
    });

    test('simulateResume restarts weight emission after stall', () async {
      scale.simulateDataStall();
      await Future.delayed(Duration(milliseconds: 300));

      scale.simulateResume();

      final snapshot = await scale.currentSnapshot.first.timeout(
        Duration(seconds: 2),
      );
      expect(snapshot, isA<ScaleSnapshot>());
    });

    test('simulateDisconnect emits disconnected state', () async {
      scale.simulateDisconnect();

      final state = await scale.connectionState.first;
      expect(state, ConnectionState.disconnected);
    });

    test('simulateDisconnect stops weight emission', () async {
      await scale.currentSnapshot.first.timeout(Duration(seconds: 2));

      scale.simulateDisconnect();

      final completer = Completer<bool>();
      final sub = scale.currentSnapshot.listen((_) {
        if (!completer.isCompleted) completer.complete(false);
      });

      await Future.delayed(Duration(milliseconds: 600));
      if (!completer.isCompleted) completer.complete(true);

      final stalled = await completer.future;
      await sub.cancel();
      expect(stalled, isTrue, reason: 'Expected no snapshots after disconnect');
    });

    test(
      'connectionState starts as discovered, connects via onConnect',
      () async {
        // A simulated scale, like a real one, is not "connected" until it is
        // actually connected through the controller.
        expect(await scale.connectionState.first, ConnectionState.discovered);
        await scale.onConnect();
        expect(await scale.connectionState.first, ConnectionState.connected);
      },
    );
  });
}
