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

  VoidCallback? get _recoveryAction {
    if (!_state.discoveryRecoveryRequired) return null;
    if (_state.status == AppStartupStatus.initializing) return null;
    return _retry;
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        _StartupDiscoveryRecoveryNotice(
          message: _state.discoveryRecovery,
          onRetry: _recoveryAction,
        ),
        Expanded(child: widget.child),
      ],
    );
  }
}

class _StartupDiscoveryRecoveryNotice extends StatelessWidget {
  final String? message;
  final VoidCallback? onRetry;

  const _StartupDiscoveryRecoveryNotice({
    required this.message,
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
                        'Some device services did not start.',
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
              TextButton(onPressed: onRetry, child: const Text('Retry')),
            ],
          ),
        ),
      ),
    );
  }
}
