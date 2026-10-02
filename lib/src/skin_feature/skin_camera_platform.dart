import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:permission_handler/permission_handler.dart' as permissions;

bool get supportsSkinCamera =>
    !kIsWeb &&
    const {
      TargetPlatform.android,
      TargetPlatform.iOS,
      TargetPlatform.macOS,
    }.contains(defaultTargetPlatform);

Future<bool> requestSkinCameraPermission() async =>
    switch (defaultTargetPlatform) {
      TargetPlatform.android || TargetPlatform.iOS =>
        (await permissions.Permission.camera.request()).isGranted,
      TargetPlatform.macOS =>
        await const MethodChannel(
              'com.reaprime/skin_camera',
            ).invokeMethod<bool>('requestCamera') ??
            false,
      _ => false,
    };
