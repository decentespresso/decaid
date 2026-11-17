import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/models/device/impl/de1/de1.models.dart';
import 'package:reaprime/src/services/account/decent_account_service.dart';
import 'package:reaprime/src/services/account/legacy_de1_identity_resolver.dart';
import 'package:reaprime/src/services/account/registered_decent_machine.dart';

RegisteredDecentMachine machine(
  String serial, {
  String sku = '',
  DecentMachineModel? model,
}) => RegisteredDecentMachine(
  serial: serial,
  rawSku: sku,
  recognizedModel: model,
);

void main() {
  group('DecentMachineModel canonical mapping', () {
    test('maps all firmware values 0..7', () {
      expect(DecentMachineModel.fromInt(0), DecentMachineModel.Unknown);
      expect(DecentMachineModel.fromInt(1), DecentMachineModel.DE1);
      expect(DecentMachineModel.fromInt(2), DecentMachineModel.DE1Plus);
      expect(DecentMachineModel.fromInt(3), DecentMachineModel.DE1Pro);
      expect(DecentMachineModel.fromInt(4), DecentMachineModel.DE1XL);
      expect(DecentMachineModel.fromInt(5), DecentMachineModel.DE1Cafe);
      expect(DecentMachineModel.fromInt(6), DecentMachineModel.DE1XXL);
      expect(DecentMachineModel.fromInt(7), DecentMachineModel.DE1XXXL);
    });

    test('maps Bengle values >= 128 and keeps below-128 unknown', () {
      for (final value in [128, 129, 255]) {
        expect(isBengleModelValue(value), isTrue);
        expect(DecentMachineModel.fromInt(value), DecentMachineModel.Bengle);
      }
      expect(isBengleModelValue(127), isFalse);
      expect(DecentMachineModel.fromInt(127), DecentMachineModel.Unknown);
      expect(DecentMachineModel.fromInt(-1), DecentMachineModel.Unknown);
    });

    test('preserves established public enum names', () {
      expect(DecentMachineModel.DE1Pro.name, 'DE1Pro');
      expect(DecentMachineModel.DE1XL.name, 'DE1XL');
      expect(DecentMachineModel.DE1XXL.name, 'DE1XXL');
      expect(DecentMachineModel.DE1XXXL.name, 'DE1XXXL');
      expect(DecentMachineModel.Bengle.name, 'Bengle');
      expect(DecentMachineModel.Unknown.name, 'Unknown');
      expect(DecentMachineModel.DE1Plus.displayName, 'DE1+');
    });
  });

  group('parseSkuModel', () {
    test('parses explicit anchored DE1-family SKU tokens', () {
      expect(parseSkuModel('DE-DE1PRO220V7-00533'), DecentMachineModel.DE1Pro);
      expect(parseSkuModel('DE-DE1XL120V-00444'), DecentMachineModel.DE1XL);
      expect(parseSkuModel('DE-DE1XXXL230V-00999'), DecentMachineModel.DE1XXXL);
      expect(parseSkuModel('DE-DE1XXL230V-00888'), DecentMachineModel.DE1XXL);
      expect(parseSkuModel('DE-DE1CAFE220V-00777'), DecentMachineModel.DE1Cafe);
      expect(parseSkuModel('DE-DE1PLUS230V-00111'), DecentMachineModel.DE1Plus);
      expect(parseSkuModel('DE-DE1220V-00001'), DecentMachineModel.DE1);
    });

    test('detects explicit Bengle tokens for exclusion', () {
      expect(
        parseSkuModel('DE-BE1BENGLE220V_15A_3000W_B0-01101'),
        DecentMachineModel.Bengle,
      );
      expect(
        parseSkuModel('de-be1bengle120v_15a_3000w_b0-01102'),
        DecentMachineModel.Bengle,
      );
    });

    test('unknown SKU formats stay unknown rather than being guessed', () {
      expect(parseSkuModel('DE-DE1C220V-00001'), isNull);
      expect(parseSkuModel('DE-SOMETHINGELSE'), isNull);
      expect(parseSkuModel(''), isNull);
      expect(parseSkuModel('DE1PRO220V'), isNull);
    });

    test('longer unknown variants sharing a known prefix stay unknown', () {
      expect(parseSkuModel('DE-DE1PROXL220V-00001'), isNull);
      expect(parseSkuModel('DE-DE1CAFEX220V-00001'), isNull);
      expect(parseSkuModel('DE-DE1XXXLZ230V-00001'), isNull);
      expect(parseSkuModel('DE-DE1XXLZ230V-00001'), isNull);
      expect(parseSkuModel('DE-DE1XLZ120V-00001'), isNull);
      expect(parseSkuModel('DE-DE1+PRO220V-00001'), isNull);
      expect(parseSkuModel('DE-DE1Z220V-00001'), isNull);
    });
  });

  group('parseRegisteredMachines', () {
    test('parses serial and SKU records from the real backend', () {
      final machines = parseRegisteredMachines(
        '1337 DE-BE1BENGLE220V_15A_3000W_B0-01101\n'
        '1338 DE-DE1PRO220V7-00533',
      );

      expect(machines, hasLength(2));
      expect(machines[0].serial, '1337');
      expect(machines[0].rawSku, 'DE-BE1BENGLE220V_15A_3000W_B0-01101');
      expect(machines[0].recognizedModel, DecentMachineModel.Bengle);
      expect(machines[1].serial, '1338');
      expect(machines[1].rawSku, 'DE-DE1PRO220V7-00533');
      expect(machines[1].recognizedModel, DecentMachineModel.DE1Pro);
    });

    test('bare serials have no recognized model', () {
      final machines = parseRegisteredMachines('DE1-0001\n1338');
      expect(machines[0].serial, 'DE1-0001');
      expect(machines[0].recognizedModel, isNull);
      expect(machines[1].serial, '1338');
      expect(machines[1].recognizedModel, isNull);
    });

    test('deduplicates serials and ignores blank lines', () {
      final machines = parseRegisteredMachines(
        '1337 DE-DE1PRO220V7-00533\n\n1337 DE-DE1XL120V-00444\n 1338 ',
      );
      expect(machines.map((m) => m.serial), ['1337', '1338']);
    });

    test('parseSerialNumbers remains a serial-only projection', () {
      expect(
        parseSerialNumbers(
          '1337 DE-BE1BENGLE220V_15A_3000W_B0-01101\n'
          '1338 DE-DE1PRO220V7-00533',
        ),
        ['1337', '1338'],
      );
    });

    test('round-trips through JSON', () {
      final original = parseRegisteredMachines(
        '1337 DE-DE1PRO220V7-00533\n1338',
      );
      final restored = original
          .map((m) => RegisteredDecentMachine.fromJson(m.toJson()))
          .toList();
      expect(restored.map((m) => m.serial), ['1337', '1338']);
      expect(restored[0].rawSku, 'DE-DE1PRO220V7-00533');
      expect(restored[0].recognizedModel, DecentMachineModel.DE1Pro);
      expect(restored[1].recognizedModel, isNull);
    });
  });

  group('LegacyDe1IdentityResolver', () {
    const resolver = LegacyDe1IdentityResolver();

    RegisteredDecentMachine de1(String serial) =>
        machine(serial, sku: 'DE-DE1220V-00001', model: DecentMachineModel.DE1);

    RegisteredDecentMachine pro(String serial) => machine(
      serial,
      sku: 'DE-DE1PRO220V7-00533',
      model: DecentMachineModel.DE1Pro,
    );

    RegisteredDecentMachine xl(String serial) => machine(
      serial,
      sku: 'DE-DE1XL120V-00444',
      model: DecentMachineModel.DE1XL,
    );

    test('exact nonzero serial match resolves to that record', () {
      final result = resolver.resolve(
        rawSerial: '1338',
        rawModelValue: 3,
        registeredMachines: [de1('1337'), pro('1338')],
      );
      expect(result, isA<ResolvedLegacyDe1Identity>());
      expect((result as ResolvedLegacyDe1Identity).machine.serial, '1338');
    });

    test('recognized API model overrides a conflicting raw model', () {
      final result = resolver.resolve(
        rawSerial: '1338',
        rawModelValue: 3, // machine reports DE1Pro, API record says DE1XL
        registeredMachines: [xl('1338')],
      );
      final resolved = (result as ResolvedLegacyDe1Identity).machine;
      expect(resolved.recognizedModel, DecentMachineModel.DE1XL);
    });

    test('unknown API model retains the raw model on exact serial match', () {
      final result = resolver.resolve(
        rawSerial: '1338',
        rawModelValue: 3,
        registeredMachines: [machine('1338', sku: 'DE-SOMETHINGELSE')],
      );
      expect(result, isA<ResolvedLegacyDe1Identity>());
      expect(
        (result as ResolvedLegacyDe1Identity).machine.recognizedModel,
        isNull,
      );
    });

    test('unmatched nonzero serial remains unresolved', () {
      final result = resolver.resolve(
        rawSerial: '9999',
        rawModelValue: 3,
        registeredMachines: [de1('1337')],
      );
      expect(result, isA<UnavailableLegacyDe1Identity>());
    });

    test('a valid persisted mapping resolves for serial 0', () {
      final result = resolver.resolve(
        rawSerial: '0',
        rawModelValue: 0,
        registeredMachines: [pro('1338'), xl('1339')],
        mappedMachine: pro('1338'),
      );
      final resolved = (result as ResolvedLegacyDe1Identity).machine;
      expect(resolved.serial, '1338');
    });

    test('a stale persisted mapping is ignored, normal matching applies', () {
      final result = resolver.resolve(
        rawSerial: '0',
        rawModelValue: 0,
        registeredMachines: [pro('1338'), xl('1339')],
        mappedMachine: pro('1340'),
      );
      expect(result, isA<AmbiguousLegacyDe1Identity>());

      final narrowed = resolver.resolve(
        rawSerial: '0',
        rawModelValue: 0,
        registeredMachines: [pro('1338')],
        mappedMachine: pro('1340'),
      );
      expect((narrowed as ResolvedLegacyDe1Identity).machine.serial, '1338');
    });

    test('a persisted mapping to an unknown-SKU record is not accepted for '
        'serial 0', () {
      final result = resolver.resolve(
        rawSerial: '0',
        rawModelValue: 0,
        registeredMachines: [
          machine('1338', sku: 'DE-SOMETHINGELSE'),
          pro('1339'),
        ],
        mappedMachine: machine('1338', sku: 'DE-SOMETHINGELSE'),
      );
      expect(result, isA<ResolvedLegacyDe1Identity>());
      expect((result as ResolvedLegacyDe1Identity).machine.serial, '1339');

      final onlyUnknown = resolver.resolve(
        rawSerial: '0',
        rawModelValue: 0,
        registeredMachines: [machine('1338', sku: 'DE-SOMETHINGELSE')],
        mappedMachine: machine('1338', sku: 'DE-SOMETHINGELSE'),
      );
      expect(onlyUnknown, isA<UnavailableLegacyDe1Identity>());
    });

    test('one known legacy DE1 candidate resolves automatically', () {
      final result = resolver.resolve(
        rawSerial: '0',
        rawModelValue: 0,
        registeredMachines: [pro('1338')],
      );
      expect((result as ResolvedLegacyDe1Identity).machine.serial, '1338');
    });

    test('unique raw-model hint narrows multiple candidates to one', () {
      final result = resolver.resolve(
        rawSerial: '0',
        rawModelValue: 3, // DE1Pro hint
        registeredMachines: [pro('1338'), xl('1339'), pro('1340')],
      );
      expect(result, isA<AmbiguousLegacyDe1Identity>());

      final narrowed = resolver.resolve(
        rawSerial: '0',
        rawModelValue: 3,
        registeredMachines: [pro('1338'), xl('1339')],
      );
      expect((narrowed as ResolvedLegacyDe1Identity).machine.serial, '1338');
    });

    test('contradictory or unhelpful hints are ignored, not forced', () {
      // Hint matches nothing.
      final noHintMatch = resolver.resolve(
        rawSerial: '0',
        rawModelValue: 7, // DE1XXXL hint, no candidate matches
        registeredMachines: [pro('1338'), xl('1339')],
      );
      expect(noHintMatch, isA<AmbiguousLegacyDe1Identity>());

      // Hint matches more than one candidate.
      final multiHintMatch = resolver.resolve(
        rawSerial: '0',
        rawModelValue: 3,
        registeredMachines: [pro('1338'), pro('1340')],
      );
      expect(multiHintMatch, isA<AmbiguousLegacyDe1Identity>());
    });

    test('ambiguous candidates produce a manual selection request', () {
      final result = resolver.resolve(
        rawSerial: '0',
        rawModelValue: 0,
        registeredMachines: [de1('1337'), pro('1338'), xl('1339')],
      );
      expect(result, isA<AmbiguousLegacyDe1Identity>());
      final candidates = (result as AmbiguousLegacyDe1Identity).candidates;
      expect(candidates.map((m) => m.serial), ['1337', '1338', '1339']);
    });

    test('Bengle and unknown-SKU records are excluded from serial-0 '
        'candidates', () {
      final result = resolver.resolve(
        rawSerial: '0',
        rawModelValue: 0,
        registeredMachines: [
          machine(
            '2001',
            sku: 'DE-BE1BENGLE220V_15A_3000W_B0-01101',
            model: DecentMachineModel.Bengle,
          ),
          machine('3001', sku: 'DE-SOMETHINGELSE'),
          pro('1338'),
        ],
      );
      expect(result, isA<ResolvedLegacyDe1Identity>());
      expect((result as ResolvedLegacyDe1Identity).machine.serial, '1338');

      final onlyNonLegacy = resolver.resolve(
        rawSerial: '0',
        rawModelValue: 0,
        registeredMachines: [
          machine(
            '2001',
            sku: 'DE-BE1BENGLE220V_15A_3000W_B0-01101',
            model: DecentMachineModel.Bengle,
          ),
          machine('3001', sku: 'DE-SOMETHINGELSE'),
        ],
      );
      expect(onlyNonLegacy, isA<UnavailableLegacyDe1Identity>());
    });

    test('Bengle records are not selected by exact serial match either', () {
      final result = resolver.resolve(
        rawSerial: '2001',
        rawModelValue: 129,
        registeredMachines: [
          machine(
            '2001',
            sku: 'DE-BE1BENGLE220V_15A_3000W_B0-01101',
            model: DecentMachineModel.Bengle,
          ),
        ],
      );
      expect(result, isA<UnavailableLegacyDe1Identity>());
    });

    test('a Bengle mapping is not accepted for a legacy DE1', () {
      final result = resolver.resolve(
        rawSerial: '0',
        rawModelValue: 0,
        registeredMachines: [pro('1338')],
        mappedMachine: machine(
          '2001',
          sku: 'DE-BE1BENGLE220V_15A_3000W_B0-01101',
          model: DecentMachineModel.Bengle,
        ),
      );
      expect(result, isA<ResolvedLegacyDe1Identity>());
      expect((result as ResolvedLegacyDe1Identity).machine.serial, '1338');
    });
  });
}
