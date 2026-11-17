import 'dart:convert';
import 'dart:io';

import 'package:logging/logging.dart';
import 'package:shelf/shelf.dart';
import 'package:shelf_router/shelf_router.dart';

import 'package:reaprime/src/services/account/proxy_token_service.dart';
import 'package:reaprime/src/services/webserver/proxy_auth_middleware.dart';

const extensionManagementGrantContextKey = 'decaid.extensionManagementGrant';

const untrustedBrowserOriginError =
    'Extension management is not allowed from this browser origin';

const _authorizationContextKey = 'decaid.extensionManagementAuthorization';

const _browserOriginContextKey = 'decaid.browserOriginVerdict';

const _originRefusalContextKey = 'decaid.browserOriginRefusal';

const _shelfConnectionInfoContextKey = 'shelf.io.connection_info';

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

enum BrowserOriginVerdict { originless, trusted, untrusted }

final class ExtensionManagementBrowserOrigins {
  const ExtensionManagementBrowserOrigins({
    required this.apiListenerPort,
    required this.pagePorts,
    required this.deviceAddresses,
  });

  final int? Function() apiListenerPort;
  final Set<int> Function() pagePorts;
  final Future<Set<String>> Function() deviceAddresses;

  static const loopbackHosts = {'localhost', '127.0.0.1', '::1'};

  Future<BrowserOriginVerdict> classify(
    String? origin, {
    Object? connectionInfo,
  }) async {
    if (origin == null) return BrowserOriginVerdict.originless;
    if (origin.isEmpty || origin.contains(',') || origin.contains(' ')) {
      return BrowserOriginVerdict.untrusted;
    }
    final uri = Uri.tryParse(origin);
    if (uri == null ||
        uri.scheme != 'http' ||
        uri.userInfo.isNotEmpty ||
        uri.hasQuery ||
        uri.hasFragment ||
        uri.path.isNotEmpty) {
      return BrowserOriginVerdict.untrusted;
    }
    final listenerPort = apiListenerPort();
    final trustedPorts = {...pagePorts(), ?listenerPort};
    if (!trustedPorts.contains(uri.port)) return BrowserOriginVerdict.untrusted;
    final host = _hostKey(uri.host);
    if (host == null) return BrowserOriginVerdict.untrusted;
    if (_loopbackHostKeys.contains(host)) {
      return _classifyLoopbackOrigin(origin, connectionInfo);
    }
    final Set<String> addresses;
    try {
      addresses = {
        for (final address in await deviceAddresses()) ?_hostKey(address),
      };
    } catch (error, stackTrace) {
      _log.warning(
        'Could not enumerate the device addresses; refusing origin $origin',
        error,
        stackTrace,
      );
      return BrowserOriginVerdict.untrusted;
    }
    return addresses.contains(host)
        ? BrowserOriginVerdict.trusted
        : BrowserOriginVerdict.untrusted;
  }

  Future<BrowserOriginVerdict> _classifyLoopbackOrigin(
    String origin,
    Object? connectionInfo,
  ) async {
    final peer = _socketPeer(connectionInfo);
    if (peer == null) {
      _log.warning(
        'Refusing the loopback origin $origin: the request carries no reliable '
        'socket peer',
      );
      return BrowserOriginVerdict.untrusted;
    }
    if (peer.isLoopback) return BrowserOriginVerdict.trusted;
    final Set<String> addresses;
    try {
      addresses = {
        for (final address in await deviceAddresses()) ?_hostKey(address),
      };
    } catch (error, stackTrace) {
      _log.warning(
        'Could not enumerate the device addresses; refusing the loopback '
        'origin $origin',
        error,
        stackTrace,
      );
      return BrowserOriginVerdict.untrusted;
    }
    final peerKey = _hostKey(peer.address);
    return peerKey != null && addresses.contains(peerKey)
        ? BrowserOriginVerdict.trusted
        : BrowserOriginVerdict.untrusted;
  }

  static InternetAddress? _socketPeer(Object? connectionInfo) {
    if (connectionInfo is! HttpConnectionInfo) return null;
    try {
      return connectionInfo.remoteAddress;
    } catch (error, stackTrace) {
      _log.warning('The socket peer is unreadable', error, stackTrace);
      return null;
    }
  }

  static final Set<String> _loopbackHostKeys = {
    for (final host in loopbackHosts) ?_hostKey(host),
  };

