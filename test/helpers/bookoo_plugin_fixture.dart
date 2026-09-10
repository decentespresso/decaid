import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:reaprime/src/models/device/device.dart' as device;
import 'package:reaprime/src/plugins/plugin_manifest.dart';
import 'package:reaprime/src/plugins/plugin_manager.dart';

import 'plugin_ble_fixture.dart';

const bookooPluginPath = 'examples/plugins/bookoo-mini.reaplugin';
const bookooServiceUuid = '00000ffe-0000-1000-8000-00805f9b34fb';
const bookooDataCharacteristicUuid = '0000ff11-0000-1000-8000-00805f9b34fb';
const bookooCommandCharacteristicUuid = '0000ff12-0000-1000-8000-00805f9b34fb';

PluginManifest bookooManifest() => PluginManifest.fromJson(
  jsonDecode(File('$bookooPluginPath/manifest.json').readAsStringSync()),
);
Future<void> loadBookooPlugin(PluginManager manager) => manager.loadPlugin(
  id: bookooManifest().id,
  manifest: bookooManifest(),
  settings: {},
  jsCode: File('$bookooPluginPath/plugin.js').readAsStringSync(),
);

class BookooPluginTransport extends PluginBleFixtureTransport {
  BookooPluginTransport(
    super.physicalId, {
    this.firstPacket,
    this.servicePresent = true,
    this.subscriptionDelay = Duration.zero,
    this.subscriptionFailure,
  });
  final List<int>? firstPacket;
  final bool servicePresent;
  final Duration subscriptionDelay;
  final Object? subscriptionFailure;
  final subscribed = Completer<void>();

  /// Fires the platform's connection update for this device, standing in for a
  /// device-initiated or lost link. A link that is already torn down has
  /// nothing left to drop.
  void dropLink() {
    if (states.isClosed) return;
    states.add(device.ConnectionState.disconnected);
  }

  @override
  Future<List<String>> discoverServices() async =>
      servicePresent ? [bookooServiceUuid] : [];

  @override
  Future<void> subscribe(
    String service,
    String characteristic,
    void Function(Uint8List) callback,
  ) async {
    if (service != bookooServiceUuid ||
        characteristic != bookooDataCharacteristicUuid) {
      throw StateError(
        'Unexpected Bookoo subscription $service/$characteristic',
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
    if (serviceUUID != bookooServiceUuid ||
        characteristicUUID != bookooCommandCharacteristicUuid) {
      throw StateError(
        'Unexpected Bookoo write $serviceUUID/$characteristicUUID',
      );
    }
    await super.write(
      serviceUUID,
      characteristicUUID,
      data,
      withResponse: withResponse,
      timeout: timeout,
    );
  }

  void emit(List<int> packet) =>
      subscribers[bookooDataCharacteristicUuid]!(Uint8List.fromList(packet));
}
