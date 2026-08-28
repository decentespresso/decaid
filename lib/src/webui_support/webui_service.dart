import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:html/dom.dart' show DocumentType;
import 'package:html/parser.dart' show parse;
import 'package:logging/logging.dart';
import 'package:network_info_plus/network_info_plus.dart';
import 'package:shelf_plus/shelf_plus.dart';
import 'package:shelf/shelf_io.dart' as shelf_io;

@immutable
class SkinOverride {
  final SkinSource source;
  final String? value;

  const SkinOverride.registry() : source = SkinSource.registry, value = null;

  const SkinOverride.path(String path) : source = SkinSource.path, value = path;

  const SkinOverride.id(String skinId) : source = SkinSource.id, value = skinId;
}

enum SkinSource { registry, path, id }

@immutable
class _ResolvedHost {
  const _ResolvedHost(this.addresses, this.expiresAt);

  final List<String> addresses;
  final DateTime expiresAt;

  bool get isFresh => DateTime.now().isBefore(expiresAt);
}

const skinApiScriptPath = '/__decent/skin-api.js';
const skinExitDashboardPath = '/__decent/exit-dashboard';
const skinExitDashboardUrl = 'http://localhost:3000$skinExitDashboardPath';
const _skinProxyTokenMetaName = 'reaprime-proxy-token';
const _htmlAttributeEscape = HtmlEscape(HtmlEscapeMode.attribute);

String injectSkinApiScriptTag(
  String html, {
  required String scriptUrl,
  String? token,
}) {
  final escapedScriptUrl = _htmlAttributeEscape.convert(scriptUrl);
  final escapedToken = token == null || token.isEmpty
      ? ''
      : '<meta name="$_skinProxyTokenMetaName" content="'
            '${_htmlAttributeEscape.convert(token)}">';
  final injection = '$escapedToken<script src="$escapedScriptUrl"></script>';
  final bomLength = html.startsWith('\uFEFF') ? 1 : 0;
  final document = parse(html.substring(bomLength), generateSpans: true);
  final headOffset = document.head?.endSourceSpan?.start.offset;
  final bodyOffset = document.body?.endSourceSpan?.start.offset;
  var offset = headOffset ?? bodyOffset;
  if (offset == null) {
    for (final node in document.nodes) {
      if (node is DocumentType && node.sourceSpan != null) {
        offset = node.sourceSpan!.end.offset;
        break;
      }
    }
  }
  offset = (offset ?? 0) + bomLength;
  return '${html.substring(0, offset)}$injection'
      '${html.substring(offset)}';
}

List<int> injectSkinApiScriptTagBytes(
  List<int> bytes,
  Encoding encoding, {
  required String scriptUrl,
  String? token,
}) {
  final decoded = encoding.decode(bytes);
  final hasUtf8Bom =
      encoding.name.toLowerCase() == 'utf-8' &&
      bytes.length >= 3 &&
      bytes[0] == 0xEF &&
      bytes[1] == 0xBB &&
      bytes[2] == 0xBF;
  final html = hasUtf8Bom && !decoded.startsWith('\uFEFF')
      ? '\uFEFF$decoded'
      : decoded;
  return encoding.encode(
    injectSkinApiScriptTag(html, scriptUrl: scriptUrl, token: token),
  );
}

String skinExitDashboardUrlForPort(int port) =>
    'http://localhost:$port$skinExitDashboardPath';

String buildSkinApiJavaScript({int port = 3000}) {
  return 'var tokenMeta=document.querySelector('
      '${jsonEncode('meta[name="$_skinProxyTokenMetaName"]')});'
      'if(tokenMeta)window.__REA_PROXY_TOKEN__=tokenMeta.content;'
      'window.decentApp=window.decentApp||{};'
      'window.decentApp.exitToDashboard=function(){'
      'if(window.__DECENT_HOST__)window.location.assign('
      '${jsonEncode(skinExitDashboardUrlForPort(port))});'
      '};';
}

Future<List<String>> _listDeviceAddresses() async {
  final interfaces = await NetworkInterface.list(includeLoopback: false);
  return [
    for (final interface in interfaces)
      for (final address in interface.addresses) address.address,
  ];
}

