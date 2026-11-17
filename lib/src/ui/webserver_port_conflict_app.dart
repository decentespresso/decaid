import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widget_previews.dart';
import 'package:reaprime/src/services/webserver/port_binding.dart';
import 'package:reaprime/src/ui/startup_failure_shell.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

class WebServerPortConflictApp extends StatelessWidget {
  const WebServerPortConflictApp({
    super.key,
    required this.port,
    this.probe = probePortIsFree,
  });

  final int port;

  final PortProbe probe;

  @override
  Widget build(BuildContext context) {
    return StartupFailureShell(
      child: WebServerPortConflictScreen(port: port, probe: probe),
    );
  }
}

class WebServerPortConflictScreen extends StatefulWidget {
  const WebServerPortConflictScreen({
    super.key,
    required this.port,
    this.probe = probePortIsFree,
  });

  final int port;

  final PortProbe probe;

  @override
  State<WebServerPortConflictScreen> createState() =>
      _WebServerPortConflictScreenState();
}

class _WebServerPortConflictScreenState
    extends State<WebServerPortConflictScreen> {
  bool _checking = false;
  bool? _free;

  Future<void> _checkAgain() async {
    setState(() {
      _checking = true;
      _free = null;
    });
    final free = await widget.probe(widget.port);
    if (!mounted) return;
    setState(() {
      _checking = false;
      _free = free;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 520),
              child: Padding(
                padding: const EdgeInsets.all(32),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  spacing: 16,
                  children: [
                    ShadAlert.destructive(
                      icon: const Icon(LucideIcons.triangleAlert, size: 16),
                      title: const Text('Another Decaid app is running'),
                      description: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        spacing: 12,
                        children: [
                          Text(
                            'Port ${widget.port} is already in use. Only one '
                            'Decaid app can run at a time, because they share '
                            'the same port.',
                          ),
                          const Text(
                            'Close the other Decaid app, then open this one '
                            'again.',
                          ),
                        ],
                      ),
                    ),
                    if (_free != null)
                      ShadAlert(
                        icon: const Icon(LucideIcons.info, size: 16),
                        description: Text(
                          _free!
                              ? 'Port ${widget.port} is free now. Close this '
                                    'app and open it again.'
                              : 'Port ${widget.port} is still in use.',
                        ),
                      ),
                    Wrap(
                      spacing: 12,
                      runSpacing: 12,
                      children: [
                        ShadButton(
                          onPressed: _checking ? null : _checkAgain,
                          child: Text(_checking ? 'Checking…' : 'Check again'),
                        ),
                        ShadButton.outline(
                          onPressed: () => SystemNavigator.pop(),
                          child: const Text('Close this app'),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

@Preview(name: 'Port Conflict', group: 'Startup')
Widget portConflictPreview() {
  return StartupFailureShell(
    child: WebServerPortConflictScreen(port: 8080, probe: (_) async => false),
  );
}
