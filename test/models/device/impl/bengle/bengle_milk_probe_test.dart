import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/models/device/device.dart';
import 'package:reaprime/src/models/device/impl/bengle/bengle_milk_probe.dart';
import 'package:reaprime/src/models/device/impl/bengle/mock_bengle.dart';
import 'package:reaprime/src/models/device/machine.dart';

void main() {
  group('BengleMilkProbe adapter', () {
    late MockBengle bengle;
    late BengleMilkProbe probe;

    setUp(() async {
      bengle = MockBengle();
      await bengle.onConnect();
      probe = BengleMilkProbe(bengle: bengle);
      await probe.onConnect();
    });

    tearDown(() async {
      await probe.disconnect();
      await bengle.onDisconnect();
    });

    test('deviceId is derived from machine deviceId', () {
      expect(probe.deviceId, equals('${bengle.deviceId}-milkprobe'));
    });

    test('connectionState reflects probeAttached', () async {
      final initial = await probe.connectionState.first;
      expect(initial, ConnectionState.connected);

      bengle.setProbeAttached(false);
      final after = await probe.connectionState.firstWhere(
        (s) => s == ConnectionState.disconnected,
      );
      expect(after, ConnectionState.disconnected);
    });

    test('data emits temperature frames while steaming', () async {
      await bengle.requestState(MachineState.steam);
      await bengle.setStopAtTemperatureTarget(0.0);
      final sample = await probe.data.firstWhere(
        (m) => m['temperature'] is num,
      );
      expect(sample['timestamp'], isA<String>());
      expect((sample['temperature'] as num).toDouble(), greaterThan(0));
    });

    test('info exposes temperature channel', () {
      expect(
        probe.info.dataChannels.map((c) => c.key),
        contains('temperature'),
      );
    });
  });
}
