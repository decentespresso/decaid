import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:shelf/shelf.dart';

import 'listener_health.dart';
import 'port_binding.dart';

class ApiListener {
  ApiListener({
    required this.handler,
    this.address = '0.0.0.0',
    required this._port,
    this.healthPath = '/api/v1/info',
  });

  final Handler handler;
  final Object address;
  final String healthPath;
  int _port;
  HttpServer? _server;
  bool _stopped = false;
  int _lifecycleVersion = 0;
  Future<void>? _startOperation;
  String? _boundAddress;
  int startCount = 0;

  @visibleForTesting
  int startAttemptCount = 0;

  @visibleForTesting
  Future<void> Function()? bindBarrier;

  int get port => _port;
  String get addressString => _boundAddress ?? address.toString();
  bool get isStarted => _server != null;

  Future<void> start({bool Function()? isCancelled}) {
    if (_stopped) return Future<void>.value();
    final current = _startOperation;
    if (current != null) return current;
    final operation = _startInternal(_lifecycleVersion, isCancelled);
    _startOperation = operation.whenComplete(() => _startOperation = null);
    return _startOperation!;
  }

  Future<void> _startInternal(int version, bool Function()? isCancelled) async {
    final current = _server;
    if (current != null && await checkHealth()) return;
    if (version != _lifecycleVersion ||
        _stopped ||
        (isCancelled?.call() ?? false)) {
      return;
    }

    await current?.close(force: true);
    if (version != _lifecycleVersion ||
        _stopped ||
        (isCancelled?.call() ?? false)) {
      return;
    }
    _server = null;

    startAttemptCount++;
    final server = await serveOrReportPortInUse(handler, address, _port);
    final barrier = bindBarrier;
    if (barrier != null) await barrier();
    if (version != _lifecycleVersion ||
        _stopped ||
        (isCancelled?.call() ?? false)) {
      await server.close(force: true);
      return;
    }
    _server = server;
    _port = server.port;
    _boundAddress = server.address.address;
    startCount++;
  }

  Future<bool> checkHealth() async {
    if (_server == null) return false;
    return ListenerHealth.probe(
      Uri(scheme: 'http', host: '127.0.0.1', port: _port, path: healthPath),
      expectedStatus: HttpStatus.ok,
      expectedContentType: 'application/json',
    );
  }

  Future<void> recover({bool Function()? isCancelled}) async {
    if (_stopped || (isCancelled?.call() ?? false) || await checkHealth()) {
      return;
    }
    if (isCancelled?.call() ?? false) return;
    await start(isCancelled: isCancelled);
  }

  Future<void> stop() async {
    _stopped = true;
    _lifecycleVersion++;
    final server = _server;
    _server = null;
    await server?.close(force: true);
  }

  @visibleForTesting
  Future<void> closeForTesting() async {
    final server = _server;
    await server?.close(force: true);
  }
}
