import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/models/device/impl/bengle/bengle_mmr.dart';
import 'package:reaprime/src/models/device/impl/de1/de1.models.dart';
import 'package:reaprime/src/models/device/impl/de1/mmr_address.dart';
import 'package:reaprime/src/models/device/impl/de1/unified_de1/unified_de1.dart';

void main() {
  test('app MMR declarations match the pinned Bengle firmware contract', () {
    final contract =
        jsonDecode(
              File('test/fixtures/bengle_mmr_contract.json').readAsStringSync(),
            )
            as Map<String, dynamic>;
    final firmware = contract['firmware'] as Map<String, dynamic>;
    final rows = (contract['registers'] as List<dynamic>)
        .cast<Map<String, dynamic>>();
    final appRegisters = <String, MmrAddress>{
      for (final register in MMRItem.values)
        'MMRItem.${register.name}': register,
      for (final register in BengleMmr.values)
        'BengleMmr.${register.name}': register,
      for (final register in BengleSteamMmr.values)
        'BengleSteamMmr.${register.name}': register,
      for (final register in BengleScaleMmr.values)
        'BengleScaleMmr.${register.name}': register,
    };

    expect(firmware, {
      'repository': 'tadelv/Bengle',
      'commit': '2377c7e0e48e9ee2c43cf02ad2f82028252f56e8',
      'path': 'BengleMainCPUFirmware/src/Classes/Data/MMR.def',
    });

    final appNames = rows.map((row) => row['app'] as String).toList();
    final firmwareNames = rows.map((row) => row['firmware'] as String).toList();
    expect(appNames.toSet(), hasLength(appNames.length));
    expect(firmwareNames.toSet(), hasLength(firmwareNames.length));
    expect(appNames, unorderedEquals(appRegisters.keys));

    for (final row in rows) {
      final appName = row['app'] as String;
      final register = appRegisters[appName]!;
      final address = int.parse(
        (row['address'] as String).substring(2),
        radix: 16,
      );
      expect(register.address, address, reason: '$appName address');
      expect(register.length, row['length'], reason: '$appName length');
      expect(
        register.readScale,
        (row['readScale'] as num).toDouble(),
        reason: '$appName read scale',
      );
      expect(
        register.writeScale,
        (row['writeScale'] as num).toDouble(),
        reason: '$appName write scale',
      );
    }
  });
}
