part of '../webserver_service.dart';

class PresenceHandler {
  final PresenceController _presenceController;
  final SettingsController _settingsController;
  final log = Logger('PresenceHandler');

  PresenceHandler({
    required PresenceController presenceController,
    required SettingsController settingsController,
  }) : _presenceController = presenceController,
       _settingsController = settingsController;

  void addRoutes(RouterPlus app) {
    app.post('/api/v1/machine/heartbeat', _heartbeatHandler);
    app.get('/api/v1/presence/settings', _getSettingsHandler);
    app.post('/api/v1/presence/settings', _updateSettingsHandler);
    app.get('/api/v1/presence/schedules', _getSchedulesHandler);
    app.post('/api/v1/presence/schedules', _addScheduleHandler);
    app.put('/api/v1/presence/schedules/<id>', _updateScheduleHandler);
    app.delete('/api/v1/presence/schedules/<id>', _deleteScheduleHandler);
  }

  Future<Response> _heartbeatHandler(Request request) async {
    try {
      final seconds = _presenceController.heartbeat();
      return jsonOk({'timeout': seconds});
    } catch (e, st) {
      log.severe('Error in heartbeat handler', e, st);
      return jsonError({'error': e.toString()});
    }
  }

  Future<Response> _getSettingsHandler(Request request) async {
    try {
      final schedulesJson = _settingsController.wakeSchedules;
      List<Map<String, dynamic>> schedules = [];
      if (schedulesJson.isNotEmpty && schedulesJson != '[]') {
        schedules = WakeSchedule.deserializeList(
          schedulesJson,
        ).map((s) => s.toJson()).toList();
      }

      return jsonOk({
        'userPresenceEnabled': _settingsController.userPresenceEnabled,
        'sleepTimeoutMinutes': _settingsController.sleepTimeoutMinutes,
        'keepAwakeUntil': _presenceController.keepAwakeUntil?.toIso8601String(),
        'schedules': schedules,
      });
    } catch (e, st) {
      log.severe('Error in get settings handler', e, st);
      return jsonError({'error': e.toString()});
    }
  }

  Future<Response> _updateSettingsHandler(Request request) async {
    try {
      final body = await request.readAsString();
      final decoded = jsonDecode(body);
      if (decoded is! Map<String, dynamic>) {
        return jsonBadRequest({'error': 'Request body must be a JSON object'});
      }

      bool? userPresenceEnabled;
      int? sleepTimeoutMinutes;

      if (decoded.containsKey('userPresenceEnabled')) {
        final v = decoded['userPresenceEnabled'];
        if (v is! bool) {
          return jsonBadRequest({
            'error': 'userPresenceEnabled must be a boolean',
          });
        }
        userPresenceEnabled = v;
      }

      if (decoded.containsKey('sleepTimeoutMinutes')) {
        final v = decoded['sleepTimeoutMinutes'];
        if (v is! int) {
          return jsonBadRequest({
            'error': 'sleepTimeoutMinutes must be an integer',
          });
        }
        sleepTimeoutMinutes = normalizeSleepTimeoutPreferenceMinutes(v);
      }

      if (userPresenceEnabled != null) {
        await _settingsController.setUserPresenceEnabled(userPresenceEnabled);
      }
      if (sleepTimeoutMinutes != null) {
        await _settingsController.setSleepTimeoutMinutes(sleepTimeoutMinutes);
      }

      return jsonOk({
        'userPresenceEnabled': _settingsController.userPresenceEnabled,
        'sleepTimeoutMinutes': _settingsController.sleepTimeoutMinutes,
      });
    } on FormatException {
      return jsonBadRequest({'error': 'Malformed JSON'});
    } catch (e, st) {
      log.severe('Error in update settings handler', e, st);
      return jsonError({'error': e.toString()});
    }
  }

  Future<Response> _getSchedulesHandler(Request request) async {
    try {
      final schedulesJson = _settingsController.wakeSchedules;
      if (schedulesJson.isEmpty || schedulesJson == '[]') {
        return jsonOk([]);
      }

      final schedules = WakeSchedule.deserializeList(schedulesJson);
      return jsonOk(schedules.map((s) => s.toJson()).toList());
    } catch (e, st) {
      log.severe('Error in get schedules handler', e, st);
      return jsonError({'error': e.toString()});
    }
  }

