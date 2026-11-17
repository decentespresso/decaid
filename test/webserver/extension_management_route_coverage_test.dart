import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/plugins/plugin_loader_service.dart';
import 'package:reaprime/src/plugins/plugin_manager.dart';
import 'package:reaprime/src/services/webserver/extension_management_auth.dart';
import 'package:reaprime/src/services/webserver_service.dart';
import 'package:reaprime/src/webui_support/webui_service.dart';
import 'package:reaprime/src/webui_support/webui_storage.dart';
import 'package:shelf_plus/shelf_plus.dart';

import '../plugins/plugin_test_helpers.dart';

class _FakePluginLoaderService extends Fake implements PluginLoaderService {}

class _FakeWebUIStorage extends Fake implements WebUIStorage {}

class _RecordingRouter extends RouterPlus {
  final List<String> registered = [];

  @override
  void add(
    String verb,
    String route,
    Function handler, [
    Middleware? localMiddleware,
  ]) {
    registered.add('${verb.toUpperCase()} $route');
    super.add(verb, route, handler, localMiddleware);
  }

  @override
  void all(String route, Function handler, {Middleware? use}) {
    registered.add('ALL $route');
    super.all(route, handler, use: use);
  }
}

const _reviewedOpenRoutes = {'ALL /api/v1/plugins/<id>/<endpoint>'};

void main() {
  late _RecordingRouter router;

  setUp(() {
    final manager = PluginManager(kvStore: FakeKeyValueStoreService());
    addTearDown(manager.dispose);
    router = _RecordingRouter();
    PluginsHandler(
      pluginManager: manager,
      pluginService: _FakePluginLoaderService(),
    ).addRoutes(router);
    WebUIHandler(
      storage: _FakeWebUIStorage(),
      service: WebUIService(),
    ).addRoutes(router);
  });

  test('every mutating plugin and skin route the handlers register is '
      'gated or reviewed as open', () {
    final protected = extensionManagementRoutes
        .map((route) => route.toString())
        .toSet();
    final unclassified = router.registered
        .where((route) => !route.startsWith('GET '))
        .where((route) => !protected.contains(route))
        .where((route) => !_reviewedOpenRoutes.contains(route));

    expect(
      unclassified,
      isEmpty,
      reason:
          'Add each new mutating route to extensionManagementRoutes in '
          'extension_management_auth.dart, or to _reviewedOpenRoutes here '
          'when it does not manage plugins or skins.',
    );
  });

  test('every gated route is one the handlers register', () {
    expect(
      extensionManagementRoutes.map((route) => route.toString()),
      everyElement(isIn(router.registered)),
    );
  });
}
