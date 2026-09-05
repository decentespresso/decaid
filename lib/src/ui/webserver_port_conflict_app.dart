import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:reaprime/src/services/webserver/port_binding.dart';

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
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.orange),
        useMaterial3: true,
      ),
      home: WebServerPortConflictScreen(port: port, probe: probe),
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
    final text = Theme.of(context).textTheme;
    return Scaffold(
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 520),
          child: Padding(
            padding: const EdgeInsets.all(32),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Another Decaid app is running',
                  style: text.headlineSmall,
                ),
                const SizedBox(height: 16),
                Text(
                  'Port ${widget.port} is already in use. Only one Decaid app '
                  'can run at a time, because they share the same port.',
                  style: text.bodyLarge,
                ),
                const SizedBox(height: 12),
                Text(
                  'Close the other Decaid app, then open this one again.',
                  style: text.bodyLarge,
                ),
                if (_free != null) ...[
                  const SizedBox(height: 16),
                  Text(
                    _free!
                        ? 'Port ${widget.port} is free now. Close this app and '
                              'open it again.'
                        : 'Port ${widget.port} is still in use.',
                    style: text.bodyLarge?.copyWith(
                      color: Theme.of(context).colorScheme.primary,
                    ),
                  ),
                ],
                const SizedBox(height: 24),
                Wrap(
                  spacing: 12,
                  runSpacing: 12,
                  children: [
                    FilledButton(
                      onPressed: _checking ? null : _checkAgain,
                      child: Text(_checking ? 'Checking…' : 'Check again'),
                    ),
                    OutlinedButton(
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
    );
  }
}