class WebUIService {
  final _log = Logger("WebUIService");
  final Future<List<String>> Function() _listLocalAddresses;
  HttpServer? _server;
  HttpServer? _entryServer;
  final Set<int> _usedPorts = {};
  int port = 3000;
  String _path = "";
  String? _localIP;

  @visibleForTesting
  static Future<String?> Function() resolveWifiIP = NetworkInfo().getWifiIP;

  @visibleForTesting
  static Future<List<InternetAddress>> Function(String host) resolveHost =
      InternetAddress.lookup;

  @visibleForTesting
  static Duration hostResolutionTtl = const Duration(seconds: 30);

  static const int _resolvedHostLimit = 128;
  final Map<String, _ResolvedHost> _resolvedHosts = {};

  WebUIService({Future<List<String>> Function()? listLocalAddresses})
    : _listLocalAddresses = listLocalAddresses ?? _listDeviceAddresses;

  Future<String> _resolveLocalIP() async {
    try {
      final ip = await resolveWifiIP();
      if (ip != null && ip.isNotEmpty) return ip;
    } catch (e) {
      _log.warning('Failed to resolve WiFi IP, falling back to localhost', e);
    }
    return 'localhost';
  }

  SkinOverride skinOverride = const SkinOverride.registry();

  String? skinProxyToken;
  String? Function(String path)? skinProxyTokenProvider;
  void Function()? skinProxyTokenRevoker;

  Future<bool> _isDeviceAddress(String host) async {
    if (host == 'localhost' || host == '127.0.0.1' || host == '::1') {
      return true;
    }
    try {
      return (await _listLocalAddresses()).contains(host);
    } catch (e) {
      _log.fine('Failed to enumerate network interfaces: $e');
      return host == _localIP;
    }
  }

  Future<bool> _isDeviceHost(String host) async {
    if (await _isDeviceAddress(host)) return true;
    List<String> local;
    try {
      local = await _listLocalAddresses();
    } catch (e) {
      _log.fine('Failed to enumerate network interfaces: $e');
      return false;
    }
    return (await _resolvedAddresses(host)).any(local.contains);
  }

  Future<List<String>> _resolvedAddresses(String host) async {
    final cached = _resolvedHosts[host];
    if (cached != null && cached.isFresh) return cached.addresses;
    List<String> addresses;
    try {
      addresses = [
        for (final address in await resolveHost(host)) address.address,
      ];
    } catch (e) {
      _log.fine('Failed to resolve host $host: $e');
      addresses = const [];
    }
    if (_resolvedHosts.length >= _resolvedHostLimit) _resolvedHosts.clear();
    _resolvedHosts[host] = _ResolvedHost(
      addresses,
      DateTime.now().add(hostResolutionTtl),
    );
    return addresses;
  }

  Future<String?> _skinApiUrl(Request request, int port) async {
    final uri = request.requestedUri;
    if (uri.scheme != 'http' || uri.port != port || uri.userInfo.isNotEmpty) {
      return null;
    }
    if (!await _isDeviceHost(uri.host)) return null;
    return Uri(
      scheme: 'http',
      host: uri.host,
      port: port,
      path: skinApiScriptPath,
    ).toString();
  }

