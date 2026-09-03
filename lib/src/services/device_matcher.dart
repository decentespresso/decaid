import 'package:reaprime/src/models/device/device.dart';
import 'package:reaprime/src/models/device/device_implementation.dart';
import 'package:reaprime/src/models/device/impl/acaia/acaia_scale.dart';
import 'package:reaprime/src/models/device/impl/atomheart/atomheart_scale.dart';
import 'package:reaprime/src/models/device/impl/bengle/bengle.dart';
import 'package:reaprime/src/models/device/impl/blackcoffee/blackcoffee_scale.dart';
import 'package:reaprime/src/models/device/impl/bookoo/miniscale.dart';
import 'package:reaprime/src/models/device/impl/de1/unified_de1/unified_de1.dart';
import 'package:reaprime/src/models/device/impl/decent_scale/scale.dart';
import 'package:reaprime/src/models/device/impl/decent_temp/temperature.dart';
import 'package:reaprime/src/models/device/impl/difluid/difluid_r2_sensor.dart';
import 'package:reaprime/src/models/device/impl/difluid/difluid_scale.dart';
import 'package:reaprime/src/models/device/impl/eureka/eureka_scale.dart';
import 'package:reaprime/src/models/device/impl/felicita/arc.dart';
import 'package:reaprime/src/models/device/impl/hiroia/hiroia_scale.dart';
import 'package:reaprime/src/models/device/impl/skale/skale2_scale.dart';
import 'package:reaprime/src/models/device/impl/smartchef/smartchef_scale.dart';
import 'package:reaprime/src/models/device/impl/timemore/timemore_dot_scale.dart';
import 'package:reaprime/src/models/device/impl/varia/varia_aku_scale.dart';
import 'package:reaprime/src/models/device/transport/ble_transport.dart';
import 'package:reaprime/src/models/device/impl/weighmaster/weighmaster_scale.dart';

class DeviceMatcher {
  static List<String> serviceUuidsFor(DeviceType type) => switch (type) {
    DeviceType.scale => [
      DecentScale.serviceIdentifier.long,
      Skale2Scale.serviceIdentifier.long,
      FelicitaArc.serviceIdentifier.long,
      BlackCoffeeScale.serviceIdentifier.long,
      BookooScale.serviceIdentifier.long,
      EurekaScale.serviceIdentifier.long,
      SmartChefScale.serviceIdentifier.long,
      VariaAkuScale.serviceIdentifier.long,
      DifluidScale.serviceIdentifier.long,
      HiroiaScale.serviceIdentifier.long,
      AtomheartScale.serviceIdentifier.long,
      WeighMasterScale.serviceIdentifier.long,
      TimemoreDotScale.serviceIdentifier.long,
      ...AcaiaScale.advertisedServiceUuids,
    ],
    DeviceType.machine => [UnifiedDe1.advertisingIdentifier.long],
    DeviceType.sensor => [
      DecentTemp.serviceIdentifier.long,
      DifluidR2Sensor.serviceIdentifier.long,
    ],
  };

