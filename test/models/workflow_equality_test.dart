import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/controllers/workflow_controller.dart';
import 'package:reaprime/src/models/data/profile.dart';
import 'package:reaprime/src/models/data/workflow.dart';
import 'package:reaprime/src/models/data/workflow_context.dart';

void main() {
  group('SteamSettings equality', () {
    test('equal by value', () {
      final a = SteamSettings(targetTemperature: 150, duration: 50, flow: 2.1);
      final b = SteamSettings(targetTemperature: 150, duration: 50, flow: 2.1);
      expect(a, equals(b));
      expect(a.hashCode, equals(b.hashCode));
    });

    test('differ when duration differs', () {
      final a = SteamSettings(targetTemperature: 150, duration: 50, flow: 2.1);
      final b = SteamSettings(targetTemperature: 150, duration: 30, flow: 2.1);
      expect(a, isNot(equals(b)));
    });

    test('differ when flow differs', () {
      final a = SteamSettings(targetTemperature: 150, duration: 50, flow: 2.1);
      final b = SteamSettings(targetTemperature: 150, duration: 50, flow: 1.5);
      expect(a, isNot(equals(b)));
    });

    test('differ when stopAtTemperature differs', () {
      final a = SteamSettings(
        targetTemperature: 150,
        duration: 50,
        flow: 2.1,
        stopAtTemperature: 65.0,
      );
      final b = SteamSettings(
        targetTemperature: 150,
        duration: 50,
        flow: 2.1,
        stopAtTemperature: 70.0,
      );
      expect(a, isNot(equals(b)));
    });

    test('stopAtTemperature defaults to 0.0 (off)', () {
      final s = SteamSettings(targetTemperature: 150, duration: 50, flow: 2.1);
      expect(s.stopAtTemperature, equals(0.0));
      expect(SteamSettings.defaults().stopAtTemperature, equals(0.0));
    });

    test('stopAtTemperature survives fromJson round-trip', () {
      final original = SteamSettings(
        targetTemperature: 150,
        duration: 50,
        flow: 2.1,
        stopAtTemperature: 65.0,
      );
      final roundTrip = SteamSettings.fromJson(original.toJson());
      expect(roundTrip.stopAtTemperature, equals(65.0));
      expect(original, equals(roundTrip));
    });

    test('fromJson tolerates missing stopAtTemperature (legacy clients)', () {
      final json = <String, dynamic>{
        'targetTemperature': 150,
        'duration': 50,
        'flow': 2.1,
      };
      final parsed = SteamSettings.fromJson(json);
      expect(parsed.stopAtTemperature, equals(0.0));
    });

    test('copyWith preserves and overrides stopAtTemperature', () {
      final base = SteamSettings(
        targetTemperature: 150,
        duration: 50,
        flow: 2.1,
        stopAtTemperature: 65.0,
      );
      expect(base.copyWith().stopAtTemperature, equals(65.0));
      expect(
        base.copyWith(stopAtTemperature: 0.0).stopAtTemperature,
        equals(0.0),
      );
    });
  });

  group('HotWaterData equality', () {
    test('equal by value', () {
      final a = HotWaterData(
        targetTemperature: 75,
        duration: 30,
        volume: 50,
        flow: 10,
      );
      final b = HotWaterData(
        targetTemperature: 75,
        duration: 30,
        volume: 50,
        flow: 10,
      );
      expect(a, equals(b));
      expect(a.hashCode, equals(b.hashCode));
    });

    test('differ when any field differs', () {
      final base = HotWaterData(
        targetTemperature: 75,
        duration: 30,
        volume: 50,
        flow: 10,
      );
      expect(base, isNot(equals(base.copyWith(duration: 31))));
      expect(base, isNot(equals(base.copyWith(targetTemperature: 76))));
      expect(base, isNot(equals(base.copyWith(volume: 51))));
      expect(base, isNot(equals(base.copyWith(flow: 9.9))));
    });
  });

  group('RinseData equality', () {
    test('equal by value', () {
      final a = RinseData(targetTemperature: 90, duration: 10, flow: 6.0);
      final b = RinseData(targetTemperature: 90, duration: 10, flow: 6.0);
      expect(a, equals(b));
      expect(a.hashCode, equals(b.hashCode));
    });

    test('differ when duration differs', () {
      final a = RinseData(targetTemperature: 90, duration: 10, flow: 6.0);
      final b = RinseData(targetTemperature: 90, duration: 11, flow: 6.0);
      expect(a, isNot(equals(b)));
    });
  });

  group('Workflow equality', () {
    test('steamSettings equality survives fromJson round-trip', () {
      final original = SteamSettings(
        targetTemperature: 150,
        duration: 50,
        flow: 2.1,
      );
      final roundTrip = SteamSettings.fromJson(original.toJson());
      expect(original, equals(roundTrip));
    });

    test('hotWaterData equality survives fromJson round-trip', () {
      final original = HotWaterData(
        targetTemperature: 75,
        duration: 30,
        volume: 50,
        flow: 10.0,
      );
      final roundTrip = HotWaterData.fromJson(original.toJson());
      expect(original, equals(roundTrip));
    });

    test('rinseData equality survives fromJson round-trip', () {
      final original = RinseData(
        targetTemperature: 90,
        duration: 10,
        flow: 6.0,
      );
      final roundTrip = RinseData.fromJson(original.toJson());
      expect(original, equals(roundTrip));
    });

    test(
      'default workflow fields equal to a freshly-constructed workflow with the same settings',
      () {
        final controller = WorkflowController();
        final wf = controller.currentWorkflow;
        final roundTrip = Workflow.fromJson(wf.toJson());
        expect(wf.steamSettings, equals(roundTrip.steamSettings));
        expect(wf.hotWaterData, equals(roundTrip.hotWaterData));
        expect(wf.rinseData, equals(roundTrip.rinseData));
      },
    );
  });

  group('Profile equality + JSON round-trip', () {
    test('default profile (no newlines) round-trips equal', () {
      final p = Defaults.createDefaultProfile();
      expect(Profile.fromJson(p.toJson()), equals(p));
    });

    test('profile with newlines in notes round-trips equal', () {
      final p = Profile(
        version: '2',
        title: 't',
        notes: 'line1\nline2\nline3',
        author: 'a',
        beverageType: BeverageType.espresso,
        steps: [
          ProfileStepPressure(
            name: 'pour',
            transition: TransitionType.fast,
            volume: 100,
            seconds: 30,
            temperature: 93,
            sensor: TemperatureSensor.coffee,
            pressure: 9,
          ),
        ],
        targetVolumeCountStart: 0,
        tankTemperature: 0,
      );
      final rt = Profile.fromJson(p.toJson());
      expect(
        rt.notes,
        equals(p.notes),
        reason:
            'toJson must not escape \\n without fromJson unescaping '
            'it — the WorkflowHandler profile guard relies on '
            'round-trip equality',
      );
      expect(rt, equals(p));
    });
  });

  group('WorkflowContext equality', () {
    test('equal by value', () {
      const a = WorkflowContext(
        targetDoseWeight: 18.0,
        targetYield: 36.0,
        grinderId: 'g1',
        coffeeName: 'Illy',
      );
      const b = WorkflowContext(
        targetDoseWeight: 18.0,
        targetYield: 36.0,
        grinderId: 'g1',
        coffeeName: 'Illy',
      );
      expect(a, equals(b));
      expect(a.hashCode, equals(b.hashCode));
    });

    test('differ when any field differs', () {
      const base = WorkflowContext(targetDoseWeight: 18.0, targetYield: 36.0);
      expect(base, isNot(equals(base.copyWith(targetDoseWeight: 18.5))));
      expect(base, isNot(equals(base.copyWith(grinderId: 'g2'))));
    });

    test('round-trip via toJson/fromJson', () {
      const original = WorkflowContext(
        targetDoseWeight: 18.0,
        targetYield: 36.0,
        grinderId: '123',
        grinderSetting: '5',
        beanBatchId: '456',
        coffeeName: 'Illy',
        coffeeRoaster: 'Mixed',
      );
      final rt = WorkflowContext.fromJson(original.toJson());
      expect(rt, equals(original));
    });
  });
}
