import 'package:flutter/material.dart';
import 'package:reaprime/src/models/device/scale.dart';
import 'package:shadcn_ui/shadcn_ui.dart' hide Scale;

class ScaleDebugView extends StatefulWidget {
  final Scale scale;

  const ScaleDebugView({super.key, required this.scale});

  @override
  State<ScaleDebugView> createState() => _ScaleDebugViewState();
}

class _ScaleDebugViewState extends State<ScaleDebugView> {
  var _lastDate = DateTime.now();

  @override
  void initState() {
    super.initState();
    widget.scale.onConnect();
  }

  @override
  Widget build(BuildContext context) {
    final theme = ShadTheme.of(context);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Scale Debug'),
        leading: IconButton(
          icon: const Icon(LucideIcons.arrowLeft),
          onPressed: () => Navigator.of(context).pop(),
        ),
        actions: [
          ShadButton.destructive(
            size: ShadButtonSize.sm,
            child: const Text('Disconnect'),
            onPressed: () async {
              await widget.scale.disconnect();
              if (!context.mounted) return;
              Navigator.of(context).pop();
            },
          ),
        ],
      ),
      body: StreamBuilder<ScaleSnapshot>(
        stream: widget.scale.currentSnapshot,
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.active) {
            final diff =
                snapshot.data?.timestamp.difference(_lastDate) ?? Duration.zero;
            _lastDate = snapshot.data?.timestamp ?? DateTime.now();
            return _buildActiveView(theme, snapshot.data!, diff);
          } else if (snapshot.connectionState == ConnectionState.waiting) {
            return Center(
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const SizedBox(
                    width: 14,
                    height: 14,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                  const SizedBox(width: 8),
                  Text('Connecting…', style: theme.textTheme.muted),
                ],
              ),
            );
          }
          return Center(
            child: Text('Waiting for data', style: theme.textTheme.muted),
          );
        },
      ),
    );
  }

  Widget _buildActiveView(
    ShadThemeData theme,
    ScaleSnapshot data,
    Duration diff,
  ) {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                data.weight.toStringAsFixed(1),
                style: theme.textTheme.h1.copyWith(fontWeight: FontWeight.bold),
              ),
              Text('grams', style: theme.textTheme.muted),
            ],
          ),
        ),
        const SizedBox(height: 12),

        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text(
              'Battery: ${data.batteryLevel}%',
              style: theme.textTheme.muted,
            ),
            const SizedBox(width: 16),
            Text('${diff.inMilliseconds}ms ago', style: theme.textTheme.muted),
          ],
        ),
        const SizedBox(height: 20),

        ShadButton(
          child: const Text('Tare'),
          onPressed: () async {
            await widget.scale.tare();
          },
        ),
        const SizedBox(height: 16),

        Row(
          children: [
            Expanded(
              child: ShadButton.outline(
                child: const Text('Wake'),
                onPressed: () async {
                  await widget.scale.wakeDisplay();
                },
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: ShadButton.outline(
                child: const Text('Sleep'),
                onPressed: () async {
                  await widget.scale.sleepDisplay();
                },
              ),
            ),
          ],
        ),
        const SizedBox(height: 16),

        Text('Timer', style: theme.textTheme.small),
        const SizedBox(height: 8),
        Row(
          children: [
            Expanded(
              child: ShadButton.outline(
                size: ShadButtonSize.sm,
                child: const Text('Start'),
                onPressed: () async {
                  await widget.scale.startTimer();
                },
              ),
            ),
            const SizedBox(width: 6),
            Expanded(
              child: ShadButton.outline(
                size: ShadButtonSize.sm,
                child: const Text('Stop'),
                onPressed: () async {
                  await widget.scale.stopTimer();
                },
              ),
            ),
            const SizedBox(width: 6),
            Expanded(
              child: ShadButton.outline(
                size: ShadButtonSize.sm,
                child: const Text('Reset'),
                onPressed: () async {
                  await widget.scale.resetTimer();
                },
              ),
            ),
          ],
        ),
      ],
    );
  }
}
