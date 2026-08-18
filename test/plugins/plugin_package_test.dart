import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/plugins/plugin_package.dart';

void main() {
  late Directory tempDir;

  Map<String, dynamic> manifestJson(String id, {String version = '1.0.0'}) => {
    'id': id,
    'author': 'Test',
    'name': 'Test plugin',
    'description': 'Test plugin',
    'version': version,
    'apiVersion': 1,
    'permissions': <String>[],
    'settings': <String, dynamic>{},
    'api': <Object>[],
  };

  Directory writePlugin(
    String path, {
    String id = 'pkg.reaplugin',
    Object? manifest,
    bool withSource = true,
  }) {
    final dir = Directory(path)..createSync(recursive: true);
    File(
      '${dir.path}/manifest.json',
    ).writeAsStringSync(jsonEncode(manifest ?? manifestJson(id)));
    if (withSource) {
      File('${dir.path}/plugin.js').writeAsStringSync('function f() {}');
    }
    return dir;
  }

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('plugin_package');
  });

  tearDown(() {
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });

  test('accepts a flat package root', () {
    writePlugin('${tempDir.path}/staged');

    final pkg = resolvePluginPackage(Directory('${tempDir.path}/staged'));

    expect(pkg.manifest.id, 'pkg.reaplugin');
    expect(pkg.root.path, '${tempDir.path}/staged');
  });

  test('accepts a single wrapper directory', () {
    writePlugin('${tempDir.path}/staged/repo-1.0.0');

    final pkg = resolvePluginPackage(Directory('${tempDir.path}/staged'));

    expect(pkg.manifest.id, 'pkg.reaplugin');
    expect(pkg.root.path, endsWith('repo-1.0.0'));
  });

  test('rejects several plugin roots as ambiguous', () {
    writePlugin('${tempDir.path}/staged/one', id: 'one.reaplugin');
    writePlugin('${tempDir.path}/staged/two', id: 'two.reaplugin');

    expect(
      () => resolvePluginPackage(Directory('${tempDir.path}/staged')),
      throwsA(
        isA<PluginPackageException>().having(
          (e) => e.message,
          'message',
          contains('2 plugin roots'),
        ),
      ),
    );
  });

  test('rejects a package without a manifest', () {
    Directory('${tempDir.path}/staged/assets').createSync(recursive: true);

    expect(
      () => resolvePluginPackage(Directory('${tempDir.path}/staged')),
      throwsA(isA<PluginPackageException>()),
    );
  });

  test('rejects a package without plugin.js', () {
    writePlugin('${tempDir.path}/staged', withSource: false);

    expect(
      () => resolvePluginPackage(Directory('${tempDir.path}/staged')),
      throwsA(
        isA<PluginPackageException>().having(
          (e) => e.message,
          'message',
          contains('plugin.js'),
        ),
      ),
    );
  });

  test('rejects a malformed manifest', () {
    final dir = Directory('${tempDir.path}/staged')
      ..createSync(recursive: true);
    File('${dir.path}/manifest.json').writeAsStringSync('{ not json');
    File('${dir.path}/plugin.js').writeAsStringSync('function f() {}');

    expect(
      () => resolvePluginPackage(dir),
      throwsA(isA<PluginPackageException>()),
    );
  });

  test('rejects an unsafe plugin id', () {
    writePlugin('${tempDir.path}/staged', id: '../escape');

    expect(
      () => resolvePluginPackage(Directory('${tempDir.path}/staged')),
      throwsA(
        isA<PluginPackageException>().having(
          (e) => e.message,
          'message',
          contains('Unsafe plugin id'),
        ),
      ),
    );
  });
}
