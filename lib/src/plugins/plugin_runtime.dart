import 'package:logging/logging.dart';
import 'plugin_manifest.dart';

enum PluginRuntimeState { loading, running, stopping, disposed }

class PluginRuntime {
  final String pluginId;
  final PluginManifest manifest;
  final Logger log;

  PluginRuntimeState state = PluginRuntimeState.loading;

  PluginRuntime({required this.pluginId, required this.manifest})
    : log = Logger("PluginRuntime::$pluginId");

  bool get isAlive => state == PluginRuntimeState.running;

  void markRunning() {
    state = PluginRuntimeState.running;
  }

  void markStopping() {
    state = PluginRuntimeState.stopping;
  }

  void markDisposed() {
    state = PluginRuntimeState.disposed;
  }
}
