import 'dart:async';

import 'package:flutter/material.dart';
import 'package:logging/logging.dart';
import 'package:reaprime/src/services/app_startup_coordinator.dart';

class StartupDiscoveryRecovery extends StatefulWidget {
  const StartupDiscoveryRecovery({
    super.key,
    required this.startupCoordinator,
    required this.child,
  });

  final AppStartupCoordinator startupCoordinator;
  final Widget child;

  @override
  State<StartupDiscoveryRecovery> createState() =>
      _StartupDiscoveryRecoveryState();
}

class _StartupDiscoveryRecoveryState extends State<StartupDiscoveryRecovery> {
  static final _log = Logger('StartupDiscoveryRecovery');

  late AppStartupState _state;
  StreamSubscription<AppStartupState>? _stateSubscription;

  @override
  void initState() {
    super.initState();
    _state = widget.startupCoordinator.state;
    _stateSubscription = widget.startupCoordinator.stateStream.listen((state) {
      if (!mounted || identical(state, _state)) return;
      setState(() => _state = state);
    });
  }

  @override
  void dispose() {
    _stateSubscription?.cancel();
    super.dispose();
  }

  void _retry() {
    unawaited(
      widget.startupCoordinator.retry().catchError((
        Object error,
        StackTrace stack,
      ) {
        _log.warning('Startup recovery failed', error, stack);
      }),
    );
  }

  void _retryForeground() {
    unawaited(
      widget.startupCoordinator.retryForeground().catchError((
        Object error,
        StackTrace stack,
      ) {
        _log.warning('Foreground recovery failed', error, stack);
      }),
    );
  }

  bool get _startupPending => _state.status == AppStartupStatus.initializing;

  VoidCallback? get _recoveryAction {
    if (!_state.discoveryRecoveryRequired) return null;
    if (_startupPending) return null;
    return _retry;
  }

  VoidCallback? get _foregroundRecoveryAction {
    if (!_state.foregroundRecoveryRequired) return null;
    if (_startupPending || _state.foregroundRetryPending) return null;
    return _retryForeground;
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        _StartupRecoveryNotice(
          title: 'Some device services did not start.',
          message: _state.discoveryRecovery,
          actionLabel: 'Retry',
          onRetry: _recoveryAction,
        ),
        _StartupRecoveryNotice(
          title: 'Android foreground service did not start.',
          message: _state.foregroundRecovery,
          actionLabel: 'Retry foreground service',
          onRetry: _foregroundRecoveryAction,
        ),
        Expanded(child: widget.child),
      ],
    );
  }
}

class _StartupRecoveryNotice extends StatelessWidget {
  final String title;
  final String? message;
  final String actionLabel;
  final VoidCallback? onRetry;

  const _StartupRecoveryNotice({
    required this.title,
    required this.message,
    required this.actionLabel,
    required this.onRetry,
  });

  @override
  Widget build(BuildContext context) {
    final detail = message;
    if (detail == null) return const SizedBox.shrink();
    final theme = Theme.of(context);
    return Material(
      color: theme.colorScheme.errorContainer,
      child: SafeArea(
        bottom: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 8, 8),
          child: Row(
            children: [
              Icon(
                Icons.warning_amber_rounded,
                color: theme.colorScheme.onErrorContainer,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  spacing: 2,
                  children: [
                    Semantics(
                      liveRegion: true,
                      child: Text(
                        title,
                        style: theme.textTheme.titleSmall?.copyWith(
                          color: theme.colorScheme.onErrorContainer,
                        ),
                      ),
                    ),
                    Text(
                      detail,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onErrorContainer,
                      ),
                    ),
                  ],
                ),
              ),
              TextButton(onPressed: onRetry, child: Text(actionLabel)),
            ],
          ),
        ),
      ),
    );
  }
}