  static DeviceImplementation? implementationForName(String advertisedName) {
    final name = advertisedName;
    final nameLower = name.toLowerCase();

    if (name == 'Half Decent Scale (USB)') {
      return DeviceImplementation.hdsSerial;
    }
    if (name == 'Half Decent Scale (WiFi)') return DeviceImplementation.hdsWifi;
    if (name == 'Decent Scale') return DeviceImplementation.decentScale;
    if (name == 'Skale2' || nameLower.startsWith('skale')) {
      return DeviceImplementation.skale2;
    }
    if (name == 'DE1' || nameLower == 'nrf5x' || nameLower.startsWith('de1')) {
      return DeviceImplementation.unifiedDe1;
    }
    if (name == 'Bengle' || nameLower.startsWith('bengle')) {
      return DeviceImplementation.bengle;
    }
    if (nameLower.startsWith('felicita')) {
      return DeviceImplementation.felicitaArc;
    }
    if (nameLower.startsWith('black')) {
      return DeviceImplementation.blackCoffeeScale;
    }
    if (nameLower.contains('dot') || nameLower.contains('tes017')) {
      return DeviceImplementation.timemoreDot;
    }
    if (nameLower.contains('acaia') ||
        nameLower.contains('lunar') ||
        nameLower.contains('pearl') ||
        nameLower.contains('proch') ||
        nameLower.contains('pyxis')) {
      return DeviceImplementation.acaiaScale;
    }
    if (nameLower.contains('eureka') ||
        nameLower.contains('precisa') ||
        nameLower.contains('cfs-9002')) {
      return DeviceImplementation.eurekaScale;
    }
    if (nameLower.contains('solo barista') || nameLower.contains('lsj-001')) {
      return DeviceImplementation.eurekaScale;
    }
    if (nameLower.contains('smartchef')) {
      return DeviceImplementation.smartChefScale;
    }
    if (nameLower.contains('difluid') && nameLower.contains('r2')) {
      return DeviceImplementation.difluidR2Sensor;
    }
    if (nameLower.contains('aku') || nameLower.contains('varia')) {
      return DeviceImplementation.variaAkuScale;
    }
    if (nameLower.contains('hiroia') || nameLower.contains('jimmy')) {
      return DeviceImplementation.hiroiaScale;
    }
    if (nameLower.contains('difluid')) return DeviceImplementation.difluidScale;
    if (nameLower.contains('atomheart') || nameLower.contains('eclair')) {
      return DeviceImplementation.atomheartScale;
    }
    if (nameLower.contains('bookoo')) return DeviceImplementation.bookooScale;
    if (nameLower.contains('decent temp')) {
      return DeviceImplementation.decentTemp;
    }
    if (name == 'WeighMaster Scale') {
      return DeviceImplementation.weighMasterScale;
    }
    return null;
  }

  static Future<Device?> match({
    required BLETransport transport,
    required String advertisedName,
    List<String> advertisedServices = const [],
  }) async {
    final name = advertisedName;
    final nameLower = name.toLowerCase();

    if (name == 'Decent Scale') return DecentScale(transport: transport);
    if (name == 'Skale2' || nameLower.startsWith("skale")) {
      return Skale2Scale(transport: transport);
    }

    if (name == 'DE1' || nameLower == 'nrf5x' || nameLower.startsWith('de1')) {
      return UnifiedDe1(transport: transport);
    }
    if (name == 'Bengle' || nameLower.startsWith("bengle")) {
      return Bengle(transport: transport);
    }

    if (nameLower.startsWith('felicita')) {
      return FelicitaArc(transport: transport);
    }
    if (nameLower.startsWith('black')) {
      return BlackCoffeeScale(transport: transport);
    }

    if (nameLower.contains('dot') ||
        nameLower.contains('tes017') ||
        (name.isEmpty && advertisesKnownService(advertisedServices))) {
      return TimemoreDotScale(transport: transport);
    }

    if (nameLower.contains('acaia') ||
        nameLower.contains('lunar') ||
        nameLower.contains('pearl') ||
        nameLower.contains('proch') ||
        nameLower.contains('pyxis')) {
      return AcaiaScale(transport: transport);
    }

    if (nameLower.contains('eureka') ||
        nameLower.contains('precisa') ||
        nameLower.contains('cfs-9002')) {
      return EurekaScale(transport: transport);
    }
    if (nameLower.contains('solo barista') || nameLower.contains('lsj-001')) {
      return EurekaScale(transport: transport);
    }

    if (nameLower.contains('smartchef')) {
      return SmartChefScale(transport: transport);
    }
    if (nameLower.contains('difluid') && nameLower.contains('r2')) {
      return DifluidR2Sensor(transport: transport);
    }
    if (nameLower.contains('aku') || nameLower.contains('varia')) {
      return VariaAkuScale(transport: transport);
    }
    if (nameLower.contains('hiroia') || nameLower.contains('jimmy')) {
      return HiroiaScale(transport: transport);
    }
    if (nameLower.contains('difluid')) {
      return DifluidScale(transport: transport);
    }
    if (nameLower.contains('atomheart') || nameLower.contains('eclair')) {
      return AtomheartScale(transport: transport);
    }
    if (nameLower.contains('bookoo')) {
      return BookooScale(transport: transport);
    }
    if (nameLower.contains('decent temp')) {
      return DecentTemp(transport: transport);
    }
    if (name == 'WeighMaster Scale') {
      return WeighMasterScale(transport: transport);
    }

    return null;
  }

  static bool advertisesKnownService(List<String> advertisedServices) {
    final lower = advertisedServices.map((s) => s.toLowerCase()).toSet();
    return lower.contains(TimemoreDotScale.serviceIdentifier.long) ||
        lower.contains(TimemoreDotScale.serviceIdentifier.short);
  }
}