  Future<void> serveFolderAtPath(String path, {int port = 3000}) async {
    await _server?.close(force: true);
    _server = null;
    _resolvedHosts.clear();
    final tokenProvider = skinProxyTokenProvider;
    if (tokenProvider != null) _revokeSkinProxyToken();
    _localIP ??= await _resolveLocalIP();

    final webUI = createStaticHandler(
      path,
      defaultDocument: 'index.html',
      serveFilesOutsidePath: false,
      listDirectories: true,
    );

    FutureOr<Response> skinHandler(Request request) {
      if (request.url.path == skinApiScriptPath.substring(1)) {
        return Response.ok(
          request.method == 'HEAD'
              ? null
              : buildSkinApiJavaScript(port: this.port),
          headers: {
            'Content-Type': 'application/javascript; charset=utf-8',
            'Cache-Control': 'no-store',
            'Cross-Origin-Resource-Policy': 'same-origin',
            'X-Content-Type-Options': 'nosniff',
          },
        );
      }
      return webUI(request);
    }

    Future<Response> Function(Request request) expirationModifier(
      Handler innerHandler,
    ) {
      return (Request request) async {
        _log.fine("handling request: ${request.requestedUri.path}");
        final response = await innerHandler(request);

        if (request.requestedUri.path.startsWith('/ws')) {
          return response;
        }

        return response.change(
          headers: {
            ...response.headersAll,
            'Cache-Control': 'no-cache, no-store, must-revalidate',
            'Expires': "0",
          },
        );
      };
    }

    Future<Response> Function(Request request) skinApiInjector(
      Handler innerHandler,
    ) {
      return (Request request) async {
        final response = await innerHandler(request);
        final contentType = response.headers['content-type'] ?? '';
        if (request.method == 'HEAD' ||
            response.statusCode != HttpStatus.ok ||
            !contentType.toLowerCase().startsWith('text/html') ||
            response.headers.containsKey('content-encoding')) {
          return response;
        }
        final scriptUrl = await _skinApiUrl(request, this.port);
        if (scriptUrl == null) return response;
        final token = await _isDeviceAddress(request.requestedUri.host)
            ? skinProxyToken
            : null;
        final encoding = response.encoding ?? utf8;
        final body = await response.read().expand((chunk) => chunk).toList();
        final injected = injectSkinApiScriptTagBytes(
          body,
          encoding,
          scriptUrl: scriptUrl,
          token: token,
        );
        return response.change(
          body: injected,
          headers: {
            'accept-ranges': null,
            'content-length': null,
            'content-md5': null,
            'content-range': null,
            'etag': null,
            'last-modified': null,
          },
        );
      };
    }

    final handler = const Pipeline()
        .addMiddleware(logRequests())
        .addMiddleware(expirationModifier)
        .addMiddleware(skinApiInjector)
        .addHandler(skinHandler);

    try {
      if (tokenProvider != null) skinProxyToken = tokenProvider(path);
      _server = await _serveFresh(handler);
      this.port = _server!.port;
      await _serveEntryPoint(port);
      _log.fine("serving $path");
      _path = path;
    } catch (e, st) {
      await _server?.close(force: true);
      await _entryServer?.close(force: true);
      _server = null;
      _entryServer = null;
      _revokeSkinProxyToken();
      _log.severe("failed to start serving", e, st);
      rethrow;
    }
  }

  void _revokeSkinProxyToken() {
    if (skinProxyToken != null) skinProxyTokenRevoker?.call();
    skinProxyToken = null;
  }

  Future<HttpServer> _serveFresh(Handler handler) async {
    while (true) {
      final server = await shelf_io.serve(handler, '0.0.0.0', 0);
      if (_usedPorts.add(server.port)) return server;
      await server.close(force: true);
    }
  }

  Future<void> _serveEntryPoint(int requestedPort) async {
    if (_entryServer?.port == requestedPort) return;
    await _entryServer?.close(force: true);
    _entryServer = await shelf_io.serve(
      (request) async {
        final uri = request.requestedUri;
        if (uri.scheme != 'http' ||
            uri.userInfo.isNotEmpty ||
            !await _isDeviceHost(uri.host)) {
          return Response.notFound('Not found');
        }
        return Response(
          HttpStatus.temporaryRedirect,
          headers: {
            HttpHeaders.locationHeader: uri.replace(port: port).toString(),
            HttpHeaders.cacheControlHeader: 'no-store',
          },
        );
      },
      '0.0.0.0',
      requestedPort,
    );
  }

  String serverIP() {
    _log.fine("server ip: ${_server?.address.address}");
    return Platform.isAndroid
        ? _server?.address.address ?? "localhost"
        : "localhost";
  }

  String deviceIp() {
    return _localIP ?? "";
  }

  String serverPath() {
    return _path;
  }

  bool get isServing => _server != null;

  Future<void> stopServing() async {
    if (_server != null || _entryServer != null) {
      _log.info('Stopping WebUI server on port $port');
      await _server?.close(force: true);
      await _entryServer?.close(force: true);
      _server = null;
      _entryServer = null;
      _path = "";
      _log.info('WebUI server stopped');
    }
    _resolvedHosts.clear();
    _revokeSkinProxyToken();
  }
}
