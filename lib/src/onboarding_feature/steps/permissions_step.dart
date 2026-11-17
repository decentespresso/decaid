import 'dart:async';
import 'dart:io';

import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/material.dart';
import 'package:logging/logging.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:reaprime/src/onboarding_feature/widgets/onboarding_scaffold.dart';
import 'package:shadcn_ui/shadcn_ui.dart';
import 'package:universal_ble/universal_ble.dart';

import '../onboarding_controller.dart';

final _log = Logger('PermissionsStep');

OnboardingStep createPermissionsStep() {
  return OnboardingStep(
    id: 'permissions',
    shouldShow: () => _checkPermissionsNeeded(),
    builder: (controller) =>
        _PermissionsStepView(onboardingController: controller),
  );
}

Future<bool> _checkPermissionsNeeded() async {
  if (Platform.isAndroid) {
    final info = await DeviceInfoPlugin().androidInfo;
    if (info.version.sdkInt >= 31) {
      final scan = await Permission.bluetoothScan.status;
      final connect = await Permission.bluetoothConnect.status;
      return !scan.isGranted || !connect.isGranted;
    } else {
      final bt = await Permission.bluetooth.status;
      final loc = await Permission.locationWhenInUse.status;
      return !bt.isGranted || !loc.isGranted;
    }
  } else if (Platform.isIOS) {
    final bt = await Permission.bluetooth.status;
    return !bt.isGranted;
  }
  return false;
}

class _PermissionsStepView extends StatefulWidget {
  final OnboardingController onboardingController;
  const _PermissionsStepView({required this.onboardingController});

  @override
  State<_PermissionsStepView> createState() => _PermissionsStepViewState();
}

class _PermissionsStepViewState extends State<_PermissionsStepView> {
  late final Future<void> _permissionsFuture;

  @override
  void initState() {
    super.initState();
    _permissionsFuture = _requestPermissions();
  }

  Future<void> _requestPermissions() async {
    if (Platform.isAndroid) {
      final sdkVersion = await _getAndroidSdkVersion();
      if (sdkVersion >= 31) {
        await Permission.bluetoothScan.request();
        await Permission.bluetoothConnect.request();
      } else {
        await Permission.bluetooth.request();
        await Permission.locationWhenInUse.request();
      }

      await Permission.notification.request();

      final batteryOptStatus =
          await Permission.ignoreBatteryOptimizations.status;
      if (!batteryOptStatus.isGranted) {
        await Permission.ignoreBatteryOptimizations.request();
      }
    } else if (Platform.isIOS) {
      await Permission.bluetooth.request();
    } else {
      try {
        await UniversalBle.availabilityStream
            .firstWhere((e) => e == AvailabilityState.poweredOn)
            .timeout(Duration(seconds: 5));
      } on TimeoutException {
        _log.warning(
          'Bluetooth availability check timed out, continuing without BLE',
        );
      }
    }

    if (!mounted) return;
    widget.onboardingController.advance();
  }

  Future<int> _getAndroidSdkVersion() async {
    final androidInfo = await DeviceInfoPlugin().androidInfo;
    return androidInfo.version.sdkInt;
  }

  @override
  Widget build(BuildContext context) {
    return OnboardingScaffold(
      semanticsLabel: 'Requesting permissions',
      body: [
        FutureBuilder<void>(
          future: _permissionsFuture,
          builder: (context, snapshot) {
            if (snapshot.hasError) {
              return Semantics(
                liveRegion: true,
                child: Text('Error: ${snapshot.error}'),
              );
            }
            return Column(
              spacing: 16,
              children: [
                SizedBox(
                  width: 200,
                  child: Semantics(
                    label: 'Requesting permissions',
                    child: ShadProgress(),
                  ),
                ),
                Semantics(
                  liveRegion: true,
                  child: Text(
                    'Requesting permissions...',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ),
              ],
            );
          },
        ),
      ],
    );
  }
}
