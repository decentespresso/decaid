import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/controllers/scan_state_guardian.dart';
import 'package:reaprime/src/models/adapter_state.dart';

import '../helpers/mock_device_discovery_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late MockBleDiscoveryService bleService;
  late ScanStateGuardian guardian;

  setUp(() {
    bleService = MockBleDiscoveryService();
    guardian = ScanStateGuardian(bleService: bleService);
  });

  tearDown(() {
    guardian.dispose();
    bleService.dispose();
  });

  test(
    'emits adapterTurnedOff when adapter state changes to poweredOff',
    () async {
      bleService.setAdapterState(AdapterState.poweredOn);
      await Future.delayed(Duration.zero);

      expectLater(guardian.events, emits(ScanStateEvent.adapterTurnedOff));
      bleService.setAdapterState(AdapterState.poweredOff);
    },
  );

  test(
    'emits adapterTurnedOn when adapter state changes to poweredOn',
    () async {
      bleService.setAdapterState(AdapterState.poweredOff);
      await Future.delayed(Duration.zero);

      expectLater(guardian.events, emits(ScanStateEvent.adapterTurnedOn));
      bleService.setAdapterState(AdapterState.poweredOn);
    },
  );

  test('emits scanStateStale on app resume', () async {
    expectLater(guardian.events, emits(ScanStateEvent.scanStateStale));
    guardian.onAppResumed();
  });
}
