import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/skin_feature/skin_view.dart';
import 'package:reaprime/src/webui_support/webui_service.dart';

void main() {
  const skinPort = 24801;
  const nonce = 'cafebabe-main-frame-nonce';
  String exitUrl({int port = skinPort, String query = 'nonce=$nonce'}) =>
      'http://localhost:$port$skinExitAppPath${query.isEmpty ? '' : '?$query'}';
  final trustedPage = Uri.parse('http://localhost:$skinPort/');

  group('classifySkinNavigation', () {
    test('accepts an exit request carrying a nonce on the skin port', () {
      expect(
        classifySkinNavigation(Uri.parse(exitUrl()), skinPort: skinPort),
        SkinNavDecision.exitApp,
      );
    });

    test('blocks an exit request without a nonce', () {
      for (final url in [exitUrl(query: ''), exitUrl(query: 'nonce=')]) {
        expect(
          classifySkinNavigation(Uri.parse(url), skinPort: skinPort),
          SkinNavDecision.block,
          reason: url,
        );
      }
    });

    test('blocks extended and malformed exit requests', () {
      for (final url in [
        exitUrl(query: 'nonce=$nonce&nonce=$nonce'),
        exitUrl(query: 'nonce=$nonce&id=streamline.js'),
        '${exitUrl()}#fragment',
        'http://localhost:$skinPort$skinExitAppPath/extra?nonce=$nonce',
        'http://user@localhost:$skinPort$skinExitAppPath?nonce=$nonce',
        exitUrl(port: 24802),
        'http://localhost$skinExitAppPath?nonce=$nonce',
      ]) {
        expect(
          classifySkinNavigation(Uri.parse(url), skinPort: skinPort),
          SkinNavDecision.block,
          reason: url,
        );
      }
    });

    test('never accepts a remote exit request', () {
      for (final url in [
        'https://localhost:$skinPort$skinExitAppPath?nonce=$nonce',
        'http://example.com:$skinPort$skinExitAppPath?nonce=$nonce',
      ]) {
        expect(
          classifySkinNavigation(Uri.parse(url), skinPort: skinPort),
          isNot(SkinNavDecision.exitApp),
          reason: url,
        );
      }
    });

    test('still routes the dashboard exit and skin switch hooks', () {
      expect(
        classifySkinNavigation(
          Uri.parse(skinExitDashboardUrlForPort(skinPort)),
          skinPort: skinPort,
        ),
        SkinNavDecision.exitDashboard,
      );
      expect(
        classifySkinNavigation(
          Uri.parse(
            'http://localhost:$skinPort$skinSwitchPath?id=a&nonce=$nonce',
          ),
          skinPort: skinPort,
        ),
        SkinNavDecision.switchSkin,
      );
    });
  });

  group('exit request trust', () {
    bool trusted({
      String query = 'nonce=$nonce',
      bool isForMainFrame = true,
      Uri? topLevelUri,
      String expectedNonce = nonce,
    }) => isTrustedSkinSwitchRequest(
      target: Uri.parse(exitUrl(query: query)),
      isForMainFrame: isForMainFrame,
      topLevelUri: topLevelUri ?? trustedPage,
      skinPort: skinPort,
      expectedNonce: expectedNonce,
    );

    test('accepts the main-frame nonce from the trusted skin page', () {
      expect(trusted(), isTrue);
    });

    test('rejects a missing nonce', () {
      expect(trusted(query: ''), isFalse);
      expect(trusted(query: 'nonce='), isFalse);
    });

    test('rejects a wrong nonce', () {
      expect(trusted(query: 'nonce=guessed'), isFalse);
    });

    test('rejects a stale nonce from a retired view', () {
      expect(trusted(expectedNonce: 'a-newer-view-nonce'), isFalse);
    });

    test('never accepts an empty expected nonce', () {
      expect(trusted(query: 'nonce=', expectedNonce: ''), isFalse);
    });

    test(
      'rejects a top-level navigation started by a cross-origin subframe',
      () {
        expect(trusted(query: '', isForMainFrame: true), isFalse);
        expect(trusted(query: 'nonce=guessed', isForMainFrame: true), isFalse);
      },
    );

    test('rejects subframe navigations and untrusted top-level pages', () {
      expect(trusted(isForMainFrame: false), isFalse);
      expect(
        trusted(topLevelUri: Uri.parse('http://localhost:24802/')),
        isFalse,
      );
      expect(trusted(topLevelUri: Uri.parse('http://example.com/')), isFalse);
    });
  });

  test('skin API reads the main-frame nonce for exitApp', () {
    final script = buildSkinApiJavaScript(port: skinPort);

    expect(script, contains('window.decentApp.exitApp'));
    expect(script, contains('http://localhost:$skinPort$skinExitAppPath'));
    expect(script, contains('window.$skinSwitchNonceGlobal'));
    expect(script, contains('"?nonce="'));
  });
}
