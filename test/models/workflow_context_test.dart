import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/models/data/workflow.dart';
import 'package:reaprime/src/models/data/workflow_context.dart';

void main() {
  group('WorkflowContext', () {
    test('round-trip serialization with all fields', () {
      final ctx = WorkflowContext(
        targetDoseWeight: 18.0,
        targetYield: 36.0,
        grinderId: 'grinder-123',
        grinderModel: 'Niche Zero',
        grinderSetting: '15',
        beanBatchId: 'batch-456',
        coffeeName: 'Gesha Village',
        coffeeRoaster: 'Sey',
        finalBeverageType: 'espresso',
        baristaName: 'Alice',
        drinkerName: 'Bob',
        extras: {
          'plugin1': {'key': 'value'},
        },
      );

      final json = ctx.toJson();
      final restored = WorkflowContext.fromJson(json);

      expect(restored.targetDoseWeight, 18.0);
      expect(restored.targetYield, 36.0);
      expect(restored.grinderId, 'grinder-123');
      expect(restored.grinderModel, 'Niche Zero');
      expect(restored.grinderSetting, '15');
      expect(restored.beanBatchId, 'batch-456');
      expect(restored.coffeeName, 'Gesha Village');
      expect(restored.coffeeRoaster, 'Sey');
      expect(restored.finalBeverageType, 'espresso');
      expect(restored.baristaName, 'Alice');
      expect(restored.drinkerName, 'Bob');
      expect(restored.extras, {
        'plugin1': {'key': 'value'},
      });
    });

    test('round-trip with minimal fields (nulls omitted from JSON)', () {
      final ctx = WorkflowContext(targetDoseWeight: 18.0, targetYield: 36.0);

      final json = ctx.toJson();
      expect(json.containsKey('grinderId'), false);
      expect(json.containsKey('extras'), false);

      final restored = WorkflowContext.fromJson(json);
      expect(restored.targetDoseWeight, 18.0);
      expect(restored.targetYield, 36.0);
      expect(restored.grinderId, isNull);
      expect(restored.coffeeName, isNull);
    });

    test('ratio computed correctly', () {
      final ctx = WorkflowContext(targetDoseWeight: 18.0, targetYield: 36.0);
      expect(ctx.ratio, 2.0);
    });

    test('ratio null when dose weight is null or zero', () {
      expect(WorkflowContext(targetYield: 36.0).ratio, isNull);
      expect(
        WorkflowContext(targetDoseWeight: 0, targetYield: 36.0).ratio,
        isNull,
      );
    });

    test('copyWith preserves unchanged fields', () {
      final ctx = WorkflowContext(
        targetDoseWeight: 18.0,
        targetYield: 36.0,
        coffeeName: 'Ethiopian',
      );

      final updated = ctx.copyWith(targetYield: 40.0);

      expect(updated.targetDoseWeight, 18.0);
      expect(updated.targetYield, 40.0);
      expect(updated.coffeeName, 'Ethiopian');
    });

    group('fromJson non-string coercion (#106)', () {
      test('int values for ID/text fields are stringified, not crashed', () {
        final restored = WorkflowContext.fromJson({
          'grinderId': 123,
          'grinderSetting': 5,
          'beanBatchId': 456,
          'coffeeName': 789,
        });
        expect(restored.grinderId, '123');
        expect(restored.grinderSetting, '5');
        expect(restored.beanBatchId, '456');
        expect(restored.coffeeName, '789');
      });

      test('double values are stringified', () {
        final restored = WorkflowContext.fromJson({'grinderSetting': 5.5});
        expect(restored.grinderSetting, '5.5');
      });

      test('bool values are stringified', () {
        final restored = WorkflowContext.fromJson({'drinkerName': true});
        expect(restored.drinkerName, 'true');
      });

      test('null values stay null', () {
        final restored = WorkflowContext.fromJson({
          'grinderId': null,
          'coffeeName': null,
        });
        expect(restored.grinderId, isNull);
        expect(restored.coffeeName, isNull);
      });

      test(
        'Map / List values are refused (null-coerced), not silently stringified',
        () {
          final restored = WorkflowContext.fromJson({
            'coffeeName': {'nested': 'map'},
            'baristaName': [1, 2, 3],
          });
          expect(restored.coffeeName, isNull);
          expect(restored.baristaName, isNull);
        },
      );

      test('toJson → merge-with-int → fromJson roundtrip does not crash '
          '(regression for workflow_handler deepMerge path)', () {
        final ctx = WorkflowContext(
          grinderId: 'grinder-1',
          grinderSetting: '5',
          beanBatchId: 'batch-1',
        );
        // Simulate a client sending numeric grinderSetting; the
        // handler's deepMerge produces a mixed-type map, which then
        // needs to round-trip through fromJson on the next PUT.
        final merged = {...ctx.toJson(), 'grinderSetting': 7};
        final reparsed = WorkflowContext.fromJson(merged);
        expect(reparsed.grinderSetting, '7');

        // Next PUT cycle: serialize + reparse again — must still work.
        final second = WorkflowContext.fromJson(reparsed.toJson());
        expect(second.grinderSetting, '7');
        expect(second.grinderId, 'grinder-1');
        expect(second.beanBatchId, 'batch-1');
      });
    });
  });

  group('Workflow.fromJson - migration-on-read', () {
    test('legacy-only JSON (no context) synthesizes WorkflowContext', () {
      final json = {
        'id': 'wf-1',
        'name': 'Legacy Workflow',
        'description': '',
        'profile': {
          'title': 'Test',
          'author': 'Test',
          'notes': '',
          'beverage_type': 'espresso',
          'steps': [
            {
              'name': 'pour',
              'pump': 'pressure',
              'transition': 'fast',
              'volume': 100,
              'seconds': 30,
              'temperature': 93,
              'sensor': 'coffee',
              'pressure': 9,
            },
          ],
          'tank_temperature': 0.0,
          'target_weight': 36.0,
          'target_volume': 0,
          'target_volume_count_start': 0,
          'legacy_profile_type': '',
          'type': 'advanced',
          'lang': 'en',
          'hidden': false,
          'reference_file': '',
          'changes_since_last_espresso': '',
          'version': '2',
        },
        'doseData': {'doseIn': 18.0, 'doseOut': 36.0},
        'grinderData': {
          'setting': '15',
          'manufacturer': 'Niche',
          'model': 'Zero',
        },
        'coffeeData': {'name': 'Gesha Village', 'roaster': 'Sey'},
        'steamSettings': {
          'targetTemperature': 150,
          'duration': 50,
          'flow': 0.8,
        },
        'hotWaterData': {
          'targetTemperature': 75,
          'duration': 30,
          'volume': 50,
          'flow': 10.0,
        },
        'rinseData': {'targetTemperature': 90, 'duration': 10, 'flow': 6.0},
      };

      final workflow = Workflow.fromJson(json);

      expect(workflow.context, isNotNull);
      expect(workflow.context!.targetDoseWeight, 18.0);
      expect(workflow.context!.targetYield, 36.0);
      expect(workflow.context!.grinderSetting, '15');
      expect(workflow.context!.grinderModel, 'Zero');
      expect(workflow.context!.coffeeName, 'Gesha Village');
      expect(workflow.context!.coffeeRoaster, 'Sey');
    });

    test('context + legacy fields: legacy only backfills null context slots', () {
      final json = {
        'id': 'wf-3',
        'name': 'Blended',
        'description': '',
        'profile': {
          'title': 'Test',
          'author': 'Test',
          'notes': '',
          'beverage_type': 'espresso',
          'steps': [
            {
              'name': 'pour',
              'pump': 'pressure',
              'transition': 'fast',
              'volume': 100,
              'seconds': 30,
              'temperature': 93,
              'sensor': 'coffee',
              'pressure': 9,
            },
          ],
          'tank_temperature': 0.0,
          'target_weight': 36.0,
          'target_volume': 0,
          'target_volume_count_start': 0,
          'legacy_profile_type': '',
          'type': 'advanced',
          'lang': 'en',
          'hidden': false,
          'reference_file': '',
          'changes_since_last_espresso': '',
          'version': '2',
        },
        // context has targetYield but NOT targetDoseWeight — legacy should backfill it
        'context': {'targetYield': 38.0},
        'doseData': {
          'doseIn': 19.0,
          'doseOut': 99.0,
        }, // doseOut must NOT override context's targetYield
        'steamSettings': {
          'targetTemperature': 150,
          'duration': 50,
          'flow': 0.8,
        },
        'hotWaterData': {
          'targetTemperature': 75,
          'duration': 30,
          'volume': 50,
          'flow': 10.0,
        },
        'rinseData': {'targetTemperature': 90, 'duration': 10, 'flow': 6.0},
      };

      final workflow = Workflow.fromJson(json);

      expect(workflow.context!.targetYield, 38.0);
      expect(workflow.context!.targetDoseWeight, 19.0);
    });

    test(
      'legacy doseData-only JSON (no grinder/coffee) synthesizes partial context',
      () {
        final json = {
          'id': 'wf-2',
          'name': 'Dose Only',
          'description': '',
          'profile': {
            'title': 'Test',
            'author': 'Test',
            'notes': '',
            'beverage_type': 'espresso',
            'steps': [
              {
                'name': 'pour',
                'pump': 'pressure',
                'transition': 'fast',
                'volume': 100,
                'seconds': 30,
                'temperature': 93,
                'sensor': 'coffee',
                'pressure': 9,
              },
            ],
            'tank_temperature': 0.0,
            'target_volume': 0,
            'target_volume_count_start': 0,
            'legacy_profile_type': '',
            'type': 'advanced',
            'lang': 'en',
            'hidden': false,
            'reference_file': '',
            'changes_since_last_espresso': '',
            'version': '2',
          },
          'doseData': {'doseIn': 16, 'doseOut': 32},
          'steamSettings': {
            'targetTemperature': 150,
            'duration': 50,
            'flow': 0.8,
          },
          'hotWaterData': {
            'targetTemperature': 75,
            'duration': 30,
            'volume': 50,
            'flow': 10.0,
          },
          'rinseData': {'targetTemperature': 90, 'duration': 10, 'flow': 6.0},
        };

        final workflow = Workflow.fromJson(json);

        expect(workflow.context, isNotNull);
        expect(workflow.context!.targetDoseWeight, 16.0);
        expect(workflow.context!.targetYield, 32.0);
        expect(workflow.context!.grinderSetting, isNull);
        expect(workflow.context!.coffeeName, isNull);
      },
    );
  });

  group('Workflow.machine snapshot', () {
    test('WorkflowMachine round-trips and omits null flowCalibration', () {
      final m = WorkflowMachine(flowCalibration: 1.05);
      expect(m.toJson(), {'flowCalibration': 1.05});
      expect(WorkflowMachine.fromJson(m.toJson()).flowCalibration, 1.05);
      expect(
        const WorkflowMachine().toJson().containsKey('flowCalibration'),
        false,
      );
    });

    test('Workflow round-trips the machine snapshot', () {
      final wf = Workflow.fromJson(
        _workflowJson(machine: {'flowCalibration': 0.92}),
      );
      expect(wf.machine?.flowCalibration, 0.92);
      final reparsed = Workflow.fromJson(wf.toJson());
      expect(reparsed.machine?.flowCalibration, 0.92);
    });

    test('Workflow without a machine field stays null and omits it', () {
      final wf = Workflow.fromJson(_workflowJson());
      expect(wf.machine, isNull);
      expect(wf.toJson().containsKey('machine'), false);
    });
  });
}

