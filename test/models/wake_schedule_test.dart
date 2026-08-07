import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/models/wake_schedule.dart';

void main() {
  group('WakeSchedule', () {
    group('toJson', () {
      test('produces expected format', () {
        final schedule = WakeSchedule(
          id: 'test-id-123',
          hour: 6,
          minute: 30,
          daysOfWeek: {1, 3, 5},
          enabled: true,
        );

        final json = schedule.toJson();

        expect(json['id'], 'test-id-123');
        expect(json['time'], '06:30');
        expect(json['daysOfWeek'], unorderedEquals([1, 3, 5]));
        expect(json['enabled'], true);
      });

      test('zero-pads single digit hours and minutes', () {
        final schedule = WakeSchedule(
          id: 'test-id',
          hour: 5,
          minute: 3,
          daysOfWeek: {},
          enabled: true,
        );

        final json = schedule.toJson();
        expect(json['time'], '05:03');
      });

      test('handles midnight correctly', () {
        final schedule = WakeSchedule(
          id: 'test-id',
          hour: 0,
          minute: 0,
          daysOfWeek: {},
          enabled: false,
        );

        final json = schedule.toJson();
        expect(json['time'], '00:00');
      });

      test('serializes empty daysOfWeek as empty list', () {
        final schedule = WakeSchedule(
          id: 'test-id',
          hour: 12,
          minute: 0,
          daysOfWeek: {},
          enabled: true,
        );

        final json = schedule.toJson();
        expect(json['daysOfWeek'], isEmpty);
      });

      test('includes keepAwakeFor when set', () {
        final schedule = WakeSchedule(
          id: 'test-id',
          hour: 10,
          minute: 0,
          daysOfWeek: {1, 3},
          enabled: true,
          keepAwakeFor: 60,
        );
        final json = schedule.toJson();
        expect(json['keepAwakeFor'], 60);
      });

      test('omits keepAwakeFor when null', () {
        final schedule = WakeSchedule(
          id: 'test-id',
          hour: 10,
          minute: 0,
          daysOfWeek: {},
          enabled: true,
        );
        final json = schedule.toJson();
        expect(json.containsKey('keepAwakeFor'), isFalse);
      });
    });

    group('fromJson', () {
      test('parses time string correctly', () {
        final json = {
          'id': 'test-id-456',
          'time': '14:05',
          'daysOfWeek': [2, 4, 6],
          'enabled': false,
        };

        final schedule = WakeSchedule.fromJson(json);

        expect(schedule.id, 'test-id-456');
        expect(schedule.hour, 14);
        expect(schedule.minute, 5);
        expect(schedule.daysOfWeek, {2, 4, 6});
        expect(schedule.enabled, false);
      });

      test('parses midnight time', () {
        final json = {
          'id': 'test-id',
          'time': '00:00',
          'daysOfWeek': <int>[],
          'enabled': true,
        };

        final schedule = WakeSchedule.fromJson(json);
        expect(schedule.hour, 0);
        expect(schedule.minute, 0);
      });

      test('parses empty daysOfWeek', () {
        final json = {
          'id': 'test-id',
          'time': '08:00',
          'daysOfWeek': <int>[],
          'enabled': true,
        };

        final schedule = WakeSchedule.fromJson(json);
        expect(schedule.daysOfWeek, isEmpty);
      });

      test('parses keepAwakeFor when present', () {
        final json = {
          'id': 'test-id',
          'time': '10:00',
          'daysOfWeek': [1, 3],
          'enabled': true,
          'keepAwakeFor': 60,
        };
        final schedule = WakeSchedule.fromJson(json);
        expect(schedule.keepAwakeFor, 60);
      });

      test('keepAwakeFor is null when absent from JSON', () {
        final json = {
          'id': 'test-id',
          'time': '10:00',
          'daysOfWeek': <int>[],
          'enabled': true,
        };
        final schedule = WakeSchedule.fromJson(json);
        expect(schedule.keepAwakeFor, isNull);
      });

      test('keepAwakeFor 0 is treated as null', () {
        final json = {
          'id': 'test-id',
          'time': '10:00',
          'daysOfWeek': <int>[],
          'enabled': true,
          'keepAwakeFor': 0,
        };
        final schedule = WakeSchedule.fromJson(json);
        expect(schedule.keepAwakeFor, isNull);
      });
    });

    group('toJson/fromJson round-trip', () {
      test('preserves all fields', () {
        final original = WakeSchedule(
          id: 'round-trip-id',
          hour: 7,
          minute: 45,
          daysOfWeek: {1, 2, 3, 4, 5},
          enabled: true,
        );

        final restored = WakeSchedule.fromJson(original.toJson());

        expect(restored.id, original.id);
        expect(restored.hour, original.hour);
        expect(restored.minute, original.minute);
        expect(restored.daysOfWeek, original.daysOfWeek);
        expect(restored.enabled, original.enabled);
      });

      test('preserves disabled schedule', () {
        final original = WakeSchedule(
          id: 'disabled-id',
          hour: 23,
          minute: 59,
          daysOfWeek: {7},
          enabled: false,
        );

        final restored = WakeSchedule.fromJson(original.toJson());

        expect(restored.id, original.id);
        expect(restored.hour, original.hour);
        expect(restored.minute, original.minute);
        expect(restored.daysOfWeek, original.daysOfWeek);
        expect(restored.enabled, original.enabled);
      });

      test('preserves keepAwakeFor through round-trip', () {
        final original = WakeSchedule(
          id: 'keep-awake-id',
          hour: 10,
          minute: 0,
          daysOfWeek: {1, 3},
          enabled: true,
          keepAwakeFor: 120,
        );
        final restored = WakeSchedule.fromJson(original.toJson());
        expect(restored.keepAwakeFor, 120);
      });

      test('preserves null keepAwakeFor through round-trip', () {
        final original = WakeSchedule(
          id: 'no-keep-awake-id',
          hour: 10,
          minute: 0,
          daysOfWeek: {},
          enabled: true,
        );
        final restored = WakeSchedule.fromJson(original.toJson());
        expect(restored.keepAwakeFor, isNull);
      });
    });

    group('matchesTime', () {
      test('returns true when day and time match', () {
        final schedule = WakeSchedule(
          id: 'test-id',
          hour: 6,
          minute: 30,
          daysOfWeek: {1},
          enabled: true,
        );

        final dateTime = DateTime(2026, 2, 23, 6, 30);
        expect(schedule.matchesTime(dateTime), isTrue);
      });

      test('returns false when day does not match', () {
        final schedule = WakeSchedule(
          id: 'test-id',
          hour: 6,
          minute: 30,
          daysOfWeek: {1},
          enabled: true,
        );

        final dateTime = DateTime(2026, 2, 24, 6, 30);
        expect(schedule.matchesTime(dateTime), isFalse);
      });

      test('returns false when minute does not match', () {
        final schedule = WakeSchedule(
          id: 'test-id',
          hour: 6,
          minute: 30,
          daysOfWeek: {1},
          enabled: true,
        );

        final dateTime = DateTime(2026, 2, 23, 6, 31);
        expect(schedule.matchesTime(dateTime), isFalse);
      });

      test('returns false when hour does not match', () {
        final schedule = WakeSchedule(
          id: 'test-id',
          hour: 6,
          minute: 30,
          daysOfWeek: {1},
          enabled: true,
        );

        final dateTime = DateTime(2026, 2, 23, 7, 30);
        expect(schedule.matchesTime(dateTime), isFalse);
      });

      test('empty daysOfWeek matches every day', () {
        final schedule = WakeSchedule(
          id: 'test-id',
          hour: 8,
          minute: 0,
          daysOfWeek: {},
          enabled: true,
        );

        for (int day = 23; day <= 29; day++) {
          final dateTime = DateTime(2026, 2, day, 8, 0);
          expect(
            schedule.matchesTime(dateTime),
            isTrue,
            reason: 'Should match on day $day (weekday ${dateTime.weekday})',
          );
        }
      });

      test('disabled schedule never matches', () {
        final schedule = WakeSchedule(
          id: 'test-id',
          hour: 6,
          minute: 30,
          daysOfWeek: {},
          enabled: false,
        );

        final dateTime = DateTime(2026, 2, 23, 6, 30);
        expect(schedule.matchesTime(dateTime), isFalse);
      });
    });

    group('copyWith', () {
      test('copies with changed fields', () {
        final original = WakeSchedule(
          id: 'original-id',
          hour: 6,
          minute: 30,
          daysOfWeek: {1, 2, 3},
          enabled: true,
        );

        final modified = original.copyWith(hour: 7, minute: 0, enabled: false);

        expect(modified.id, 'original-id');
        expect(modified.hour, 7);
        expect(modified.minute, 0);
        expect(modified.daysOfWeek, {1, 2, 3});
        expect(modified.enabled, false);
      });

      test('preserves all fields when no changes specified', () {
        final original = WakeSchedule(
          id: 'keep-id',
          hour: 14,
          minute: 15,
          daysOfWeek: {6, 7},
          enabled: true,
        );

        final copy = original.copyWith();

        expect(copy.id, original.id);
        expect(copy.hour, original.hour);
        expect(copy.minute, original.minute);
        expect(copy.daysOfWeek, original.daysOfWeek);
        expect(copy.enabled, original.enabled);
      });

      test('can change daysOfWeek', () {
        final original = WakeSchedule(
          id: 'test-id',
          hour: 6,
          minute: 30,
          daysOfWeek: {1, 2, 3},
          enabled: true,
        );

        final modified = original.copyWith(daysOfWeek: {4, 5});

        expect(modified.daysOfWeek, {4, 5});
      });

      test('can set keepAwakeFor', () {
        final original = WakeSchedule(
          id: 'test-id',
          hour: 10,
          minute: 0,
          daysOfWeek: {},
          enabled: true,
        );
        final modified = original.copyWith(keepAwakeFor: 60);
        expect(modified.keepAwakeFor, 60);
      });

      test('can clear keepAwakeFor to null', () {
        final original = WakeSchedule(
          id: 'test-id',
          hour: 10,
          minute: 0,
          daysOfWeek: {},
          enabled: true,
          keepAwakeFor: 60,
        );
        final modified = original.copyWith(clearKeepAwakeFor: true);
        expect(modified.keepAwakeFor, isNull);
      });
    });

    group('create', () {
      test('normalizes 0 keepAwakeFor to null', () {
        final s = WakeSchedule.create(hour: 7, minute: 0, keepAwakeFor: 0);
        expect(s.keepAwakeFor, isNull);
      });

      test('normalizes negative keepAwakeFor to null', () {
        final s = WakeSchedule.create(hour: 7, minute: 0, keepAwakeFor: -5);
        expect(s.keepAwakeFor, isNull);
      });
    });

    group('serializeList/deserializeList', () {
      test('round-trip preserves all schedules', () {
        final schedules = [
          WakeSchedule(
            id: 'id-1',
            hour: 6,
            minute: 30,
            daysOfWeek: {1, 2, 3, 4, 5},
            enabled: true,
          ),
          WakeSchedule(
            id: 'id-2',
            hour: 8,
            minute: 0,
            daysOfWeek: {6, 7},
            enabled: false,
          ),
          WakeSchedule(
            id: 'id-3',
            hour: 0,
            minute: 0,
            daysOfWeek: {},
            enabled: true,
          ),
        ];

        final jsonString = WakeSchedule.serializeList(schedules);
        final restored = WakeSchedule.deserializeList(jsonString);

        expect(restored.length, 3);

        for (int i = 0; i < schedules.length; i++) {
          expect(restored[i].id, schedules[i].id);
          expect(restored[i].hour, schedules[i].hour);
          expect(restored[i].minute, schedules[i].minute);
          expect(restored[i].daysOfWeek, schedules[i].daysOfWeek);
          expect(restored[i].enabled, schedules[i].enabled);
        }
      });

      test('handles empty list', () {
        final jsonString = WakeSchedule.serializeList([]);
        final restored = WakeSchedule.deserializeList(jsonString);

        expect(restored, isEmpty);
      });

      test('produces valid JSON string', () {
        final schedules = [
          WakeSchedule(
            id: 'id-1',
            hour: 6,
            minute: 30,
            daysOfWeek: {1},
            enabled: true,
          ),
        ];

        final jsonString = WakeSchedule.serializeList(schedules);

        final decoded = jsonDecode(jsonString);
        expect(decoded, isList);
        expect((decoded as List).length, 1);
      });
    });
  });
}
