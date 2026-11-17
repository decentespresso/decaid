import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:logging/logging.dart';
import 'package:reaprime/src/skin_feature/skin_webview_startup.dart';

Widget _view({
  bool created = false,
  bool loading = true,
  TargetPlatform platform = TargetPlatform.windows,
}) => MaterialApp(
  home: Scaffold(
    body: SkinWebViewStartup(
      platform: platform,
      isLoading: loading,
      isCreated: created,
      skinId: 'streamline.js',
      port: 24800,
      onOpenInBrowser: () {},
      onDashboard: () {},
      child: const SizedBox.expand(),
    ),
  ),
);

List<Map<String, dynamic>> _events(List<LogRecord> records) => records
    .where((record) => record.message.startsWith('{'))
    .map((record) => jsonDecode(record.message) as Map<String, dynamic>)
    .where((record) => record['event'] == 'windowsSkinStartup')
    .toList();

void main() {
  late Level previousLevel;
  late List<LogRecord> records;
  late StreamSubscription<LogRecord> subscription;

  setUp(() {
    previousLevel = Logger.root.level;
    Logger.root.level = Level.ALL;
    records = [];
    subscription = Logger('SkinView').onRecord.listen(records.add);
  });

  tearDown(() async {
    await subscription.cancel();
    Logger.root.level = previousLevel;
  });

  testWidgets('creation timeout records correlated diagnostic context', (
    tester,
  ) async {
    await tester.pumpWidget(_view());
    await tester.pump(const Duration(seconds: 30));
    final events = _events(records);

    expect(events.map((event) => event['action']), ['started', 'timeout']);
    expect(events.map((event) => event['stage']), [
      'webview-creation',
      'webview-creation',
    ]);
    expect(events.map((event) => event['attemptId']).toSet(), hasLength(1));
    expect(events.first['attemptId'], isNotEmpty);
    expect(events.last['skinId'], 'streamline.js');
    expect(events.last['port'], 24800);
    expect(events.last['elapsedMs'], greaterThanOrEqualTo(0));
    expect(events.last['webViewCreated'], isFalse);
    expect(events.last['timedOut'], isTrue);
    expect(
      events.last.keys,
      unorderedEquals([
        'event',
        'action',
        'attemptId',
        'skinId',
        'port',
        'stage',
        'elapsedMs',
        'webViewCreated',
        'timedOut',
      ]),
    );
    expect(records.last.level, Level.WARNING);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('page timeout and late recovery retain the startup identity', (
    tester,
  ) async {
    await tester.pumpWidget(_view());
    await tester.pumpWidget(_view(created: true));
    await tester.pump(const Duration(seconds: 30));
    await tester.pumpWidget(_view(created: true, loading: false));
    final events = _events(records);

    expect(events.map((event) => event['action']), [
      'started',
      'created',
      'timeout',
      'recovered',
    ]);
    expect(events.map((event) => event['stage']), [
      'webview-creation',
      'page-load',
      'page-load',
      'loaded',
    ]);
    expect(events.map((event) => event['attemptId']).toSet(), hasLength(1));
    expect(events.last['timedOut'], isTrue);
    expect(
      events.last['elapsedMs'],
      greaterThanOrEqualTo(events.first['elapsedMs']),
    );
    expect(find.text('WebView Error'), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
    expect(_events(records), hasLength(4));
  });

  testWidgets(
    'completed startup does not log ordinary page loads as startups',
    (tester) async {
      await tester.pumpWidget(_view());
      await tester.pumpWidget(_view(created: true, loading: false));
      await tester.pumpWidget(_view(created: true));
      await tester.pumpWidget(_view(created: true, loading: false));
      await tester.pump(const Duration(seconds: 31));
      await tester.pumpWidget(const SizedBox.shrink());

      final events = _events(records);
      expect(events.map((event) => event['action']), [
        'started',
        'created',
        'loaded',
      ]);
      expect(events.map((event) => event['stage']), [
        'webview-creation',
        'page-load',
        'loaded',
      ]);
    },
  );

  testWidgets(
    'closing before creation records cancellation without a timeout',
    (tester) async {
      await tester.pumpWidget(_view());
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(seconds: 31));
      final events = _events(records);

      expect(events.map((event) => event['action']), ['started', 'aborted']);
      expect(events.last['stage'], 'webview-creation');
      expect(events.last['timedOut'], isFalse);
      expect(records.last.level, Level.INFO);
    },
  );

  testWidgets('non-Windows views do not emit Windows startup diagnostics', (
    tester,
  ) async {
    await tester.pumpWidget(_view(platform: TargetPlatform.android));
    await tester.pump(const Duration(seconds: 31));
    await tester.pumpWidget(const SizedBox.shrink());

    expect(_events(records), isEmpty);
  });
}
