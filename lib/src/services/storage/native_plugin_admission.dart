import 'dart:io';

import 'package:flutter/services.dart';

const String nativePluginAdmissionChannelName = 'com.reaprime/recovery_plugins';

const String nativePluginAdmissionMethod = 'admitPlugins';

/// Whether [operatingSystem] defers the generated plugin registrant until
/// [admitNativePlugins] is called.
///
/// These are the embeddings whose engine attachment runs the generated
/// registrant: Android through `configureFlutterEngine`, iOS through the
/// implicit-engine callback, and macOS through the window nib load. Elsewhere a
/// plugin cannot attach before Dart `main()`, so there is nothing to admit.
bool platformDefersGeneratedPluginRegistration(String operatingSystem) =>
    operatingSystem == 'android' ||
    operatingSystem == 'ios' ||
    operatingSystem == 'macos';

/// A refused or undelivered plugin registration.
///
/// Normal services must not run after this: every plugin channel would be
/// absent, so the failure is reported here instead of resurfacing later as an
/// unrelated `MissingPluginException`.
class NativePluginAdmissionException implements Exception {
  const NativePluginAdmissionException(this.reason);

  final String reason;

  @override
  String toString() => 'NativePluginAdmissionException: $reason';
}

/// Asks the embedding to register the generated plugins for this engine, and
/// does nothing on platforms that register plugins at engine attachment.
///
/// Android, iOS and macOS defer their automatic registration until this call, so
/// this is the boundary between a recovery-only engine and a fully configured
/// one. Failures are never swallowed, and an engine that was already admitted
/// answers success, so repeated calls are safe.
Future<void> admitNativePlugins() => _defaultAdmission.admit();

final NativePluginAdmission _defaultAdmission = NativePluginAdmission();

final class NativePluginAdmission {
  NativePluginAdmission({
    NativePluginAdmissionChannel? channel,
    bool Function()? defersRegistration,
  }) : _channel = channel ?? const PlatformNativePluginAdmissionChannel(),
       _defersRegistration = defersRegistration ?? _platformDefersRegistration;

  final NativePluginAdmissionChannel _channel;
  final bool Function() _defersRegistration;

  Future<void> admit() async {
    if (!_defersRegistration()) return;
    try {
      await _channel.admit();
    } on MissingPluginException catch (error) {
      throw NativePluginAdmissionException(
        'the plugin admission channel is missing, so no plugin would '
        'be registered: ${error.message}',
      );
    } on PlatformException catch (error) {
      throw NativePluginAdmissionException(
        'the engine refused plugin registration '
        '(${error.code}): ${error.message}',
      );
    }
  }
}

bool _platformDefersRegistration() =>
    platformDefersGeneratedPluginRegistration(Platform.operatingSystem);

abstract interface class NativePluginAdmissionChannel {
  Future<void> admit();
}

final class PlatformNativePluginAdmissionChannel
    implements NativePluginAdmissionChannel {
  const PlatformNativePluginAdmissionChannel();

  static const MethodChannel _channel = MethodChannel(
    nativePluginAdmissionChannelName,
  );

  @override
  Future<void> admit() =>
      _channel.invokeMethod<void>(nativePluginAdmissionMethod);
}