  static String? _hostKey(String host) {
    final bare = host.startsWith('[') && host.endsWith(']')
        ? host.substring(1, host.length - 1)
        : host;
    if (bare.isEmpty || bare.contains('%')) return null;
    if (bare.toLowerCase() == 'localhost') return 'localhost';
    final address = InternetAddress.tryParse(bare);
    if (address == null) return null;
    return '${address.type.name}:${address.rawAddress.join('.')}';
  }
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

const extensionManagementBodySensitiveRoutes = <ExtensionManagementRoute>[
  ExtensionManagementRoute('POST', '/api/v1/settings'),
  ExtensionManagementRoute('POST', '/api/v1/data/import'),
  ExtensionManagementRoute('POST', '/api/v1/data/sync'),
];

final class _ExtensionManagementModeSnapshot {
  _ExtensionManagementModeSnapshot(this._readRequirement);

  final Future<bool> Function()? _readRequirement;
  Future<bool>? _resolved;

  Future<bool> requireAuthorization() =>
      _resolved ??= _resolveRequirement(_readRequirement);
}

final class ExtensionManagementAuthorization {
  final ExtensionManagementGrant? _grant;
  final ProxyCaller? _caller;
  final bool _presentedBearer;
  final _ExtensionManagementModeSnapshot _mode;

  const ExtensionManagementAuthorization._({
    required this._grant,
    required this._caller,
    required this._presentedBearer,
    required this._mode,
  });

  String get callerDescription {
    final grant = _grant;
    if (grant != null) return grant.callerId;
    final caller = _caller;
    if (caller == null) return 'unauthenticated';
    final label = caller.label;
    return label == null ? caller.id : '${caller.id} ${jsonEncode(label)}';
  }

