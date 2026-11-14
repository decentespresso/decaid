import 'dart:convert';
import 'dart:io';

import 'package:logging/logging.dart';
import 'package:shelf/shelf.dart';
import 'package:shelf_router/shelf_router.dart';

import 'package:reaprime/src/services/account/proxy_token_service.dart';
import 'package:reaprime/src/services/webserver/proxy_auth_middleware.dart';

const extensionManagementGrantContextKey = 'decaid.extensionManagementGrant';

const _authorizationContextKey = 'decaid.extensionManagementAuthorization';

final _log = Logger('ExtensionManagement');

abstract interface class ExtensionManagementGrant {
  String get callerId;

  bool get isActive;
}

final class ExtensionManagementRoute {
  final String method;
  final String path;

  const ExtensionManagementRoute(this.method, this.path);

  @override
  String toString() => '$method $path';
}

const extensionManagementRoutes = <ExtensionManagementRoute>[
  ExtensionManagementRoute('POST', '/api/v1/plugins/install'),
  ExtensionManagementRoute('POST', '/api/v1/plugins/install/github-release'),
  ExtensionManagementRoute('POST', '/api/v1/plugins/install/github-branch'),
  ExtensionManagementRoute('POST', '/api/v1/plugins/update'),
  ExtensionManagementRoute('POST', '/api/v1/plugins/<id>/settings'),
  ExtensionManagementRoute('PUT', '/api/v1/plugins/<id>/source'),
  ExtensionManagementRoute('POST', '/api/v1/plugins/<id>/enable'),
  ExtensionManagementRoute('POST', '/api/v1/plugins/<id>/disable'),
  ExtensionManagementRoute('POST', '/api/v1/plugins/<id>/update/approve'),
  ExtensionManagementRoute('DELETE', '/api/v1/plugins/<id>'),
  ExtensionManagementRoute('PUT', '/api/v1/webui/skins/default'),
  ExtensionManagementRoute(
    'POST',
    '/api/v1/webui/skins/install/github-release',
  ),
  ExtensionManagementRoute('POST', '/api/v1/webui/skins/install/github-branch'),
  ExtensionManagementRoute('POST', '/api/v1/webui/skins/install/url'),
  ExtensionManagementRoute('POST', '/api/v1/webui/skins/update'),
  ExtensionManagementRoute('DELETE', '/api/v1/webui/skins/<id>'),
  ExtensionManagementRoute('POST', '/api/v1/webui/server/start'),
  ExtensionManagementRoute('POST', '/api/v1/webui/server/stop'),
];

const extensionManagementReadRoutes = <ExtensionManagementRoute>[
  ExtensionManagementRoute('GET', '/api/v1/plugins'),
  ExtensionManagementRoute('GET', '/api/v1/plugins/<id>/settings'),
  ExtensionManagementRoute('GET', '/api/v1/webui/skins'),
  ExtensionManagementRoute('GET', '/api/v1/webui/skins/default'),
  ExtensionManagementRoute('GET', '/api/v1/webui/skins/<id>'),
  ExtensionManagementRoute('GET', '/api/v1/webui/server/status'),
];

const extensionManagementSettingsRoute = ExtensionManagementRoute(
  'POST',
  '/api/v1/settings',
);

const extensionManagementSettingsKeys = {
  'defaultSkinId',
  'automaticUpdateCheck',
};

final class ExtensionManagementAuthorization {
  final ExtensionManagementGrant? _grant;
  final ProxyCaller? _caller;
  final bool _presentedBearer;

  const ExtensionManagementAuthorization._({
    required this._grant,
    required this._caller,
    required this._presentedBearer,
  });

  String get callerDescription {
    final grant = _grant;
    if (grant != null) return grant.callerId;
    final caller = _caller;
    if (caller == null) return 'unauthenticated';
    final label = caller.label;
    return label == null ? caller.id : '${caller.id} ${jsonEncode(label)}';
  }

  Response? get denial {
    final grant = _grant;
    if (grant != null) {
      return grant.isActive
          ? null
          : _unauthorized('Plugin extension-management authority has ended');
    }
    final caller = _caller;
    if (caller == null) {
      return _unauthorized(
        _presentedBearer
            ? 'Invalid token'
            : 'Missing or malformed bearer token',
      );
    }
    if (!caller.scopes.contains(ProxyTokenService.scopeExtensionsManage)) {
      return _json(
        403,
        'Token is not scoped for ${ProxyTokenService.scopeExtensionsManage}',
      );
    }
    return null;
  }
}

