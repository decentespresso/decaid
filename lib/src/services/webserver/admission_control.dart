part of '../webserver_service.dart';

const _admissionWindowMs = 1000;

enum AdmissionDecision { accepted, perClientLimit, globalLimit }

final class _ClientAdmissionState {
  _ClientAdmissionState(this.windowStartedAt);

  int active = 0;
  int accepted = 0;
  int windowStartedAt;
}

final class AdmissionGate {
  AdmissionGate({
    required this.globalConcurrent,
    required this.perClientConcurrent,
    required this.globalRate,
    required this.perClientRate,
    required this.maxTrackedClients,
    int Function()? nowMs,
  }) : _nowMs = nowMs ?? (() => DateTime.now().millisecondsSinceEpoch),
       assert(globalConcurrent > 0),
       assert(perClientConcurrent > 0),
       assert(globalRate > 0),
       assert(perClientRate > 0),
       assert(maxTrackedClients > 0);

  final int globalConcurrent;
  final int perClientConcurrent;
  final int globalRate;
  final int perClientRate;
  final int maxTrackedClients;
  final int Function() _nowMs;
  final Map<String, _ClientAdmissionState> _clients = {};

  int _globalActive = 0;
  int _globalAccepted = 0;
  int? _globalWindowStartedAt;

  int get activeCount => _globalActive;
  int get trackedClientCount => _clients.length;

  AdmissionDecision acquire(String clientKey) {
    final now = _nowMs();
    _removeExpiredClients(now);
    _resetGlobalWindow(now);

    var client = _clients[clientKey];
    if (client != null) {
      _resetClientWindow(client, now);
      if (client.active >= perClientConcurrent ||
          client.accepted >= perClientRate) {
        return AdmissionDecision.perClientLimit;
      }
    }
    if (_globalActive >= globalConcurrent || _globalAccepted >= globalRate) {
      return AdmissionDecision.globalLimit;
    }
    if (client == null) {
      if (_clients.length >= maxTrackedClients) {
        return AdmissionDecision.globalLimit;
      }
      client = _ClientAdmissionState(now);
      _clients[clientKey] = client;
    }

    client.active++;
    client.accepted++;
    _globalActive++;
    _globalAccepted++;
    return AdmissionDecision.accepted;
  }

  void release(String clientKey) {
    final client = _clients[clientKey];
    if (client == null || client.active == 0) return;
    client.active--;
    _globalActive--;
  }

  void _removeExpiredClients(int now) {
    _clients.removeWhere(
      (_, client) =>
          client.active == 0 &&
          now - client.windowStartedAt >= _admissionWindowMs,
    );
  }

  void _resetGlobalWindow(int now) {
    final startedAt = _globalWindowStartedAt;
    if (startedAt == null || now - startedAt >= _admissionWindowMs) {
      _globalWindowStartedAt = now;
      _globalAccepted = 0;
    }
  }

  void _resetClientWindow(_ClientAdmissionState client, int now) {
    if (now - client.windowStartedAt < _admissionWindowMs) return;
    client.windowStartedAt = now;
    client.accepted = 0;
  }
}

final _apiAdmissionGate = AdmissionGate(
  globalConcurrent: 128,
  perClientConcurrent: 32,
  globalRate: 1024,
  perClientRate: 256,
  maxTrackedClients: 256,
);

final _webSocketAdmissionGate = AdmissionGate(
  globalConcurrent: 128,
  perClientConcurrent: 32,
  globalRate: 128,
  perClientRate: 32,
  maxTrackedClients: 256,
);

Middleware apiAdmissionMiddleware(AdmissionGate gate) {
  return (innerHandler) {
    return (request) async {
      if (request.method == 'OPTIONS' ||
          !request.requestedUri.path.startsWith('/api/')) {
        return innerHandler(request);
      }

      final clientKey = clientIpFromRequest(request);
      final decision = gate.acquire(clientKey);
      if (decision != AdmissionDecision.accepted) {
        return _admissionRejected(decision);
      }
      try {
        return await innerHandler(request);
      } finally {
        gate.release(clientKey);
      }
    };
  };
}

Handler admittedWebSocketHandler(
  void Function(WebSocketChannel channel, String? protocol) onConnection, {
  AdmissionGate? gate,
}) {
  final admissionGate = gate ?? _webSocketAdmissionGate;
  return (request) async {
    final clientKey = clientIpFromRequest(request);
    final decision = admissionGate.acquire(clientKey);
    if (decision != AdmissionDecision.accepted) {
      return _admissionRejected(decision);
    }

    var released = false;
    void release() {
      if (released) return;
      released = true;
      admissionGate.release(clientKey);
    }

    final handler = sws.webSocketHandler((channel, protocol) {
      channel.sink.done.whenComplete(release);
      try {
        onConnection(channel, protocol);
      } catch (_) {
        release();
        rethrow;
      }
    });

    try {
      final response = await handler(request);
      release();
      return response;
    } on HijackException {
      rethrow;
    } catch (_) {
      release();
      rethrow;
    }
  };
}

Response _admissionRejected(AdmissionDecision decision) {
  final perClient = decision == AdmissionDecision.perClientLimit;
  return Response(
    perClient ? 429 : 503,
    body: jsonEncode({
      'error': perClient ? 'client_admission_limit' : 'global_admission_limit',
    }),
    headers: {'content-type': 'application/json', 'retry-after': '1'},
  );
}