  Future<Response?> denial() async {
    final grant = _grant;
    if (grant != null) {
      return grant.isActive
          ? null
          : _unauthorized('Plugin extension-management authority has ended');
    }
    if (!await _mode.requireAuthorization()) return null;
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

Middleware extensionManagementBrowserOriginMiddleware(
  ExtensionManagementBrowserOrigins origins, {
  List<ExtensionManagementRoute> routes = extensionManagementRoutes,
  List<ExtensionManagementRoute> bodyRoutes =
      extensionManagementBodySensitiveRoutes,
}) {
  final byMethod = ExtensionManagementRouteMatcher(routes);
  final byBody = ExtensionManagementRouteMatcher(bodyRoutes);
  final guarded = [...routes, ...bodyRoutes];
  final byRequestedMethod = ExtensionManagementRouteMatcher(guarded);
  final byPreflight = ExtensionManagementRouteMatcher.paths(guarded);
  return (Handler inner) {
    return (Request request) async {
      final origin = request.headers['origin'];
      if (origin == null) {
        return inner(
          request.change(
            context: {
              _browserOriginContextKey: BrowserOriginVerdict.originless,
            },
          ),
        );
      }
      final connectionInfo = request.context[_shelfConnectionInfoContextKey];
      if (request.method == 'OPTIONS') {
        if (!await _isManagementPreflight(
          request,
          byRequestedMethod,
          byPreflight,
        )) {
          return inner(request);
        }
        final verdict = await origins.classify(
          origin,
          connectionInfo: connectionInfo,
        );
        if (verdict != BrowserOriginVerdict.untrusted) {
          return inner(
            request.change(context: {_browserOriginContextKey: verdict}),
          );
        }
        _log.warning(
          'OPTIONS /${request.url.path} refused (403) for an untrusted '
          'browser origin',
        );
        return untrustedBrowserOriginRefusal();
      }
      if (await byMethod.matches(request)) {
        final verdict = await origins.classify(
          origin,
          connectionInfo: connectionInfo,
        );
        if (verdict == BrowserOriginVerdict.untrusted) {
          _log.warning(
            '${request.method} /${request.url.path} refused (403) for an '
            'untrusted browser origin',
          );
          return untrustedBrowserOriginRefusal();
        }
        return inner(
          request.change(context: {_browserOriginContextKey: verdict}),
        );
      }
      if (!await byBody.matches(request)) return inner(request);
      final verdict = await origins.classify(
        origin,
        connectionInfo: connectionInfo,
      );
      final response = await inner(
        request.change(context: {_browserOriginContextKey: verdict}),
      );
      if (!_isBrowserOriginRefusal(response)) return response;
      return _withoutAffirmativeCors(response);
    };
  };
}

bool _isBrowserOriginRefusal(Response response) =>
    response.context[_originRefusalContextKey] == true;

final _httpMethodToken = RegExp(r"^[!#$%&'*+\-.^_`|~0-9A-Za-z]+$");

Future<bool> _isManagementPreflight(
  Request request,
  ExtensionManagementRouteMatcher byMethod,
  ExtensionManagementRouteMatcher byPath,
) {
  final requested = request.headers['access-control-request-method'];
  if (requested == null || !_httpMethodToken.hasMatch(requested)) {
    return byPath.matches(request);
  }
  return byMethod.matchesMethod(requested, request);
}

Response _withoutAffirmativeCors(Response response) {
  final names = [
    for (final name in response.headers.keys)
      if (name.toLowerCase().startsWith('access-control-')) name,
  ];
  if (names.isEmpty) return response;
  return response.change(headers: {for (final name in names) name: null});
}

Response untrustedBrowserOriginRefusal() => _json(
  403,
  untrustedBrowserOriginError,
).change(context: {_originRefusalContextKey: true});

bool isUntrustedBrowserOrigin(Request request) =>
    request.context[_browserOriginContextKey] == BrowserOriginVerdict.untrusted;

Response? requireTrustedBrowserOrigin(
  Request request, {
  required String action,
}) {
  if (!isUntrustedBrowserOrigin(request)) return null;
  _log.warning('$action refused (403) for an untrusted browser origin');
  return untrustedBrowserOriginRefusal();
}

Middleware extensionManagementAuthMiddleware(
  ProxyTokenService? tokens, {
  List<ExtensionManagementRoute> routes = extensionManagementRoutes,
  Future<bool> Function()? requireExtensionManagementAuthorization,
}) {
  final policy = ExtensionManagementRouteMatcher(routes);
  return (Handler inner) {
    return (Request request) async {
      final grant = request.context[extensionManagementGrantContextKey];
      final bearer = bearerTokenOf(request);
      final caller = bearer == null ? null : tokens?.validate(bearer);
      final authorization = ExtensionManagementAuthorization._(
        grant: grant is ExtensionManagementGrant ? grant : null,
        caller: caller,
        presentedBearer: bearer != null,
        mode: _ExtensionManagementModeSnapshot(
          requireExtensionManagementAuthorization,
        ),
      );

      if (await policy.matches(request)) {
        final refusal = await _authorize(
          authorization,
          '${request.method} /${request.url.path}',
        );
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

Future<Response?> requireExtensionManagement(
  Request request, {
  required String action,
}) async {
  final authorization = request.context[_authorizationContextKey];
  if (authorization is! ExtensionManagementAuthorization) {
    return _unauthorized('Missing or malformed bearer token');
  }
  return _authorize(authorization, action);
}

Future<bool> mayManageExtensions(Request request) async {
  final authorization = request.context[_authorizationContextKey];
  if (authorization is! ExtensionManagementAuthorization) return false;
  return await authorization.denial() == null;
}

Future<Response?> _authorize(
  ExtensionManagementAuthorization authorization,
  String action,
) async {
  final denial = await authorization.denial();
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

Future<bool> _resolveRequirement(
  Future<bool> Function()? readRequirement,
) async {
  if (readRequirement == null) return true;
  try {
    return await readRequirement();
  } catch (error, stackTrace) {
    _log.warning(
      'The extension management security setting is unreadable; keeping the '
      'management routes protected',
      error,
      stackTrace,
    );
    return true;
  }
}

final class ExtensionManagementRouteMatcher {
  static final _matched = Response(204);
  static final _unmatched = Response(204);

  final Router _router = Router(notFoundHandler: (_) => _unmatched);

  ExtensionManagementRouteMatcher(Iterable<ExtensionManagementRoute> routes) {
    for (final route in routes) {
      _router.add(route.method, route.path, (Request _) => _matched);
    }
  }

  ExtensionManagementRouteMatcher.paths(
    Iterable<ExtensionManagementRoute> routes,
  ) {
    for (final route in routes) {
      _router.all(route.path, (Request _) => _matched);
    }
  }

  Future<bool> matches(Request request) async =>
      identical(await _router.call(request), _matched);

  Future<bool> matchesMethod(String method, Request request) async => identical(
    await _router.call(Request(method, request.requestedUri, url: request.url)),
    _matched,
  );
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