Middleware extensionManagementAuthMiddleware(
  ProxyTokenService? tokens, {
  List<ExtensionManagementRoute> routes = extensionManagementRoutes,
  Future<bool> Function()? automaticUpdateCheckEnabled,
  Set<String> Function()? localOrigins,
  DateTime Function() clock = DateTime.now,
}) {
  final policy = ExtensionManagementRouteMatcher(routes);
  final tokenlessUpdates = _TokenlessUpdateCheckPolicy(
    automaticUpdateCheckEnabled: automaticUpdateCheckEnabled,
    localOrigins: localOrigins,
    clock: clock,
  );
  return (Handler inner) {
    return (Request request) async {
      final grant = request.context[extensionManagementGrantContextKey];
      final bearer = bearerTokenOf(request);
      final caller = bearer == null ? null : tokens?.validate(bearer);
      final authorization = ExtensionManagementAuthorization._(
        grant: grant is ExtensionManagementGrant ? grant : null,
        caller: caller,
        presentedBearer: bearer != null,
      );

      if (await policy.matches(request)) {
        final action = '${request.method} /${request.url.path}';
        final denial = authorization.denial;
        if (denial != null &&
            grant is! ExtensionManagementGrant &&
            request.headers['authorization'] == null) {
          // A request presenting any credential keeps the credential
          // decision; only a truly tokenless loopback caller can use the
          // narrow update-check exception (#1163).
          final exception = await tokenlessUpdates.adjudicate(request, denial);
          if (exception == null) {
            _log.info('$action authorized for a tokenless loopback caller');
            try {
              return await inner(
                request.change(
                  context: {_authorizationContextKey: authorization},
                ),
              );
            } finally {
              tokenlessUpdates.recordCompletion(request);
            }
          }
          _log.warning(
            '$action refused (${exception.statusCode}) for a tokenless caller',
          );
          return exception;
        }
        final refusal = _authorize(authorization, action);
        if (refusal != null) return refusal;
      }

      return inner(
        request.change(
          context: {_authorizationContextKey: authorization},
          headers: caller != null || _carriesHostToken(request, tokens)
              ? _withoutAuthorization(request)
              : null,
        ),
      );
    };
  };
}

Response? requireExtensionManagement(
  Request request, {
  required String action,
}) {
  final authorization = request.context[_authorizationContextKey];
  if (authorization is! ExtensionManagementAuthorization) {
    return _unauthorized('Missing or malformed bearer token');
  }
  return _authorize(authorization, action);
}

bool mayManageExtensions(Request request) {
  final authorization = request.context[_authorizationContextKey];
  return authorization is ExtensionManagementAuthorization &&
      authorization.denial == null;
}

Response? _authorize(
  ExtensionManagementAuthorization authorization,
  String action,
) {
  final denial = authorization.denial;
  if (denial == null) {
    _log.info('$action authorized for ${authorization.callerDescription}');
  } else {
    _log.warning(
      '$action refused (${denial.statusCode}) for '
      '${authorization.callerDescription}',
    );
  }
  return denial;
}

bool _carriesHostToken(Request request, ProxyTokenService? tokens) {
  final authorization = request.headers['authorization'];
  if (authorization == null || tokens == null) return false;
  return authorization
      .split(RegExp(r'[\s,]+'))
      .any((part) => tokens.validate(part) != null);
}

Map<String, Object?> _withoutAuthorization(Request request) => {
  for (final name in request.headersAll.keys)
    if (name.toLowerCase() == 'authorization') name: null,
};

final class ExtensionManagementRouteMatcher {
  static final _matched = Response(204);
  static final _unmatched = Response(204);

  final Router _router = Router(notFoundHandler: (_) => _unmatched);

  ExtensionManagementRouteMatcher(Iterable<ExtensionManagementRoute> routes) {
    for (final route in routes) {
      _router.add(route.method, route.path, (Request _) => _matched);
    }
  }

  Future<bool> matches(Request request) async =>
      identical(await _router.call(request), _matched);
}

Response _unauthorized(String error) => Response(
  401,
  body: jsonEncode({'error': error}),
  headers: {'content-type': 'application/json', 'www-authenticate': 'Bearer'},
);

Response _json(int status, String error) => Response(
  status,
  body: jsonEncode({'error': error}),
  headers: {'content-type': 'application/json'},
);

Response _tooManyRequests(Duration remaining) {
  final seconds = (remaining.inMilliseconds + 999) ~/ 1000;
  return Response(
    429,
    body: jsonEncode({
      'error': 'An update check just ran; retry in $seconds seconds',
    }),
    headers: {'content-type': 'application/json', 'retry-after': '$seconds'},
  );
}