  Future<Response> _addScheduleHandler(Request request) async {
    try {
      final body = await request.readAsString();
      final json = jsonDecode(body) as Map<String, dynamic>;

      final keepAwakeFor = json['keepAwakeFor'] as int?;
      if (keepAwakeFor != null && (keepAwakeFor < 0 || keepAwakeFor > 720)) {
        return jsonBadRequest({
          'error': 'keepAwakeFor must be 1-720 minutes, or 0/null to clear',
        });
      }

      final hour =
          json['hour'] as int? ??
          int.parse((json['time'] as String).split(':')[0]);
      final minute =
          json['minute'] as int? ??
          int.parse((json['time'] as String).split(':')[1]);
      if (hour < 0 || hour > 23 || minute < 0 || minute > 59) {
        return jsonBadRequest({
          'error': 'time must be hour 0-23 and minute 0-59',
        });
      }
      final daysOfWeek = json.containsKey('daysOfWeek')
          ? (json['daysOfWeek'] as List).cast<int>().toSet()
          : <int>{};
      if (daysOfWeek.any((day) => day < 1 || day > 7)) {
        return jsonBadRequest({
          'error': 'daysOfWeek must contain weekdays 1 to 7',
        });
      }

      final schedule = WakeSchedule.create(
        hour: hour,
        minute: minute,
        daysOfWeek: daysOfWeek,
        enabled: json['enabled'] as bool? ?? true,
        keepAwakeFor: keepAwakeFor,
      );

      final schedulesJson = _settingsController.wakeSchedules;
      List<WakeSchedule> schedules = [];
      if (schedulesJson.isNotEmpty && schedulesJson != '[]') {
        schedules = WakeSchedule.deserializeList(schedulesJson);
      }

      schedules.add(schedule);
      await _settingsController.setWakeSchedules(
        WakeSchedule.serializeList(schedules),
      );

      return jsonCreated(schedule.toJson());
    } catch (e, st) {
      log.severe('Error in add schedule handler', e, st);
      return jsonError({'error': e.toString()});
    }
  }

  Future<Response> _updateScheduleHandler(Request request, String id) async {
    try {
      final schedulesJson = _settingsController.wakeSchedules;
      if (schedulesJson.isEmpty || schedulesJson == '[]') {
        return jsonNotFound({'error': 'Schedule not found', 'id': id});
      }

      final schedules = WakeSchedule.deserializeList(schedulesJson);
      final index = schedules.indexWhere((s) => s.id == id);
      if (index == -1) {
        return jsonNotFound({'error': 'Schedule not found', 'id': id});
      }

      final body = await request.readAsString();
      final json = jsonDecode(body) as Map<String, dynamic>;
      final existing = schedules[index];

      int hour = existing.hour;
      int minute = existing.minute;
      if (json.containsKey('time')) {
        final timeParts = (json['time'] as String).split(':');
        hour = int.parse(timeParts[0]);
        minute = int.parse(timeParts[1]);
      }
      if (json.containsKey('hour')) hour = json['hour'] as int;
      if (json.containsKey('minute')) minute = json['minute'] as int;
      if (hour < 0 || hour > 23 || minute < 0 || minute > 59) {
        return jsonBadRequest({
          'error': 'time must be hour 0-23 and minute 0-59',
        });
      }
      Set<int>? daysOfWeek;
      if (json.containsKey('daysOfWeek')) {
        daysOfWeek = (json['daysOfWeek'] as List).cast<int>().toSet();
        if (daysOfWeek.any((day) => day < 1 || day > 7)) {
          return jsonBadRequest({
            'error': 'daysOfWeek must contain weekdays 1 to 7',
          });
        }
      }

      int? keepAwakeFor = existing.keepAwakeFor;
      bool clearKeepAwakeFor = false;
      if (json.containsKey('keepAwakeFor')) {
        final val = json['keepAwakeFor'] as int?;
        if (val != null && (val < 0 || val > 720)) {
          return jsonBadRequest({
            'error': 'keepAwakeFor must be 1-720 minutes, or 0/null to clear',
          });
        }
        if (val == null || val == 0) {
          clearKeepAwakeFor = true;
          keepAwakeFor = null;
        } else {
          keepAwakeFor = val;
        }
      }

      final updated = existing.copyWith(
        hour: hour,
        minute: minute,
        daysOfWeek: daysOfWeek,
        enabled: json.containsKey('enabled') ? json['enabled'] as bool : null,
        keepAwakeFor: keepAwakeFor,
        clearKeepAwakeFor: clearKeepAwakeFor,
      );

      schedules[index] = updated;
      await _settingsController.setWakeSchedules(
        WakeSchedule.serializeList(schedules),
      );

      return jsonOk(updated.toJson());
    } catch (e, st) {
      log.severe('Error in update schedule handler', e, st);
      return jsonError({'error': e.toString()});
    }
  }

  Future<Response> _deleteScheduleHandler(Request request, String id) async {
    try {
      final schedulesJson = _settingsController.wakeSchedules;
      if (schedulesJson.isEmpty || schedulesJson == '[]') {
        return jsonNotFound({'error': 'Schedule not found', 'id': id});
      }

      final schedules = WakeSchedule.deserializeList(schedulesJson);
      final index = schedules.indexWhere((s) => s.id == id);
      if (index == -1) {
        return jsonNotFound({'error': 'Schedule not found', 'id': id});
      }

      schedules.removeAt(index);
      await _settingsController.setWakeSchedules(
        WakeSchedule.serializeList(schedules),
      );

      return jsonOk({'deleted': id});
    } catch (e, st) {
      log.severe('Error in delete schedule handler', e, st);
      return jsonError({'error': e.toString()});
    }
  }
}
