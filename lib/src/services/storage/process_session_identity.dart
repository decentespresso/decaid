import 'package:flutter/services.dart';

import 'process_identity_source.dart';

export 'process_identity_source.dart';

const String processSessionIdentityChannelName =
    'com.reaprime/recovery_identity';

const String processSessionIdentityMethod = 'processSessionId';

/// One opaque, non-secret identity for the lifetime of the current process, or
/// null when this platform exposes no process-level source.
///
/// The value survives AppRoot reconstruction and widget rebuilds, is derived
/// only from process-level facts, and differs after a real process launch. A
/// second engine inside one process resolves the same value; nothing here is
/// derived from widget lifetime, a fresh object, an isolate-local clock or PID
/// alone. Callers must treat null as "ownership cannot be established" and fail
/// closed rather than substituting a weaker identity.
Future<String?> resolveProcessSessionId() => _defaultResolver.resolve();

final ProcessSessionIdentityResolver _defaultResolver =
    ProcessSessionIdentityResolver();

final class ProcessSessionIdentityResolver {
  ProcessSessionIdentityResolver({
    ProcessSessionProbe? probe,
    ProcessSessionIdentityChannel? channel,
  }) : _probe = probe ?? const OsProcessSessionProbe(),
       _channel = channel ?? const PlatformProcessSessionIdentityChannel();

  final ProcessSessionProbe _probe;
  final ProcessSessionIdentityChannel _channel;
  String? _identity;
  bool _resolved = false;

  Future<String?> resolve() async {
    if (!_resolved) {
      _identity = await _resolve();
      _resolved = true;
    }
    return _identity;
  }

  Future<String?> _resolve() async {
    final procIdentity = kernelProcessSessionIdentity(_probe);
    if (procIdentity != null) return procIdentity;
    return _platformIdentity();
  }

  Future<String?> _platformIdentity() async {
    final String? identity;
    try {
      identity = await _channel.resolve();
    } on MissingPluginException {
      return null;
    } on PlatformException {
      return null;
    }
    final trimmed = identity?.trim();
    if (trimmed == null || trimmed.isEmpty) return null;
    return 'native:$trimmed';
  }
}

abstract interface class ProcessSessionIdentityChannel {
  Future<String?> resolve();
}

final class PlatformProcessSessionIdentityChannel
    implements ProcessSessionIdentityChannel {
  const PlatformProcessSessionIdentityChannel();

  static const MethodChannel _channel = MethodChannel(
    processSessionIdentityChannelName,
  );

  @override
  Future<String?> resolve() =>
      _channel.invokeMethod<String>(processSessionIdentityMethod);
}
