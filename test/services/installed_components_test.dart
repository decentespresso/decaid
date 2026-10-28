import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/plugins/plugin_loader_service.dart';
import 'package:reaprime/src/plugins/plugin_manifest.dart';
import 'package:reaprime/src/plugins/plugin_runtime.dart';
import 'package:reaprime/src/services/installed_components.dart';
import 'package:reaprime/src/webui_support/webui_service.dart';
import 'package:reaprime/src/webui_support/webui_storage.dart';

class _FakeWebUIService extends Fake implements WebUIService {
  _FakeWebUIService({this.serving = true, this.path = ''});

  final bool serving;
  final String path;

  @override
  bool get isServing => serving;

  @override
  String serverPath() => path;
}

class _FakeWebUIStorage extends Fake implements WebUIStorage {
  _FakeWebUIStorage(this.skins, this.preferred);

  final List<WebUISkin> skins;
  final WebUISkin? preferred;

  @override
  List<WebUISkin> get installedSkins => skins;

  @override
  WebUISkin? get defaultSkin => preferred;
}

class _FakePluginLoaderService extends Fake implements PluginLoaderService {
  _FakePluginLoaderService(this.plugins);

  final List<PluginRuntime> plugins;

  @override
  List<PluginRuntime> get loadedPlugins => plugins;
}

WebUISkin _skin(String id, String path, {String? version}) =>
    WebUISkin(id: id, name: id, path: path, version: version);

PluginRuntime _plugin(String id, String version) => PluginRuntime(
  pluginId: id,
  manifest: PluginManifest.fromJson({
    'id': id,
    'name': id,
    'author': 'test',
    'description': 'test',
    'version': version,
    'apiVersion': 1,
    'permissions': const ['log'],
    'api': const [],
  }),
);

void main() {
  final streamline = _skin(
    'streamline.js',
    '/skins/streamline.js',
    version: '0.2.19',
  );
  final tcl = _skin('tcl', '/skins/tcl', version: '1.4.0');

  test('the served skin is named, not the preferred default', () {
    expect(
      installedComponentLines(
        isServing: true,
        servedPath: tcl.path,
        installedSkins: [streamline, tcl],
        loadedPlugins: const [],
      ).first,
      'Skin: tcl 1.4.0',
    );
  });

  test(
    'a served path outside the registry is unregistered, not the default',
    () {
      expect(
        installedComponentLines(
          isServing: true,
          servedPath: '/home/barista/work/my-skin',
          installedSkins: [streamline, tcl],
          loadedPlugins: const [],
        ).first,
        'Skin: unregistered (my-skin) unknown',
      );
    },
  );

  test('no skin is claimed while nothing is served', () {
    expect(
      installedComponentLines(
        isServing: false,
        servedPath: streamline.path,
        installedSkins: [streamline],
        loadedPlugins: const [],
      ).first,
      'Skin: none served',
    );
    expect(
      installedComponentLines(
        isServing: true,
        servedPath: '   ',
        installedSkins: [streamline],
        loadedPlugins: const [],
      ).first,
      'Skin: none served',
    );
  });

  test('the served path matches a registered skin through normalization', () {
    expect(
      installedComponentLines(
        isServing: true,
        servedPath: '/skins/tcl/../tcl/',
        installedSkins: [streamline, tcl],
        loadedPlugins: const [],
      ).first,
      'Skin: tcl 1.4.0',
    );
  });

  test('a registered skin without a version reads as unknown', () {
    expect(
      installedComponentLines(
        isServing: true,
        servedPath: '/skins/none',
        installedSkins: [_skin('no-version', '/skins/none')],
        loadedPlugins: const [],
      ).first,
      'Skin: no-version unknown',
    );
  });

  test('every loaded plugin is named, and none reads as none', () {
    expect(
      installedComponentLines(
        isServing: true,
        servedPath: streamline.path,
        installedSkins: [streamline],
        loadedPlugins: [
          _plugin('dye2.reaplugin', '1.3.0'),
          _plugin('time-to-ready.reaplugin', '0.2.0'),
        ],
      ).last,
      'Loaded plugins: dye2.reaplugin 1.3.0, time-to-ready.reaplugin 0.2.0',
    );
    expect(
      installedComponentLines(
        isServing: true,
        servedPath: streamline.path,
        installedSkins: [streamline],
        loadedPlugins: const [],
      ).last,
      'Loaded plugins: none',
    );
  });

  test('the collector reads the served skin, not the preferred one', () {
    expect(
      collectInstalledComponents(
        webUIService: _FakeWebUIService(path: tcl.path),
        webUIStorage: _FakeWebUIStorage([streamline, tcl], streamline),
        pluginService: _FakePluginLoaderService([
          _plugin('dye2.reaplugin', '1.3.0'),
        ]),
      ),
      ['Skin: tcl 1.4.0', 'Loaded plugins: dye2.reaplugin 1.3.0'],
    );
  });

  test('the collector claims no skin while the webserver is idle', () {
    expect(
      collectInstalledComponents(
        webUIService: _FakeWebUIService(serving: false, path: streamline.path),
        webUIStorage: _FakeWebUIStorage([streamline], streamline),
        pluginService: _FakePluginLoaderService(const []),
      ),
      ['Skin: none served', 'Loaded plugins: none'],
    );
  });
}
