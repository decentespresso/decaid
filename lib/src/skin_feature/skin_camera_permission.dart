import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:logging/logging.dart';
import 'package:shared_preferences/shared_preferences.dart';

class SkinCameraTarget {
  final String id;
  final String name;
  final int port;

  const SkinCameraTarget({
    required this.id,
    required this.name,
    required this.port,
  });

  bool trusts(Uri? uri) =>
      uri != null &&
      uri.scheme == 'http' &&
      uri.host == 'localhost' &&
      uri.port == port &&
      uri.userInfo.isEmpty &&
      port != 3000 &&
      port != 8080 &&
      port != 4001;
}

class SkinCameraConsentStore {
  final Future<SharedPreferences> Function() preferences;

  const SkinCameraConsentStore({
    this.preferences = SharedPreferences.getInstance,
  });

  Future<bool?> read(String id) async =>
      (await preferences()).getBool('skinCameraConsent.$id');

  Future<void> write(String id, bool? allowed) async {
    final prefs = await preferences();
    final key = 'skinCameraConsent.$id';
    final saved = allowed == null
        ? await prefs.remove(key)
        : await prefs.setBool(key, allowed);
    if (!saved) throw StateError('Camera consent could not be saved');
  }
}

class SkinCameraPermission {
  final SkinCameraConsentStore store;
  final SkinCameraTarget? Function() currentTarget;
  final bool Function() isActive;
  final Future<bool?> Function(String skinName) prompt;
  final Future<bool> Function() requestSystemCamera;
  final _log = Logger('SkinCameraPermission');
  bool _pending = false;
  int _generation = 0;

  SkinCameraPermission({
    required this.store,
    required this.currentTarget,
    required this.isActive,
    required this.prompt,
    required this.requestSystemCamera,
  });

  void invalidate() => _generation++;

  Future<PermissionResponse> handle(
    PermissionRequest request, {
    required Future<Uri?> Function() readTopLevel,
  }) async {
    final cameraOnly =
        request.resources.length == 1 &&
        request.resources.single == PermissionResourceType.CAMERA;
    final allowed =
        cameraOnly &&
        await _request(
          origin: request.origin,
          readTopLevel: readTopLevel,
          confirmEveryRequest: false,
        );
    return PermissionResponse(
      action: allowed
          ? PermissionResponseAction.GRANT
          : PermissionResponseAction.DENY,
      resources: allowed ? [PermissionResourceType.CAMERA] : [],
    );
  }

  Future<bool> capture({required Future<Uri?> Function() readTopLevel}) =>
      _request(readTopLevel: readTopLevel, confirmEveryRequest: true);

  Future<bool> _request({
    Uri? origin,
    required Future<Uri?> Function() readTopLevel,
    required bool confirmEveryRequest,
  }) async {
    if (_pending) return false;
    _pending = true;
    final generation = _generation;
    try {
      final target = currentTarget();
      if (target == null ||
          target.id.isEmpty ||
          (!confirmEveryRequest && !target.trusts(origin))) {
        return false;
      }

      Future<bool> stillTrusted() async {
        final topLevel = await readTopLevel();
        final current = currentTarget();
        return generation == _generation &&
            isActive() &&
            current?.id == target.id &&
            current?.port == target.port &&
            target.trusts(topLevel);
      }

      if (!await stillTrusted()) return false;
      final known = await store.read(target.id);
      if (!await stillTrusted() || (!confirmEveryRequest && known == false)) {
        return false;
      }
      if (known == null || confirmEveryRequest) {
        final answer = await prompt(target.name);
        if (!await stillTrusted() || answer == null) return false;
        if (!confirmEveryRequest) await store.write(target.id, answer);
        if (!answer) return false;
      }
      if (!await stillTrusted()) return false;
      if (!await requestSystemCamera()) return false;
      final latest = await store.read(target.id);
      return await stillTrusted() && (confirmEveryRequest || latest == true);
    } catch (error, stackTrace) {
      _log.warning('Camera access denied', error, stackTrace);
      return false;
    } finally {
      _pending = false;
    }
  }
}
