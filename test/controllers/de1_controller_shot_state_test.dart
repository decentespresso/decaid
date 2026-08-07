import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/controllers/de1_controller.dart';
import 'package:reaprime/src/controllers/device_controller.dart';
import 'package:reaprime/src/models/data/shot_state_event.dart';
import 'package:reaprime/src/models/device/device.dart';
import 'package:reaprime/src/models/device/machine.dart';
import 'package:reaprime/src/models/device/scan_filter.dart';

class _FakeDiscoveryService extends DeviceDiscoveryService {
  @override
  Stream<List<Device>> get devices => const Stream.empty();

  @override
  Future<void> initialize() async {}

  @override
  Future<void> scanForDevices({ScanFilter? filter}) async {}
}

De1Controller _makeController() {
  return De1Controller(controller: DeviceController([_FakeDiscoveryService()]));
}

ShotStateEvent _pouringEvent() {
  return ShotStateEvent(
    event: 'state',
    timestamp: DateTime.now(),
    shotId: 'shot-1',
    state: ShotState.pouring,
    machineState: MachineState.espresso,
    machineSubstate: MachineSubstate.pouring,
    profileFrame: 0,
    scaleConnected: true,
    scaleLost: false,
    machineHasAutonomousSAW: false,
  );
}

void main() {
  group('De1Controller.shotState', () {
    test('is seeded with an idle state frame', () async {
      final controller = _makeController();

      final first = await controller.shotState.first;

      expect(first.event, 'state');
      expect(first.state, ShotState.idle);
      expect(first.shotId, isNull);
    });

    test('replays the latest event to late subscribers', () async {
      final controller = _makeController();
      final published = _pouringEvent();

      controller.publishShotEvent(published);

      final first = await controller.shotState.first;
      expect(first.state, ShotState.pouring);
      expect(first.shotId, 'shot-1');
    });

    test('currentShotState exposes the latest event synchronously', () {
      final controller = _makeController();
      expect(controller.currentShotState.state, ShotState.idle);

      controller.publishShotEvent(_pouringEvent());
      expect(controller.currentShotState.state, ShotState.pouring);
    });
  });

  group('De1Controller stop intent', () {
    test('records and consumes an intent exactly once', () {
      final controller = _makeController();

      controller.recordStopIntent(ShotDecisionReason.apiStop);

      expect(controller.consumeStopIntent(), ShotDecisionReason.apiStop);
      expect(
        controller.consumeStopIntent(),
        isNull,
        reason: 'a consumed intent must not be attributed twice',
      );
    });

    test('returns null when no intent was recorded', () {
      final controller = _makeController();
      expect(controller.consumeStopIntent(), isNull);
    });

    test('expires stale intents beyond the attribution window', () {
      fakeAsync((async) {
        final controller = _makeController();

        controller.recordStopIntent(ShotDecisionReason.appStop);
        async.elapse(const Duration(seconds: 6));

        expect(
          controller.consumeStopIntent(),
          isNull,
          reason:
              'a stop intent older than the window must not be '
              'attributed to a later, unrelated shot end',
        );
      });
    });

    test('a fresh intent within the window is attributed', () {
      fakeAsync((async) {
        final controller = _makeController();

        controller.recordStopIntent(ShotDecisionReason.appStop);
        async.elapse(const Duration(seconds: 2));

        expect(controller.consumeStopIntent(), ShotDecisionReason.appStop);
      });
    });
  });
}
