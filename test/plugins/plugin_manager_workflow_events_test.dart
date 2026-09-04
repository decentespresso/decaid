import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/controllers/workflow_controller.dart';
import 'package:reaprime/src/plugins/plugin_manager.dart';
import 'package:reaprime/src/plugins/plugin_manifest.dart';

import 'plugin_test_helpers.dart';

class _CountingWorkflowController extends WorkflowController {
  int addListenerCalls = 0;
  int removeListenerCalls = 0;

  @override
  void addListener(VoidCallback listener) {
    addListenerCalls += 1;
    super.addListener(listener);
  }

  @override
  void removeListener(VoidCallback listener) {
    removeListenerCalls += 1;
    super.removeListener(listener);
  }
}

Future<void> _loadPlugin(
  PluginManager manager,
  String id, {
  bool permitted = true,
  String onLoad = '',
}) {
  return manager.loadPlugin(
    id: id,
    manifest: testManifest(
      id,
      permissions: {if (permitted) PluginPermissions.eventsWorkflow},
    ),
    settings: const {},
    jsCode:
        '''
      function createPlugin(host) {
        return {
          id: "$id",
          onLoad() { $onLoad },
          onEvent(event) {
            if (event.name !== "workflowUpdated") return;
            globalThis.__workflowEvents ??= {};
            globalThis.__workflowEvents["$id"] ??= [];
            globalThis.__workflowEvents["$id"].push({
              revision: event.payload.revision,
              revisionType: typeof event.payload.revision,
              keys: Object.keys(event.payload).sort()
            });
          }
        };
      }
    ''',
  );
}

List<Map<String, dynamic>> _events(PluginManager manager, String id) {
  final result = manager.js.evaluate(
    'JSON.stringify(globalThis.__workflowEvents?.["$id"] ?? [])',
  );
  return (jsonDecode(result.stringResult) as List<dynamic>)
      .cast<Map<String, dynamic>>();
}

void _advance(WorkflowController controller) {
  controller.setWorkflow(controller.currentWorkflow.copyWith());
}

void main() {
  test('permission gates snapshots and live revision events', () async {
    final manager = PluginManager(kvStore: FakeKeyValueStoreService());
    final controller = WorkflowController();
    addTearDown(manager.dispose);
    addTearDown(controller.dispose);

    manager.attachWorkflowController(controller);
    await _loadPlugin(manager, 'permitted.plugin');
    await _loadPlugin(manager, 'denied.plugin', permitted: false);
    controller.notifyListeners();
    _advance(controller);
    _advance(controller);

    expect(_events(manager, 'permitted.plugin'), [
      {
        'revision': 0,
        'revisionType': 'number',
        'keys': ['revision'],
      },
      {
        'revision': 1,
        'revisionType': 'number',
        'keys': ['revision'],
      },
      {
        'revision': 2,
        'revisionType': 'number',
        'keys': ['revision'],
      },
    ]);
    expect(_events(manager, 'denied.plugin'), isEmpty);
  });

  test('late load and reload each receive one current snapshot', () async {
    final manager = PluginManager(kvStore: FakeKeyValueStoreService());
    final controller = WorkflowController();
    addTearDown(manager.dispose);
    addTearDown(controller.dispose);

    manager.attachWorkflowController(controller);
    _advance(controller);
    _advance(controller);
    await _loadPlugin(manager, 'reloaded.plugin');
    await _loadPlugin(manager, 'reloaded.plugin');

    expect(
      _events(manager, 'reloaded.plugin').map((event) => event['revision']),
      [2, 2],
    );
  });

  test('loading another plugin does not repeat existing snapshots', () async {
    final manager = PluginManager(kvStore: FakeKeyValueStoreService());
    final controller = WorkflowController();
    addTearDown(manager.dispose);
    addTearDown(controller.dispose);

    manager.attachWorkflowController(controller);
    await _loadPlugin(manager, 'first.plugin');
    await _loadPlugin(manager, 'second.plugin');

    expect(_events(manager, 'first.plugin'), hasLength(1));
    expect(_events(manager, 'second.plugin'), hasLength(1));
  });

  test(
    'same attachment is ignored and replacement invalidates the old one',
    () async {
      final manager = PluginManager(kvStore: FakeKeyValueStoreService());
      final first = _CountingWorkflowController();
      final second = _CountingWorkflowController();
      addTearDown(manager.dispose);
      addTearDown(first.dispose);
      addTearDown(second.dispose);

      manager.attachWorkflowController(first);
      manager.attachWorkflowController(first);
      await _loadPlugin(manager, 'events.plugin');
      manager.attachWorkflowController(second);
      _advance(first);
      _advance(second);

      expect(first.addListenerCalls, 1);
      expect(first.removeListenerCalls, 1);
      expect(second.addListenerCalls, 1);
      expect(
        _events(manager, 'events.plugin').map((event) => event['revision']),
        [0, 1],
      );
    },
  );

  test('dispose removes the listener and blocks later events', () async {
    final manager = PluginManager(kvStore: FakeKeyValueStoreService());
    final controller = _CountingWorkflowController();
    addTearDown(controller.dispose);

    manager.attachWorkflowController(controller);
    await _loadPlugin(manager, 'events.plugin');
    await manager.dispose();
    _advance(controller);

    expect(controller.addListenerCalls, 1);
    expect(controller.removeListenerCalls, 1);
  });

  test('failed loads do not receive snapshots', () async {
    final manager = PluginManager(kvStore: FakeKeyValueStoreService());
    final controller = WorkflowController();
    addTearDown(manager.dispose);
    addTearDown(controller.dispose);

    manager.attachWorkflowController(controller);
    await expectLater(
      _loadPlugin(manager, 'failed.plugin', onLoad: 'throw new Error("boom");'),
      throwsException,
    );

    expect(_events(manager, 'failed.plugin'), isEmpty);
  });
}
