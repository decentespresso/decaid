import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:logging/logging.dart';
import 'package:mime/mime.dart';
import 'package:reaprime/src/skin_feature/skin_camera_controls.dart';
import 'package:reaprime/src/skin_feature/skin_camera_permission.dart';
import 'package:reaprime/src/skin_feature/skin_camera_platform.dart';

class SkinCameraWebViewAccess with WidgetsBindingObserver {
  late final SkinCameraPermission _permission;
  bool _disposed = false;
  bool _choosingFile = false;
  int _fileChooserGeneration = 0;
  final _log = Logger('SkinCameraWebViewAccess');

  SkinCameraWebViewAccess({
    required BuildContext? Function() context,
    required SkinCameraTarget? Function() currentTarget,
    SkinCameraConsentStore store = const SkinCameraConsentStore(),
    Future<bool> Function()? requestSystemCamera,
  }) {
    _permission = SkinCameraPermission(
      store: store,
      currentTarget: currentTarget,
      isActive: () => !_disposed && _isActive(context()),
      prompt: (name) async {
        final current = context();
        if (current == null || !current.mounted) return null;
        return promptForSkinCamera(current, name);
      },
      requestSystemCamera: requestSystemCamera ?? requestSkinCameraPermission,
    );
    WidgetsBinding.instance.addObserver(this);
  }

  static bool _isActive(BuildContext? context) {
    final state = WidgetsBinding.instance.lifecycleState;
    return context != null &&
        context.mounted &&
        ModalRoute.of(context)?.isCurrent == true &&
        state != AppLifecycleState.paused &&
        state != AppLifecycleState.hidden &&
        state != AppLifecycleState.detached;
  }

  void invalidate() {
    _fileChooserGeneration++;
    _permission.invalidate();
  }

  void dispose() {
    _disposed = true;
    invalidate();
    WidgetsBinding.instance.removeObserver(this);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden ||
        state == AppLifecycleState.detached) {
      _permission.invalidate();
    }
  }

  Future<PermissionResponse> onPermissionRequest(
    InAppWebViewController controller,
    PermissionRequest request,
  ) => _permission.handle(request, readTopLevel: controller.getUrl);

  void onPermissionRequestCanceled(
    InAppWebViewController controller,
    PermissionRequest request,
  ) => invalidate();

  Future<ShowFileChooserResponse?> onShowFileChooser(
    InAppWebViewController controller,
    ShowFileChooserRequest request,
  ) async {
    final denied = ShowFileChooserResponse(handledByClient: true);
    if (_disposed || _choosingFile) return denied;
    _choosingFile = true;
    final generation = _fileChooserGeneration;
    try {
      final types = request.acceptTypes
          .map((type) => type.trim().toLowerCase())
          .toList();
      final imageOnly =
          types.isNotEmpty &&
          types.every((type) {
            final mimeType = type.startsWith('.') ? lookupMimeType(type) : type;
            return mimeType?.startsWith('image/') ?? false;
          });
      if (request.isCaptureEnabled) {
        return imageOnly &&
                await _permission.capture(readTopLevel: controller.getUrl)
            ? null
            : denied;
      }
      final fileType =
          types.isNotEmpty && types.every((type) => type.startsWith('.'))
          ? FileType.custom
          : imageOnly
          ? FileType.image
          : types.isNotEmpty && types.every((type) => type.startsWith('video/'))
          ? FileType.video
          : types.isNotEmpty && types.every((type) => type.startsWith('audio/'))
          ? FileType.audio
          : FileType.any;
      final selection = await FilePicker.pickFiles(
        type: fileType,
        allowedExtensions: fileType == FileType.custom
            ? types.map((type) => type.substring(1)).toList()
            : null,
        allowMultiple: request.mode == ShowFileChooserRequestMode.OPEN_MULTIPLE,
      );
      if (_disposed || generation != _fileChooserGeneration) return denied;
      return ShowFileChooserResponse(
        handledByClient: true,
        filePaths: selection?.paths
            .whereType<String>()
            .map((path) => Uri.file(path).toString())
            .toList(),
      );
    } catch (error, stackTrace) {
      _log.warning('Skin file selection failed', error, stackTrace);
      return denied;
    } finally {
      _choosingFile = false;
    }
  }
}
