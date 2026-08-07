import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/main.dart' as app;
import 'package:reaprime/src/plugins/plugin_loader_service.dart';

class _FakePluginLoaderService extends Fake implements PluginLoaderService {
  final disposed = Completer<void>();
  int disposeCalls = 0;

  @override
  Future<void> dispose() {
    disposeCalls += 1;
    return disposed.future;
  }
}

void main() {
  testWidgets('detached disposes the process plugin loader', (tester) async {
    final loader = _FakePluginLoaderService();
    final observer = app.AppLifecycleObserver(pluginLoaderService: loader);

    observer.didChangeAppLifecycleState(AppLifecycleState.paused);
    await tester.pump();
    expect(loader.disposeCalls, 0);

    observer.didChangeAppLifecycleState(AppLifecycleState.detached);
    await tester.pump();
    expect(loader.disposeCalls, 1);

    loader.disposed.complete();
    await tester.pump();
  });
}
