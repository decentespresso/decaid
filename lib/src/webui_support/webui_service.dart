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

/// What source to serve a skin from — overrides the registry default.
@immutable
class SkinOverride {
  final SkinSource source;
  final String? value;

  const SkinOverride.registry() : source = SkinSource.registry, value = null;

  const SkinOverride.path(String path) : source = SkinSource.path, value = path;

  const SkinOverride.id(String skinId) : source = SkinSource.id, value = skinId;
}

enum SkinSource {
  /// Normal behavior: lookup from WebUIStorage registry.
  registry,

  /// Serve directly from a filesystem path (--skin-path).
  path,

  /// Serve a specific skin ID from the registry, session-only (future).
  id,
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

String buildSkinApiJavaScript() {
  return 'var tokenMeta=document.querySelector('
      '${jsonEncode('meta[name="$_skinProxyTokenMetaName"]')});'
      'if(tokenMeta)window.__REA_PROXY_TOKEN__=tokenMeta.content;'
      'window.decentApp=window.decentApp||{};'
      'window.decentApp.exitToDashboard=function(){'
      'if(window.__DECENT_HOST__)window.location.assign('
      '${jsonEncode(skinExitDashboardUrl)});'
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
  int port = 3000;
  String _path = "";
  String? _localIP;

  /// Test seam: override in tests to simulate offline/no-WiFi without
  /// touching the real platform channel. Returns null when no WiFi IP is
  /// available (null-collapsed by [_resolveLocalIP]).
  @visibleForTesting
  static Future<String?> Function() resolveWifiIP = NetworkInfo().getWifiIP;

  WebUIService({Future<List<String>> Function()? listLocalAddresses})
    : _listLocalAddresses = listLocalAddresses ?? _listDeviceAddresses;

  /// Resolves the device's WiFi IP for the browser-hero card and QR code.
  /// Must not block the critical path — falls back to "localhost" when the
  /// platform call throws or the device is offline (gh#337).
  Future<String> _resolveLocalIP() async {
    try {
      final ip = await resolveWifiIP();
      if (ip != null && ip.isNotEmpty) return ip;
    } catch (e) {
      _log.warning('Failed to resolve WiFi IP, falling back to localhost', e);
    }
    return 'localhost';
  }

  /// Overrides the skin source for the initialization step. Set from CLI flags
  /// (--skin-path) before the onboarding flow starts. Defaults to [SkinSource.registry].
  SkinOverride skinOverride = const SkinOverride.registry();

  /// Current account-proxy skin token, set from `ProxyTokenService.skinToken`.
  /// Injected into served HTML so skins can call the proxy. Null = no injection.
  String? skinProxyToken;

  /// Accepts loopback or an address currently assigned to this device.
  Future<bool> _isLocalHost(String host) async {
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

  Future<String?> _skinApiUrl(Request request, int port) async {
    final uri = request.requestedUri;
    if (uri.scheme != 'http' || uri.port != port || uri.userInfo.isNotEmpty) {
      return null;
    }
    if (!await _isLocalHost(uri.host)) return null;
    return Uri(
      scheme: 'http',
      host: uri.host,
      port: port,
      path: skinApiScriptPath,
    ).toString();
  }

  Future<void> serveFolderAtPath(String path, {int port = 3000}) async {
    await _server?.close(force: true);
    _localIP ??= await _resolveLocalIP();

    // 1. Get system temp directory
    // final documents = await getApplicationDocumentsDirectory();
    // final tempDir = Directory("${documents.path}/served_folder_");
    // if (await tempDir.exists()) {
    //   await tempDir.delete(recursive: true);
    // }
    // final tempPath = tempDir.path;
    // final srcDir = Directory(path);
    // _log.fine("attempting copy from:");
    // _log.fine("${srcDir.listSync(recursive: true)}");
    // if (await srcDir.exists() == false) {
    //     throw "No";
    //   }

    // 2. Copy folder to temp
    // await tempDir.create(recursive: true);
    // await _copyDirectory(Directory(path), tempDir);
    // copyDirectorySync(srcDir, tempDir);

    // _log.fine("copied data:");
    // final list = tempDir.listSync(recursive: true);
    // _log.fine("${list}");
    // _log.fine("loading from $tempPath");

    final webUI = createStaticHandler(
      path,
      defaultDocument: 'index.html',
      serveFilesOutsidePath: false,
      listDirectories: true,
    );

    FutureOr<Response> skinHandler(Request request) {
      if (request.url.path == skinApiScriptPath.substring(1)) {
        return Response.ok(
          request.method == 'HEAD' ? null : buildSkinApiJavaScript(),
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

        // Option 2: Alternatively, check if the request has an Upgrade header
        // if ((request.headers['upgrade']?.toLowerCase() ?? '') == 'websocket') {
        //   return response;
        // }

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
        final scriptUrl = await _skinApiUrl(request, port);
        if (scriptUrl == null) return response;
        final encoding = response.encoding ?? utf8;
        final body = await response.read().expand((chunk) => chunk).toList();
        final injected = injectSkinApiScriptTagBytes(
          body,
          encoding,
          scriptUrl: scriptUrl,
          token: skinProxyToken,
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

    //   final handler = (Request request) async {
    //   return Response.ok('<html><body><h1>Hello WebView</h1></body></html>',
    //     headers: {'Content-Type': 'text/html'});
    // };
    // NOTE: no CORS middleware here on purpose. The skin token is injected into
    // served HTML, so the :3000 host must NOT send Access-Control-Allow-Origin:
    // * — otherwise a malicious site could fetch the skin cross-origin and
    // scrape the token. Skins read their own assets same-origin (no CORS needed)
    // and call the :8080 API cross-origin (governed by :8080's CORS).
    final handler = const Pipeline()
        .addMiddleware(logRequests())
        .addMiddleware(expirationModifier)
        .addMiddleware(skinApiInjector)
        .addHandler(skinHandler);

    try {
      _server = await shelf_io.serve(handler, '0.0.0.0', port);
      _log.fine("serving $path");
      _path = path;
    } catch (e, st) {
      _log.severe("failed to start serving", e, st);
      rethrow;
    }
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
    if (_server != null) {
      _log.info('Stopping WebUI server on port $port');
      await _server?.close(force: true);
      _server = null;
      _path = "";
      _log.info('WebUI server stopped');
    }
  }
}
