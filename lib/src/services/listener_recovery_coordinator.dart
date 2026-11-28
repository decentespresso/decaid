import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:logging/logging.dart';
import 'package:reaprime/src/services/webserver/api_listener.dart';
import 'package:reaprime/src/webui_support/webui_service.dart';

class ListenerRecoveryCoordinator {
  ListenerRecoveryCoordinator({
    required this.apiListener,
    required this.webUIService,
    this.retryDelay = const Duration(milliseconds: 150),
    this.maxAttempts = 2,
  });

  final ApiListener apiListener;
  final WebUIService webUIService;
  final Duration retryDelay;
  final int maxAttempts;
  final ValueNotifier<String?> failure = ValueNotifier<String?>(null);
  final _log = Logger('ListenerRecoveryCoordinator');

  Future<bool>? _recovery;
  bool _disposed = false;

  Future<bool> onResumed() => _recover();

  Future<bool> retry() => _recover();

  Future<bool> _recover() {
    if (_disposed) return Future<bool>.value(false);
    final current = _recovery;
    if (current != null) return current;
    final recovery = _runRecovery();
    _recovery = recovery.whenComplete(() => _recovery = null);
    return _recovery!;
  }

  Future<bool> _runRecovery() async {
    var changed = false;
    Object? lastError;
    StackTrace? lastStack;
    for (var attempt = 0; attempt < maxAttempts; attempt++) {
      if (_disposed) return changed;
      try {
        final apiHealthy = await apiListener.checkHealth();
        if (_disposed) return changed;
        if (!apiHealthy) {
          await apiListener.recover(isCancelled: () => _disposed);
          changed = true;
        }

        if (_disposed) return changed;
        if (webUIService.hasActiveSkin) {
          final webUIHealthy = await webUIService.checkHealth();
          if (_disposed) return changed;
          if (!webUIHealthy) {
            await webUIService.recover(isCancelled: () => _disposed);
            changed = true;
          }
        }
        if (_disposed) return changed;
        final apiReady = await apiListener.checkHealth();
        if (_disposed) return changed;
        if (!apiReady) {
          throw StateError('API listener is not responsive after recovery');
        }
        if (webUIService.hasActiveSkin) {
          final webUIReady = await webUIService.checkHealth();
          if (_disposed) return changed;
          if (!webUIReady) {
            throw StateError('WebUI listener is not responsive after recovery');
          }
        }
        if (_disposed) return changed;
        failure.value = null;
        return changed;
      } catch (error, stackTrace) {
        lastError = error;
        lastStack = stackTrace;
        _log.warning(
          'Listener recovery attempt ${attempt + 1} failed',
          error,
          stackTrace,
        );
        if (attempt + 1 < maxAttempts && retryDelay > Duration.zero) {
          await Future<void>.delayed(retryDelay);
        }
      }
    }
    if (_disposed) return changed;
    final message = 'Listener recovery failed: $lastError';
    failure.value = message;
    Error.throwWithStackTrace(
      lastError ?? StateError(message),
      lastStack ?? StackTrace.current,
    );
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    failure.dispose();
  }
}
