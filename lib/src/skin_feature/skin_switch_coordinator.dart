import 'package:logging/logging.dart';
import 'package:reaprime/src/webui_support/webui_service.dart';

enum SkinSwitchOutcome { switched, unchanged, unknownSkin, busy, failed }

typedef SkinPathLookup = String? Function(String skinId);

class SkinSwitchCoordinator {
  SkinSwitchCoordinator({
    required WebUIService service,
    required SkinPathLookup skinPath,
    required Future<void> Function(String skinId) setDefaultSkin,
    int entryPort = 3000,
  }) : _service = service,
       _skinPath = skinPath,
       _setDefaultSkin = setDefaultSkin,
       _entryPort = entryPort;

  final _log = Logger('SkinSwitchCoordinator');
  final WebUIService _service;
  final SkinPathLookup _skinPath;
  final Future<void> Function(String skinId) _setDefaultSkin;
  final int _entryPort;

  Future<SkinSwitchOutcome>? _inFlight;

  bool get isSwitching => _inFlight != null;

  Future<SkinSwitchOutcome> switchTo(String skinId) {
    if (_inFlight != null) {
      _log.warning('Skin switch to $skinId rejected: another is in flight');
      return Future.value(SkinSwitchOutcome.busy);
    }
    final operation = _switchTo(skinId);
    _inFlight = operation;
    return operation.whenComplete(() {
      if (identical(_inFlight, operation)) _inFlight = null;
    });
  }

  Future<SkinSwitchOutcome> _switchTo(String skinId) async {
    final path = _skinPath(skinId);
    if (path == null) {
      _log.warning('Skin switch to $skinId rejected: not installed');
      return SkinSwitchOutcome.unknownSkin;
    }
    final previousPath = _service.isServing ? _service.serverPath() : null;
    if (previousPath == path) return SkinSwitchOutcome.unchanged;

    try {
      await _service.serveFolderAtPath(path, port: _entryPort);
    } catch (e, st) {
      _log.severe('Failed to serve skin $skinId from $path', e, st);
      if (previousPath != null) {
        try {
          await _service.serveFolderAtPath(previousPath, port: _entryPort);
        } catch (e, st) {
          _log.severe('Failed to restore $previousPath', e, st);
        }
      }
      return SkinSwitchOutcome.failed;
    }

    try {
      await _setDefaultSkin(skinId);
    } catch (e, st) {
      _log.warning('Failed to persist default skin $skinId', e, st);
    }
    _log.info('Switched skin to $skinId on port ${_service.port}');
    return SkinSwitchOutcome.switched;
  }
}
