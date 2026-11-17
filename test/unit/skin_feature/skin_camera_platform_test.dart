import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:reaprime/src/skin_feature/skin_camera_platform.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const macOSChannel = MethodChannel('com.reaprime/skin_camera');
  const permissionChannel = MethodChannel(
    'flutter.baseflow.com/permissions/methods',
  );

  tearDown(() {
    debugDefaultTargetPlatformOverride = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(macOSChannel, null);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(permissionChannel, null);
  });

  for (final platform in TargetPlatform.values) {
    test('camera support on $platform is explicit', () {
      debugDefaultTargetPlatformOverride = platform;
      expect(
        supportsSkinCamera,
        [
          TargetPlatform.android,
          TargetPlatform.iOS,
          TargetPlatform.macOS,
        ].contains(platform),
      );
    });
  }

  for (final platform in [TargetPlatform.android, TargetPlatform.iOS]) {
    for (final status in [PermissionStatus.granted, PermissionStatus.denied]) {
      test(
        '$platform requests camera-only system permission: $status',
        () async {
          debugDefaultTargetPlatformOverride = platform;
          MethodCall? request;
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
              .setMockMethodCallHandler(permissionChannel, (call) async {
                request = call;
                return {Permission.camera.value: status.index};
              });
          expect(
            await requestSkinCameraPermission(),
            status == PermissionStatus.granted,
          );
          expect(request?.method, 'requestPermissions');
          expect(request?.arguments, [Permission.camera.value]);
        },
      );
    }
  }

  for (final allowed in [true, false, null]) {
    test('macOS native camera response $allowed', () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
      MethodCall? request;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(macOSChannel, (call) async {
            request = call;
            return allowed;
          });
      expect(await requestSkinCameraPermission(), allowed == true);
      expect(request?.method, 'requestCamera');
      expect(request?.arguments, isNull);
    });
  }

  for (final platform in [TargetPlatform.windows, TargetPlatform.linux]) {
    test('$platform does not request camera permission', () async {
      debugDefaultTargetPlatformOverride = platform;
      var calls = 0;
      for (final channel in [macOSChannel, permissionChannel]) {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, (_) async {
              calls++;
              return true;
            });
      }
      expect(await requestSkinCameraPermission(), isFalse);
      expect(calls, 0);
    });
  }
}
