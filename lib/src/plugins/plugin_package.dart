import 'dart:convert';
import 'dart:io';

import 'package:logging/logging.dart';
import 'package:reaprime/src/plugins/plugin_manifest.dart';
import 'package:reaprime/src/util/safe_path.dart';
import 'package:reaprime/src/util/user_facing_exception.dart';

class PluginPackageException extends UserFacingFormatException {
  PluginPackageException(super.message);

  @override
  String toString() => message;
}

class PluginPackage {
  final Directory root;
  final PluginManifest manifest;
  final Map<String, dynamic> manifestJson;

  const PluginPackage({
    required this.root,
    required this.manifest,
    required this.manifestJson,
  });
}

const _manifestName = 'manifest.json';
const _sourceName = 'plugin.js';

PluginPackage resolvePluginPackage(Directory staged) {
  if (!staged.existsSync()) {
    throw PluginPackageException(
      'Plugin package not found. Check its location.',
    );
  }

  final root = _resolveRoot(staged);

  if (!File('${root.path}/$_sourceName').existsSync()) {
    throw PluginPackageException('Plugin package has no $_sourceName');
  }

  final Map<String, dynamic> manifestJson;
  final PluginManifest manifest;
  try {
    manifestJson =
        jsonDecode(File('${root.path}/$_manifestName').readAsStringSync())
            as Map<String, dynamic>;
    manifest = PluginManifest.fromJson(manifestJson);
  } catch (e, st) {
    Logger('PluginPackage').warning('Invalid plugin manifest', e, st);
    throw PluginPackageException(
      'The plugin manifest is invalid. Check the package and try again.',
    );
  }

  if (!isSafePathComponent(manifest.id)) {
    throw PluginPackageException(
      'Unsafe plugin id: must be a single safe path component',
    );
  }

  return PluginPackage(
    root: root,
    manifest: manifest,
    manifestJson: manifestJson,
  );
}

Directory _resolveRoot(Directory staged) {
  if (File('${staged.path}/$_manifestName').existsSync()) return staged;

  final candidates = staged
      .listSync()
      .whereType<Directory>()
      .where((dir) => File('${dir.path}/$_manifestName').existsSync())
      .toList();

  if (candidates.length == 1) return candidates.single;
  if (candidates.isEmpty) {
    throw PluginPackageException('Plugin package has no $_manifestName');
  }
  throw PluginPackageException(
    'Plugin package has ${candidates.length} plugin roots; '
    'expected exactly one',
  );
}
