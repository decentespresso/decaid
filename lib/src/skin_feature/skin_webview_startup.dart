import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:logging/logging.dart';

class SkinWebViewStartup extends StatefulWidget {
  final TargetPlatform platform;
  final bool isLoading;
  final bool isCreated;
  final String skinId;
  final int port;
  final VoidCallback onOpenInBrowser;
  final VoidCallback onDashboard;
  final Widget child;

  const SkinWebViewStartup({
    super.key,
    required this.platform,
    required this.isLoading,
    required this.isCreated,
    required this.skinId,
    required this.port,
    required this.onOpenInBrowser,
    required this.onDashboard,
    required this.child,
  });

  @override
  State<SkinWebViewStartup> createState() => _SkinWebViewStartupState();
}

class _SkinWebViewStartupState extends State<SkinWebViewStartup> {
  final _elapsed = Stopwatch();
  late final _attemptId = identityHashCode(this).toRadixString(16);
  Timer? _timer;
  bool _timedOut = false;

  @override
  void initState() {
    super.initState();
    if (widget.platform == TargetPlatform.windows && widget.isLoading) {
      _elapsed.start();
      _logStartup('started');
      _timer = Timer(const Duration(seconds: 30), () {
        setState(() => _timedOut = true);
        _logStartup('timeout', level: Level.WARNING);
      });
    }
  }

  @override
  void didUpdateWidget(covariant SkinWebViewStartup oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (_elapsed.isRunning) {
      if (!oldWidget.isCreated && widget.isCreated) _logStartup('created');
      if (!widget.isLoading) {
        _logStartup(_timedOut ? 'recovered' : 'loaded');
        _elapsed.stop();
      }
    }
    if (!widget.isLoading) {
      _timer?.cancel();
      _timedOut = false;
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    if (_elapsed.isRunning) {
      _logStartup('aborted');
      _elapsed.stop();
    }
    super.dispose();
  }

  void _logStartup(String action, {Level level = Level.INFO}) {
    Logger('SkinView').log(
      level,
      jsonEncode({
        'event': 'windowsSkinStartup',
        'action': action,
        'attemptId': _attemptId,
        'skinId': widget.skinId,
        'port': widget.port,
        'stage': action == 'created'
            ? 'page-load'
            : !widget.isLoading
            ? 'loaded'
            : widget.isCreated
            ? 'page-load'
            : 'webview-creation',
        'elapsedMs': _elapsed.elapsedMilliseconds,
        'webViewCreated': widget.isCreated,
        'timedOut': _timedOut,
      }),
    );
  }

  @override
  Widget build(BuildContext context) => Stack(
    clipBehavior: widget.platform == TargetPlatform.android
        ? Clip.none
        : Clip.hardEdge,
    children: [
      Positioned.fill(
        right: widget.platform == TargetPlatform.android ? -1 : 0,
        bottom: widget.platform == TargetPlatform.android ? -1 : 0,
        child: ExcludeFocus(
          excluding: _timedOut,
          child: ExcludeSemantics(excluding: _timedOut, child: widget.child),
        ),
      ),
      if (_timedOut)
        Positioned.fill(
          child: ColoredBox(
            color: Theme.of(context).colorScheme.surface,
            child: SkinWebViewError(
              message: widget.isCreated
                  ? 'The skin did not finish loading within 30 seconds.'
                  : 'The embedded browser did not start within 30 seconds.',
              onOpenInBrowser: widget.onOpenInBrowser,
              onDashboard: widget.onDashboard,
            ),
          ),
        )
      else if (widget.isLoading)
        const Center(child: CircularProgressIndicator()),
    ],
  );
}

class SkinWebViewError extends StatelessWidget {
  final String message;
  final VoidCallback? onOpenInBrowser;
  final VoidCallback onDashboard;

  const SkinWebViewError({
    super.key,
    required this.message,
    this.onOpenInBrowser,
    required this.onDashboard,
  });

  @override
  Widget build(BuildContext context) => Center(
    child: SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        spacing: 12,
        children: [
          const Icon(Icons.error_outline, size: 48, color: Colors.red),
          Text(
            'WebView Error',
            style: Theme.of(context).textTheme.headlineSmall,
          ),
          Semantics(
            liveRegion: true,
            child: Text(
              message,
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodyMedium,
            ),
          ),
          Wrap(
            alignment: WrapAlignment.center,
            spacing: 12,
            runSpacing: 12,
            children: [
              if (onOpenInBrowser != null)
                ElevatedButton.icon(
                  onPressed: onOpenInBrowser,
                  icon: const Icon(Icons.open_in_browser),
                  label: const Text('Open in Browser'),
                ),
              ElevatedButton.icon(
                onPressed: onDashboard,
                icon: const Icon(Icons.dashboard),
                label: const Text('Go to Dashboard'),
              ),
            ],
          ),
        ],
      ),
    ),
  );
}
