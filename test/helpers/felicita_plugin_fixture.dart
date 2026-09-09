import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:reaprime/src/plugins/plugin_manifest.dart';
import 'package:reaprime/src/plugins/plugin_manager.dart';

import 'plugin_ble_fixture.dart';

const felicitaPluginPath = 'examples/plugins/felicita-arc.reaplugin';
const felicitaServiceUuid = '0000ffe0-0000-1000-8000-00805f9b34fb';
const felicitaCharacteristicUuid = '0000ffe1-0000-1000-8000-00805f9b34fb';

PluginManifest felicitaManifest() => PluginManifest.fromJson(
  jsonDecode(File('$felicitaPluginPath/manifest.json').readAsStringSync()),
);

Future<void> loadFelicitaPlugin(PluginManager manager) => manager.loadPlugin(
  id: felicitaManifest().id,
  manifest: felicitaManifest(),
  settings: {},
  jsCode: File('$felicitaPluginPath/plugin.js').readAsStringSync(),
);

List<int> felicitaPacket(double grams, {int battery = 143, int? sign}) {
  final magnitude = (grams.abs() * 100).round().toString().padLeft(6, '0');
  return [
    0,
    0,
    sign ?? (grams < 0 ? 45 : 43),
    ...magnitude.codeUnits,
    0,
    0,
    0,
    0,
    0,
    0,
    battery,
    0,
    0,
  ];
}

class FelicitaPluginTransport extends PluginBleFixtureTransport {
  FelicitaPluginTransport(
    super.physicalId, {
    this.firstPacket,
    this.servicePresent = true,
    this.subscriptionDelay = Duration.zero,
    this.subscriptionFailure,
    this.writeFailure,
  });

  final List<int>? firstPacket;
  final bool servicePresent;
  final Duration subscriptionDelay;
  final Object? subscriptionFailure;
  final Object? writeFailure;
  final subscribed = Completer<void>();

  @override
  Future<List<String>> discoverServices() async =>
      servicePresent ? [felicitaServiceUuid] : [];

  @override
  Future<void> subscribe(
    String service,
    String characteristic,
    void Function(Uint8List) callback,
  ) async {
    if (service != felicitaServiceUuid ||
        characteristic != felicitaCharacteristicUuid) {
      throw StateError(
        'Unexpected Felicita subscription $service/$characteristic',
      );
    }
    if (subscriptionDelay != Duration.zero) {
      await Future<void>.delayed(subscriptionDelay);
    }
    if (subscriptionFailure != null) throw subscriptionFailure!;
    subscribers[characteristic] = callback;
    if (firstPacket != null) callback(Uint8List.fromList(firstPacket!));
    if (!subscribed.isCompleted) subscribed.complete();
  }

  @override
  Future<void> write(
    String serviceUUID,
    String characteristicUUID,
    Uint8List data, {
    bool withResponse = true,
    Duration? timeout,
  }) async {
    if (serviceUUID != felicitaServiceUuid ||
        characteristicUUID != felicitaCharacteristicUuid) {
      throw StateError(
        'Unexpected Felicita write $serviceUUID/$characteristicUUID',
      );
    }
    if (writeFailure != null) throw writeFailure!;
    await super.write(
      serviceUUID,
      characteristicUUID,
      data,
      withResponse: withResponse,
      timeout: timeout,
    );
  }

  void emit(List<int> packet) =>
      subscribers[felicitaCharacteristicUuid]!(Uint8List.fromList(packet));
}
