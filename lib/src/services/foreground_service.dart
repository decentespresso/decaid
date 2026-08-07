import 'dart:async';

import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:logging/logging.dart';

class ForegroundTaskService {
  static final _log = Logger("ForegroundTaskService");

  static ForegroundServiceGraceTimer? _graceTimer;
  static StreamSubscription? _machineSubscription;

  static void init() {
    FlutterForegroundTask.init(
      androidNotificationOptions: AndroidNotificationOptions(
        channelId: 'foreground_service',
        channelName: 'Foreground Service Notification',
        channelDescription:
            'This notification appears when the foreground service is running.',
        channelImportance: NotificationChannelImportance.LOW,
        priority: NotificationPriority.LOW,
      ),
      iosNotificationOptions: const IOSNotificationOptions(
        showNotification: true,
        playSound: false,
      ),
      foregroundTaskOptions: ForegroundTaskOptions(
        eventAction: ForegroundTaskEventAction.repeat(60000),
        autoRunOnBoot: false,
        autoRunOnMyPackageReplaced: false,
        allowWakeLock: true,
        allowWifiLock: true,
      ),
    );
  }

  static Future<void> start() async {
    try {
      final isRunning = await FlutterForegroundTask.isRunningService;
      if (isRunning) {
        _log.info("Foreground service already running");
        return;
      }

      final started = await FlutterForegroundTask.startService(
        notificationTitle: "Streamline Active",
        notificationText: "Maintaining connections",
        callback: startCallback,
      );

      switch (started) {
        case ServiceRequestSuccess():
          _log.info("Foreground service started successfully");
        case ServiceRequestFailure(:final error):
          _log.warning("Failed to start foreground service: $error");
      }
    } catch (e, st) {
      _log.severe("Error starting foreground service", e, st);
    }
  }

  /// Stops only the native foreground service without tearing down
  /// the machine subscription or grace timer. Used by the grace timer's
  /// auto-stop so that reconnection can still be detected.
  static Future<void> _stopServiceOnly() async {
    try {
      final isRunning = await FlutterForegroundTask.isRunningService;
      if (!isRunning) {
        _log.fine("Foreground service not running, nothing to stop");
        return;
      }

      final stopped = await FlutterForegroundTask.stopService();
      switch (stopped) {
        case ServiceRequestSuccess():
          _log.info("Foreground service stopped successfully");
        case ServiceRequestFailure(:final error):
          _log.warning("Failed to stop foreground service: $error");
      }
    } catch (e, st) {
      _log.severe("Error stopping foreground service", e, st);
    }
  }

  /// Full stop: tears down subscription, grace timer, and native service.
  /// Use for explicit exit (e.g., user presses Exit button).
  static Future<void> stop() async {
    _machineSubscription?.cancel();
    _machineSubscription = null;
    _graceTimer?.dispose();
    _graceTimer = null;
    await _stopServiceOnly();
  }

  /// Call once after start() to wire auto-stop to machine connection state.
  /// Safe to call multiple times (e.g., on hot restart) — cancels previous subscription.
  static void watchMachineConnection(Stream<dynamic> machineStream) {
    _machineSubscription?.cancel();
    _graceTimer?.dispose();
    _graceTimer = ForegroundServiceGraceTimer(
      onStop: () => _stopServiceOnly(),
      onStart: () => start(),
    );

    bool isFirstEmission = true;
    _machineSubscription = machineStream.listen((machine) {
      if (isFirstEmission && machine == null) {
        isFirstEmission = false;
        return;
      }
      isFirstEmission = false;
      if (machine != null) {
        _graceTimer?.onMachineConnected();
      } else {
        _graceTimer?.onMachineDisconnected();
      }
    });
  }
}

@pragma('vm:entry-point')
void startCallback() {
  FlutterForegroundTask.setTaskHandler(FirstTaskHandler());
}

class FirstTaskHandler extends TaskHandler {
  final _log = Logger("ForegroundTaskHandler");
  int _eventCount = 0;

  @override
  Future<void> onStart(DateTime timestamp, TaskStarter sendPort) async {
    _log.info("Foreground service started at $timestamp");
  }

  @override
  Future<void> onDestroy(DateTime timestamp, bool isTimeout) async {
    _log.info("Foreground service destroyed. Timeout: $isTimeout");
  }

  @override
  void onRepeatEvent(DateTime timestamp) {
    _eventCount++;

    if (_eventCount % 5 == 0) {
      _log.fine(
        'Foreground service heartbeat: $_eventCount events, uptime: ${_formatUptime()}',
      );
    }
  }

  @override
  void onNotificationPressed() {
    _log.info('Notification tapped - bringing app to foreground');
  }

  String _formatUptime() {
    final minutes = _eventCount;
    if (minutes < 60) {
      return '${minutes}m';
    }
    final hours = minutes ~/ 60;
    final remainingMinutes = minutes % 60;
    return '${hours}h ${remainingMinutes}m';
  }
}

class ForegroundServiceGraceTimer {
  final Duration gracePeriod;
  final Future<void> Function() onStop;
  final Future<void> Function() onStart;
  final _log = Logger("ForegroundServiceGraceTimer");

  Timer? _graceTimer;
  bool _serviceStopped = false;

  ForegroundServiceGraceTimer({
    this.gracePeriod = const Duration(minutes: 5),
    required this.onStop,
    required this.onStart,
  });

  Future<void> _updateNotification(String title, String text) async {
    try {
      final isRunning = await FlutterForegroundTask.isRunningService;
      if (isRunning) {
        await FlutterForegroundTask.updateService(
          notificationTitle: title,
          notificationText: text,
        );
      }
    } catch (e) {
      _log.warning('Failed to update notification: $e');
    }
  }

  void onMachineConnected() {
    _graceTimer?.cancel();
    _graceTimer = null;

    if (_serviceStopped) {
      _log.info('Machine reconnected - restarting foreground service');
      _serviceStopped = false;
      onStart()
          .then(
            (_) => _updateNotification('Streamline Active', 'Connected to DE1'),
          )
          .catchError(
            (e) => _log.warning('Failed to restart foreground service: $e'),
          );
    } else {
      _updateNotification('Streamline Active', 'Connected to DE1');
    }
  }

  void onMachineDisconnected() {
    _graceTimer?.cancel();
    _log.info(
      'Machine disconnected - starting ${gracePeriod.inMinutes}m grace period',
    );
    _graceTimer = Timer(gracePeriod, () async {
      _log.info('Grace period expired - stopping foreground service');
      _serviceStopped = true;
      await onStop();
    });
    _updateNotification(
      'Streamline: Disconnected',
      'Will stop in ${gracePeriod.inMinutes} minutes if no reconnection',
    );
  }

  void dispose() {
    _graceTimer?.cancel();
  }
}
