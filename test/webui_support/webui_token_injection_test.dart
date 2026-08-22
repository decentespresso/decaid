import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:network_info_plus/network_info_plus.dart';
import 'package:reaprime/src/webui_support/webui_service.dart';

void main() {
  const token = 'abc.123';
  const scriptUrl = 'http://localhost:3000$skinApiScriptPath';
  const scriptTag = '<script src="$scriptUrl"></script>';

  test('handles mixed-case tags without moving the doctype', () {
    const html = '\uFEFF<!doctype html><HTML><HEAD></HEAD><BODY></BODY></HTML>';
    final out = injectSkinApiScriptTag(html, scriptUrl: scriptUrl);

    expect(out, startsWith('\uFEFF<!doctype html>'));
    expect(out, contains('<HEAD>$scriptTag</HEAD>'));
  });

  test('ignores closing-tag text inside scripts', () {
    const html = '''<!doctype html><html><head><script>
const headExample = "</head>";
const bodyExample = "</body>";
</script></head><body></body></html>''';
    final out = injectSkinApiScriptTag(html, scriptUrl: scriptUrl);

    expect(out, contains('const headExample = "</head>";'));
    expect(out, contains('const bodyExample = "</body>";'));
    expect(out, contains('</script>$scriptTag</head>'));
  });

  test('ignores markers inside comments and templates', () {
    const html =
        '<html><head><!-- </head> --><template></head></template></head>'
        '<body><!-- </body> --></body></html>';
    final out = injectSkinApiScriptTag(html, scriptUrl: scriptUrl);

    expect(out, contains('<!-- </head> -->'));
    expect(out, contains('<template></head></template>'));
    expect(out, contains('<!-- </body> -->$scriptTag</body>'));
  });

  test('inserts after a BOM and doctype when head and body are absent', () {
    const html = '\uFEFF<!doctype html>plain text';
    expect(
      injectSkinApiScriptTag(html, scriptUrl: scriptUrl),
      '\uFEFF<!doctype html>${scriptTag}plain text',
    );
  });

  test('injects into an empty document', () {
    expect(injectSkinApiScriptTag('', scriptUrl: scriptUrl), scriptTag);
  });

  test('preserves UTF-8 BOM and declared response encodings', () {
    const html = '<html><head></head><body>caf\u00E9</body></html>';
    final utf8Bytes = [0xEF, 0xBB, 0xBF, ...utf8.encode(html)];
    final utf8Out = injectSkinApiScriptTagBytes(
      utf8Bytes,
      utf8,
      scriptUrl: scriptUrl,
    );
    final latin1Out = injectSkinApiScriptTagBytes(
      latin1.encode(html),
      latin1,
      scriptUrl: scriptUrl,
    );

    expect(utf8Out.take(3), [0xEF, 0xBB, 0xBF]);
    expect(utf8.decode(utf8Out).replaceFirst(scriptTag, ''), html);
    expect(latin1.decode(latin1Out).replaceFirst(scriptTag, ''), html);
  });

  test('builds a static skin API that reads token metadata', () {
    final script = buildSkinApiJavaScript();

    expect(script, contains('window.decentApp'));
    expect(script, contains('tokenMeta.content'));
    expect(script, isNot(contains(token)));
    expect(script, contains(skinExitDashboardUrl));
  });

  test('injects the token as escaped non-executable metadata', () {
    final out = injectSkinApiScriptTag(
      '<head></head>',
      scriptUrl: scriptUrl,
      token: 'a"<&',
    );

    expect(
      out,
      contains('<meta name="reaprime-proxy-token" content="a&quot;&lt;&amp;">'),
    );
  });

  group('serveFolderAtPath offline', () {
    late Directory tempDir;
    late WebUIService service;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('webui_offline_test');
      await File(
        '${tempDir.path}/index.html',
      ).writeAsString('<html><body>test</body></html>');
      service = WebUIService();
    });

    tearDown(() async {
      await service.stopServing();
      if (tempDir.existsSync()) {
        await tempDir.delete(recursive: true);
      }
      WebUIService.resolveWifiIP = NetworkInfo().getWifiIP;
    });

    Future<String> getBodyForHost(String host) async {
      final client = HttpClient();
      addTearDown(client.close);
      final request = await client.getUrl(
        Uri.parse('http://localhost:${service.port}/'),
      );
      request.headers.set(HttpHeaders.hostHeader, '$host:${service.port}');
      final response = await request.close();
      return response.transform(utf8.decoder).join();
    }

    test('protects the skin API across origins', () async {
      const lanIp = '192.168.50.20';
      WebUIService.resolveWifiIP = () async => lanIp;
      service = WebUIService(listLocalAddresses: () async => [lanIp]);
      await File('${tempDir.path}/index.html').writeAsString(
        '<html><head><meta http-equiv="Content-Security-Policy" '
        'content="script-src \'self\'"><base href="https://example.invalid/">'
        '</head><body>test</body></html>',
      );
      service.skinProxyToken = token;
      await service.serveFolderAtPath(tempDir.path);

      final client = HttpClient();
      addTearDown(client.close);
      final request = await client.getUrl(
        Uri.parse('http://localhost:${service.port}/'),
      );
      final response = await request.close();
      final body = await response.transform(utf8.decoder).join();

      expect(
        body,
        contains(
          '<script src="http://localhost:${service.port}$skinApiScriptPath">'
          '</script>',
        ),
      );
      expect(body, contains("script-src 'self'"));
      expect(body, contains('content="$token"'));
      expect(response.headers.value(HttpHeaders.acceptRangesHeader), isNull);
      expect(response.headers.value(HttpHeaders.lastModifiedHeader), isNull);

      final lanRequest = await client.getUrl(
        Uri.parse('http://localhost:${service.port}/'),
      );
      lanRequest.headers.set(HttpHeaders.hostHeader, '$lanIp:${service.port}');
      final lanResponse = await lanRequest.close();
      final lanBody = await lanResponse.transform(utf8.decoder).join();
      expect(
        lanBody,
        contains(
          '<script src="http://$lanIp:${service.port}$skinApiScriptPath">'
          '</script>',
        ),
      );

      final untrustedRequest = await client.getUrl(
        Uri.parse('http://localhost:${service.port}/'),
      );
      untrustedRequest.headers.set(
        HttpHeaders.hostHeader,
        'example.invalid:${service.port}',
      );
      final untrustedResponse = await untrustedRequest.close();
      final untrustedBody = await untrustedResponse
          .transform(utf8.decoder)
          .join();
      expect(untrustedBody, isNot(contains('reaprime-proxy-token')));
      expect(untrustedBody, isNot(contains(skinApiScriptPath)));

      final scriptRequest = await client.getUrl(
        Uri.parse('http://localhost:${service.port}$skinApiScriptPath'),
      );
      final scriptResponse = await scriptRequest.close();
      final script = await scriptResponse.transform(utf8.decoder).join();

      expect(scriptResponse.statusCode, HttpStatus.ok);
      expect(
        scriptResponse.headers.contentType?.mimeType,
        'application/javascript',
      );
      expect(
        scriptResponse.headers.value('cross-origin-resource-policy'),
        'same-origin',
      );
      expect(script, contains('window.decentApp'));
      expect(script, isNot(contains(token)));
    });

    test('switching skins rotates both browser origin and token', () async {
      final secondDir = await Directory.systemTemp.createTemp(
        'webui_second_skin',
      );
      addTearDown(() => secondDir.delete(recursive: true));
      await File(
        '${secondDir.path}/index.html',
      ).writeAsString('<html><body>second</body></html>');
      var generation = 0;
      service.skinProxyTokenProvider = (_) => 'token-${++generation}';

      await service.serveFolderAtPath(tempDir.path);
      final firstPort = service.port;
      final firstToken = service.skinProxyToken;
      await service.serveFolderAtPath(secondDir.path);

      expect(service.port, isNot(firstPort));
      expect(service.skinProxyToken, isNot(firstToken));

      final client = HttpClient();
      addTearDown(client.close);
      await expectLater(
        client.getUrl(Uri.parse('http://localhost:$firstPort/')),
        throwsA(isA<SocketException>()),
      );
      final entryRequest = await client.getUrl(
        Uri.parse('http://localhost:3000/'),
      );
      entryRequest.followRedirects = false;
      final entryResponse = await entryRequest.close();
      expect(entryResponse.statusCode, HttpStatus.temporaryRedirect);
      expect(
        entryResponse.headers.value(HttpHeaders.locationHeader),
        'http://localhost:${service.port}/',
      );
      final request = await client.getUrl(
        Uri.parse('http://localhost:${service.port}/'),
      );
      final response = await request.close();
      final body = await response.transform(utf8.decoder).join();
      expect(body, contains('content="token-2"'));
      expect(body, isNot(contains('token-1')));
    });

    test('stopping the server revokes the served skin token', () async {
      var revocations = 0;
      service.skinProxyTokenProvider = (_) => token;
      service.skinProxyTokenRevoker = () => revocations++;
      await service.serveFolderAtPath(tempDir.path);

      await service.stopServing();

      expect(revocations, 1);
      expect(service.skinProxyToken, isNull);
    });

    test('accepts another local interface address', () async {
      const wifiIp = '192.168.50.20';
      const ethernetIp = '10.0.0.7';
      WebUIService.resolveWifiIP = () async => wifiIp;
      service = WebUIService(listLocalAddresses: () async => [ethernetIp]);
      service.skinProxyToken = token;
      await service.serveFolderAtPath(tempDir.path, port: 3001);

      final body = await getBodyForHost(ethernetIp);

      expect(body, contains('content="$token"'));
      expect(
        body,
        contains(
          '<script src="http://$ethernetIp:${service.port}$skinApiScriptPath">'
          '</script>',
        ),
      );
    });

    test('rejects a stale cached WiFi address', () async {
      const staleWifiIp = '192.168.50.20';
      WebUIService.resolveWifiIP = () async => staleWifiIp;
      service = WebUIService(listLocalAddresses: () async => ['10.0.0.7']);
      service.skinProxyToken = token;
      await service.serveFolderAtPath(tempDir.path, port: 3001);

      final body = await getBodyForHost(staleWifiIp);

      expect(body, isNot(contains('reaprime-proxy-token')));
      expect(body, isNot(contains(skinApiScriptPath)));
    });

    test('accepts the cached WiFi address when enumeration fails', () async {
      const wifiIp = '192.168.50.20';
      WebUIService.resolveWifiIP = () async => wifiIp;
      service = WebUIService(
        listLocalAddresses: () async => throw Exception('unavailable'),
      );
      service.skinProxyToken = token;
      await service.serveFolderAtPath(tempDir.path, port: 3001);

      final body = await getBodyForHost(wifiIp);

      expect(body, contains('content="$token"'));
      expect(body, contains(skinApiScriptPath));
    });

    test('rejects an arbitrary host', () async {
      WebUIService.resolveWifiIP = () async => '192.168.50.20';
      service = WebUIService(listLocalAddresses: () async => ['10.0.0.7']);
      service.skinProxyToken = token;
      await service.serveFolderAtPath(tempDir.path, port: 3001);

      final body = await getBodyForHost('example.invalid');

      expect(body, isNot(contains('reaprime-proxy-token')));
      expect(body, isNot(contains(skinApiScriptPath)));
    });

    test('falls back to localhost when getWifiIP throws (gh#337)', () async {
      WebUIService.resolveWifiIP = () async => throw Exception('no wifi');

      await service.serveFolderAtPath(tempDir.path);

      expect(service.isServing, isTrue);
      expect(service.deviceIp(), 'localhost');
    });

    test('falls back to localhost when getWifiIP returns null', () async {
      WebUIService.resolveWifiIP = () async => null;

      await service.serveFolderAtPath(tempDir.path);

      expect(service.isServing, isTrue);
      expect(service.deviceIp(), 'localhost');
    });

    test(
      'falls back to localhost when getWifiIP returns empty string',
      () async {
        WebUIService.resolveWifiIP = () async => '';

        await service.serveFolderAtPath(tempDir.path);

        expect(service.isServing, isTrue);
        expect(service.deviceIp(), 'localhost');
      },
    );
  });
}
