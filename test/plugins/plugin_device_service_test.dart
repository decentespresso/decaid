import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/controllers/device_controller.dart';
import 'package:reaprime/src/controllers/sensor_controller.dart';
import 'package:reaprime/src/models/device/device.dart';
import 'package:reaprime/src/models/device/sensor.dart';
import 'package:reaprime/src/plugins/plugin_device_service.dart';

void main() {
  test('registered plugin sensor joins inventory and publishes data', () async {
    final service = PluginDeviceService();
    final deviceController = DeviceController([service]);
    await deviceController.initialize();
    final sensorController = SensorController(controller: deviceController);
    addTearDown(() async {
      sensorController.dispose();
      deviceController.dispose();
      await service.dispose();
    });

    final operations = <PluginDeviceOperation>[];
    final registered = await service.register(
      pluginId: 'humidity.plugin',
      generation: 1,
      registrationHandle: 'registration-1',
      definition: {
        'driverId': 'humidity',
        'instanceId': 'office',
        'name': 'Office humidity',
        'vendor': 'Test',
        'dataChannels': [
          {'key': 'relativeHumidity', 'type': 'number', 'unit': '%RH'},
        ],
        'commands': [
          {'id': 'sampleNow'},
        ],
      },
      invoke: (operation, payload) async {
        operations.add(operation);
        return operation == PluginDeviceOperation.execute
            ? {'relativeHumidity': 53.1}
            : const {};
      },
    );

    final sensor = await sensorController.sensorRegistry
        .map((sensors) => sensors[registered.deviceId])
        .where((sensor) => sensor != null)
        .cast<Sensor>()
        .first;
    await sensor.connectionState
        .where((state) => state == ConnectionState.connected)
        .first;
    expect(deviceController.devices, contains(same(sensor)));
    expect(operations, [PluginDeviceOperation.connect]);

    final snapshot = sensor.data.first;
    service.publish(
      pluginId: 'humidity.plugin',
      generation: 1,
      registrationHandle: 'registration-1',
      snapshot: const {'relativeHumidity': 52.4},
    );
    expect(await snapshot, {'relativeHumidity': 52.4});
    expect(
      () => service.publish(
        pluginId: 'humidity.plugin',
        generation: 1,
        registrationHandle: 'registration-1',
        snapshot: const {'relativeHumidity': 'humid'},
      ),
      throwsA(isA<PluginDeviceException>()),
    );
    expect(await sensor.execute('sampleNow', null), {'relativeHumidity': 53.1});
    service.reportDisconnected(
      pluginId: 'humidity.plugin',
      generation: 1,
      registrationHandle: 'registration-1',
    );
    await sensor.connectionState
        .where((state) => state == ConnectionState.disconnected)
        .first;
    await expectLater(
      sensor.execute('sampleNow', null),
      throwsA(isA<PluginDeviceException>()),
    );

    await service.unregister(
      pluginId: 'humidity.plugin',
      generation: 1,
      registrationHandle: 'registration-1',
    );
    await sensorController.sensorRegistry
        .where((sensors) => !sensors.containsKey(registered.deviceId))
        .first;
    expect(deviceController.devices, isEmpty);
    expect(
      operations.where(
        (operation) => operation == PluginDeviceOperation.disconnect,
      ),
      hasLength(1),
    );
  });

  test('registration validates definitions and caps devices', () async {
    final service = PluginDeviceService();
    addTearDown(service.dispose);
    Future<Map<String, dynamic>> invoke(
      PluginDeviceOperation operation,
      Map<String, dynamic> payload,
    ) async => const {};

    await expectLater(
      service.register(
        pluginId: 'humidity.plugin',
        generation: 1,
        registrationHandle: 'invalid',
        definition: _definition('invalid', dataChannels: const []),
        invoke: invoke,
      ),
      throwsA(isA<PluginDeviceException>()),
    );
    for (var i = 0; i < 8; i++) {
      await service.register(
        pluginId: 'humidity.plugin',
        generation: 1,
        registrationHandle: 'registration-$i',
        definition: _definition('room-$i'),
        invoke: invoke,
      );
    }
    await expectLater(
      service.register(
        pluginId: 'humidity.plugin',
        generation: 1,
        registrationHandle: 'registration-9',
        definition: _definition('room-9'),
        invoke: invoke,
      ),
      throwsA(isA<PluginDeviceException>()),
    );
  });

  test('scan keeps a disconnected plugin registration discoverable', () async {
    final service = PluginDeviceService();
    final deviceController = DeviceController([service]);
    await deviceController.initialize();
    final sensorController = SensorController(controller: deviceController);
    addTearDown(() async {
      sensorController.dispose();
      deviceController.dispose();
      await service.dispose();
    });

    final operations = <PluginDeviceOperation>[];
    final registered = await service.register(
      pluginId: 'humidity.plugin',
      generation: 1,
      registrationHandle: 'registration-1',
      definition: _definition('office'),
      invoke: (operation, payload) async {
        operations.add(operation);
        return const {};
      },
    );
    final sensor = await sensorController.sensorRegistry
        .map((sensors) => sensors[registered.deviceId])
        .where((sensor) => sensor != null)
        .cast<Sensor>()
        .first;
    await sensor.connectionState
        .where((state) => state == ConnectionState.connected)
        .first;

    service.reportDisconnected(
      pluginId: 'humidity.plugin',
      generation: 1,
      registrationHandle: 'registration-1',
    );
    await sensor.connectionState
        .where((state) => state == ConnectionState.disconnected)
        .first;

    final scan = await deviceController.scanForDevices();
    expect(scan.failedServices, isEmpty);
    expect(scan.matchedDevices.map((device) => device.deviceId), [
      registered.deviceId,
    ]);
    expect(
      deviceController.devices.map((device) => device.deviceId),
      contains(registered.deviceId),
    );
    await sensor.connectionState
        .where((state) => state == ConnectionState.connected)
        .first
        .timeout(const Duration(seconds: 2));
    expect(
      operations
          .where((operation) => operation == PluginDeviceOperation.connect)
          .length,
      greaterThanOrEqualTo(2),
    );
  });

  test('new generation keeps identity and fences stale publications', () async {
    final service = PluginDeviceService();
    addTearDown(service.dispose);
    Future<Map<String, dynamic>> invoke(
      PluginDeviceOperation operation,
      Map<String, dynamic> payload,
    ) async => const {};

    final first = await service.register(
      pluginId: 'humidity.plugin',
      generation: 1,
      registrationHandle: 'registration',
      definition: _definition('office'),
      invoke: invoke,
    );
    await service.removeAllForPlugin('humidity.plugin', 1);
    final second = await service.register(
      pluginId: 'humidity.plugin',
      generation: 2,
      registrationHandle: 'registration',
      definition: _definition('office'),
      invoke: invoke,
    );

    expect(second.deviceId, first.deviceId);
    expect(
      () => service.publish(
        pluginId: 'humidity.plugin',
        generation: 1,
        registrationHandle: 'registration',
        snapshot: const {'relativeHumidity': 52.4},
      ),
      throwsA(isA<PluginDeviceException>()),
    );
  });
}

Map<String, dynamic> _definition(
  String instanceId, {
  List<Map<String, dynamic>>? dataChannels,
}) => {
  'driverId': 'humidity',
  'instanceId': instanceId,
  'name': 'Humidity',
  'vendor': 'Test',
  'dataChannels':
      dataChannels ??
      [
        {'key': 'relativeHumidity', 'type': 'number', 'unit': '%RH'},
      ],
};
