import 'package:flutter/material.dart';

class DatabaseFailureView extends StatelessWidget {
  const DatabaseFailureView({
    super.key,
    required this.logFilePath,
    this.detail,
  });

  final String logFilePath;
  final String? detail;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final detail = this.detail;
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 560),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(Icons.storage, size: 48, color: theme.colorScheme.error),
                  const SizedBox(height: 16),
                  Text(
                    'The local database could not be safely opened or updated',
                    style: theme.textTheme.headlineSmall,
                  ),
                  const SizedBox(height: 12),
                  Text(
                    'Decaid stopped because its local database could not be '
                    'opened or updated. Your existing data has been left in '
                    'place.',
                    style: theme.textTheme.bodyLarge,
                  ),
                  if (detail != null) ...[
                    const SizedBox(height: 12),
                    Text(
                      'Diagnostic: $detail',
                      style: theme.textTheme.bodySmall,
                    ),
                  ],
                  const SizedBox(height: 12),
                  Text(
                    'Log file: $logFilePath',
                    style: theme.textTheme.bodySmall,
                  ),
                  const SizedBox(height: 12),
                  Text(
                    'Please preserve your data and share your logs (and a data '
                    'package if one is available) with Decent support, then '
                    'use an updated Decaid build or assisted repair before '
                    'trying again.',
                    style: theme.textTheme.bodyMedium,
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class DatabaseFailureApp extends StatelessWidget {
  const DatabaseFailureApp({super.key, required this.logFilePath, this.detail});

  final String logFilePath;
  final String? detail;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Decaid',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.teal),
      ),
      home: DatabaseFailureView(logFilePath: logFilePath, detail: detail),
    );
  }
}
