import 'dart:convert';

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
}) {
  final policy = _RoutePolicy(routes);
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

      if (await policy.protects(request)) {
        final denial = _authorize(
          authorization,
          '${request.method} /${request.url.path}',
        );
        if (denial != null) return denial;
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

final class _RoutePolicy {
  static final _protected = Response(204);
  static final _unprotected = Response(204);

  final Router _router = Router(notFoundHandler: (_) => _unprotected);

  _RoutePolicy(List<ExtensionManagementRoute> routes) {
    for (final route in routes) {
      _router.add(route.method, route.path, (Request _) => _protected);
    }
  }

  Future<bool> protects(Request request) async =>
      identical(await _router.call(request), _protected);
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