Map<String, dynamic> _workflowJson({Map<String, dynamic>? machine}) {
  return {
    'id': 'wf-machine',
    'name': 'Machine WF',
    'description': '',
    'profile': {
      'title': 'Test',
      'author': 'Test',
      'notes': '',
      'beverage_type': 'espresso',
      'steps': [
        {
          'name': 'pour',
          'pump': 'pressure',
          'transition': 'fast',
          'volume': 100,
          'seconds': 30,
          'temperature': 93,
          'sensor': 'coffee',
          'pressure': 9,
        },
      ],
      'tank_temperature': 0.0,
      'target_weight': 36.0,
      'target_volume': 0,
      'target_volume_count_start': 0,
      'legacy_profile_type': '',
      'type': 'advanced',
      'lang': 'en',
      'hidden': false,
      'reference_file': '',
      'changes_since_last_espresso': '',
      'version': '2',
    },
    'context': {'targetDoseWeight': 18.0, 'targetYield': 36.0},
    'steamSettings': {'targetTemperature': 150, 'duration': 50, 'flow': 0.8},
    'hotWaterData': {
      'targetTemperature': 75,
      'duration': 30,
      'volume': 50,
      'flow': 10.0,
    },
    'rinseData': {'targetTemperature': 90, 'duration': 10, 'flow': 6.0},
    'machine': ?machine,
  };
}