/// The narrow tokenless exception of #1163: same-device loopback callers may
/// run the two existing-source update checks while automatic update checks
/// are enabled. This is only an authorization decision for those two
/// dispatches; it never turns into a general management grant, so an admitted
/// request keeps its unauthenticated [ExtensionManagementAuthorization].
final class _TokenlessUpdateCheckPolicy {
  static const _interval = Duration(seconds: 30);

  final _matcher = ExtensionManagementRouteMatcher(const [
    ExtensionManagementRoute('POST', '/api/v1/plugins/update'),
    ExtensionManagementRoute('POST', '/api/v1/webui/skins/update'),
  ]);

  final Future<bool> Function()? _automaticUpdateCheckEnabled;
  final Set<String> Function()? _localOrigins;
  final DateTime Function() _clock;

  /// Completion times of admitted tokenless checks, keyed by the two fixed
  /// route keys. Recorded only when a dispatch finishes, so overlapping
  /// checks can still coalesce in the update services.
  final Map<String, DateTime> _completedAt = {};

  _TokenlessUpdateCheckPolicy({
    required this._automaticUpdateCheckEnabled,
    required this._localOrigins,
    required this._clock,
  });

  /// Returns null when [request] is admitted, otherwise the response to
  /// send: [denied] for every failed check (the original credential denial)
  /// or 429 when a later tokenless retry is throttled.
  Future<Response?> adjudicate(Request request, Response denied) async {
    if (!await _matcher.matches(request)) return denied;

    // The current setting value is read before every tokenless dispatch and
    // any lookup failure closes the exception.
    final readSetting = _automaticUpdateCheckEnabled;
    if (readSetting == null) return denied;
    final bool enabled;
    try {
      enabled = await readSetting();
    } catch (error, stackTrace) {
      _log.warning(
        'automaticUpdateCheck lookup failed; refusing a tokenless update check',
        error,
        stackTrace,
      );
      return denied;
    }
    if (!enabled) return denied;

    // The actual peer address is the only network qualifier; forwarding
    // headers are never consulted.
    final info = request.context['shelf.io.connection_info'];
    if (info is! HttpConnectionInfo || !_isLoopbackPeer(info.remoteAddress)) {
      return denied;
    }

    if (!_isLoopbackAuthority(request.headers['host'], info.localPort)) {
      return denied;
    }

    final origin = request.headers['origin'];
    if (origin != null && !_isAllowedOrigin(origin)) return denied;

    final key = _keyFor(request);
    final completedAt = _completedAt[key];
    if (completedAt != null) {
      final elapsed = _clock().difference(completedAt);
      if (elapsed < _interval) return _tooManyRequests(_interval - elapsed);
    }
    return null;
  }

  void recordCompletion(Request request) {
    _completedAt[_keyFor(request)] = _clock();
  }

  static String _keyFor(Request request) =>
      '${request.method.toUpperCase()} /${request.url.path}';

  bool _isAllowedOrigin(String origin) {
    for (final candidate in _localOrigins?.call() ?? const <String>{}) {
      // A configured LAN origin is never sufficient for this exception.
      if (candidate == origin && _isLoopbackOrigin(candidate)) return true;
    }
    return false;
  }
}

bool _isLoopbackPeer(InternetAddress address) {
  if (address.type == InternetAddressType.IPv4) return address.isLoopback;
  if (address.type != InternetAddressType.IPv6) return false;
  if (address.isLoopback) return true;
  // IPv4-mapped IPv6 (::ffff:a.b.c.d) with a loopback tail.
  final raw = address.rawAddress;
  if (raw.length != 16) return false;
  for (var i = 0; i < 10; i++) {
    if (raw[i] != 0) return false;
  }
  return raw[10] == 0xff && raw[11] == 0xff && raw[12] == 127;
}

bool _isLoopbackAuthority(String? header, int localPort) {
  if (header == null) return false;
  final trimmed = header.trim();
  if (trimmed.isEmpty) return false;
  try {
    final uri = Uri.parse('http://$trimmed');
    if (uri.userInfo.isNotEmpty ||
        uri.path.isNotEmpty ||
        uri.query.isNotEmpty ||
        uri.fragment.isNotEmpty) {
      return false;
    }
    if (uri.host.isEmpty || uri.port != localPort) return false;
    return _isLoopbackHost(uri.host);
  } on FormatException {
    return false;
  }
}

bool _isLoopbackOrigin(String origin) {
  final uri = Uri.tryParse(origin);
  if (uri == null) return false;
  if (uri.scheme != 'http' && uri.scheme != 'https') return false;
  if (uri.host.isEmpty) return false;
  return _isLoopbackHost(uri.host);
}

bool _isLoopbackHost(String host) {
  if (host.toLowerCase() == 'localhost') return true;
  final address = InternetAddress.tryParse(host);
  return address != null && _isLoopbackPeer(address);
}
