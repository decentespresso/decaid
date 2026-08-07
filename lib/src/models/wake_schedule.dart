import 'dart:convert';

import 'package:uuid/uuid.dart';

class WakeSchedule {
  final String id;
  final int hour;
  final int minute;
  final Set<int> daysOfWeek;
  final bool enabled;

  final int? keepAwakeFor;

  const WakeSchedule({
    required this.id,
    required this.hour,
    required this.minute,
    required this.daysOfWeek,
    required this.enabled,
    this.keepAwakeFor,
  });

  factory WakeSchedule.create({
    required int hour,
    required int minute,
    Set<int> daysOfWeek = const {},
    bool enabled = true,
    int? keepAwakeFor,
  }) {
    final keepAwake = keepAwakeFor != null && keepAwakeFor > 0
        ? keepAwakeFor
        : null;
    return WakeSchedule(
      id: const Uuid().v4(),
      hour: hour,
      minute: minute,
      daysOfWeek: daysOfWeek,
      enabled: enabled,
      keepAwakeFor: keepAwake,
    );
  }

  factory WakeSchedule.fromJson(Map<String, dynamic> json) {
    final timeParts = (json['time'] as String).split(':');
    final days = (json['daysOfWeek'] as List).cast<int>();
    final keepAwake = json['keepAwakeFor'] as int?;

    return WakeSchedule(
      id: json['id'] as String,
      hour: int.parse(timeParts[0]),
      minute: int.parse(timeParts[1]),
      daysOfWeek: days.toSet(),
      enabled: json['enabled'] as bool,
      keepAwakeFor: keepAwake != null && keepAwake > 0 ? keepAwake : null,
    );
  }

  Map<String, dynamic> toJson() {
    final json = <String, dynamic>{
      'id': id,
      'time':
          '${hour.toString().padLeft(2, '0')}:${minute.toString().padLeft(2, '0')}',
      'daysOfWeek': daysOfWeek.toList()..sort(),
      'enabled': enabled,
    };
    if (keepAwakeFor != null) {
      json['keepAwakeFor'] = keepAwakeFor;
    }
    return json;
  }

  bool matchesTime(DateTime dateTime) {
    if (!enabled) return false;
    if (dateTime.hour != hour || dateTime.minute != minute) return false;
    if (daysOfWeek.isNotEmpty && !daysOfWeek.contains(dateTime.weekday)) {
      return false;
    }
    return true;
  }

  WakeSchedule copyWith({
    String? id,
    int? hour,
    int? minute,
    Set<int>? daysOfWeek,
    bool? enabled,
    int? keepAwakeFor,
    bool clearKeepAwakeFor = false,
  }) {
    return WakeSchedule(
      id: id ?? this.id,
      hour: hour ?? this.hour,
      minute: minute ?? this.minute,
      daysOfWeek: daysOfWeek ?? this.daysOfWeek,
      enabled: enabled ?? this.enabled,
      keepAwakeFor: clearKeepAwakeFor
          ? null
          : (keepAwakeFor ?? this.keepAwakeFor),
    );
  }

  static String serializeList(List<WakeSchedule> schedules) {
    return jsonEncode(schedules.map((s) => s.toJson()).toList());
  }

  static List<WakeSchedule> deserializeList(String jsonString) {
    final list = jsonDecode(jsonString) as List;
    return list
        .map((item) => WakeSchedule.fromJson(item as Map<String, dynamic>))
        .toList();
  }
}
