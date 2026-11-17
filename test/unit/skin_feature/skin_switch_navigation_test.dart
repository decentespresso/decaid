import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/skin_feature/skin_view.dart';
import 'package:reaprime/src/webui_support/webui_service.dart';

void main() {
  const skinPort = 24801;
  String switchUrl(int port, String id) =>
      'http://localhost:$port$skinSwitchPath?id=$id';

  group('classifySkinNavigation', () {
    test('accepts a switch request on the active skin port', () {
      expect(
        classifySkinNavigation(
          Uri.parse(switchUrl(skinPort, 'streamline.js')),
          skinPort: skinPort,
        ),
        SkinNavDecision.switchSkin,
      );
    });

    test('blocks a switch request on the stable entry port', () {
      expect(
        classifySkinNavigation(
          Uri.parse(switchUrl(3000, 'streamline.js')),
          skinPort: 3000,
        ),
        SkinNavDecision.block,
      );
    });

    test('blocks a switch request from another skin port', () {
      expect(
        classifySkinNavigation(
          Uri.parse(switchUrl(24802, 'streamline.js')),
          skinPort: skinPort,
        ),
        SkinNavDecision.block,
      );
    });

    test('blocks a switch request without a skin id', () {
      expect(
        classifySkinNavigation(
          Uri.parse('http://localhost:$skinPort$skinSwitchPath'),
          skinPort: skinPort,
        ),
        SkinNavDecision.block,
      );
      expect(
        classifySkinNavigation(
          Uri.parse(switchUrl(skinPort, '')),
          skinPort: skinPort,
        ),
        SkinNavDecision.block,
      );
    });

    test('blocks a remote switch request', () {
      expect(
        classifySkinNavigation(
          Uri.parse('https://example.com$skinSwitchPath?id=streamline.js'),
          skinPort: skinPort,
        ),
        SkinNavDecision.openExternal,
      );
      expect(
        classifySkinNavigation(
          Uri.parse('http://example.com$skinSwitchPath?id=streamline.js'),
          skinPort: skinPort,
        ),
        SkinNavDecision.openExternal,
      );
    });

    test('still routes the exit hook and skin pages', () {
      expect(
        classifySkinNavigation(
          Uri.parse(skinExitDashboardUrlForPort(skinPort)),
          skinPort: skinPort,
        ),
        SkinNavDecision.exitDashboard,
      );
      expect(
        classifySkinNavigation(
          Uri.parse('http://localhost:$skinPort/index.html'),
          skinPort: skinPort,
        ),
        SkinNavDecision.allow,
      );
    });
  });

  group('isTrustedSkinSwitchRequest', () {
    const nonce = 'cafebabe-main-frame-nonce';
    Uri target(String id, {String? withNonce}) => Uri.parse(
      'http://localhost:$skinPort$skinSwitchPath?id=$id'
      '${withNonce == null ? '' : '&nonce=$withNonce'}',
    );

    test('accepts a request carrying the main-frame nonce', () {
      expect(
        isTrustedSkinSwitchRequest(
          target: target('streamline.js', withNonce: nonce),
          isForMainFrame: true,
          topLevelUri: Uri.parse('http://localhost:$skinPort/'),
          skinPort: skinPort,
          expectedNonce: nonce,
        ),
        isTrue,
      );
    });

    test('rejects a top-level navigation without the nonce', () {
      expect(
        isTrustedSkinSwitchRequest(
          target: target('streamline.js'),
          isForMainFrame: true,
          topLevelUri: Uri.parse('http://localhost:$skinPort/'),
          skinPort: skinPort,
          expectedNonce: nonce,
        ),
        isFalse,
      );
    });

    test('rejects a wrong or retired-generation nonce', () {
      expect(
        isTrustedSkinSwitchRequest(
          target: target('streamline.js', withNonce: 'guessed'),
          isForMainFrame: true,
          topLevelUri: Uri.parse('http://localhost:$skinPort/'),
          skinPort: skinPort,
          expectedNonce: nonce,
        ),
        isFalse,
      );
      expect(
        isTrustedSkinSwitchRequest(
          target: target('streamline.js', withNonce: nonce),
          isForMainFrame: true,
          topLevelUri: Uri.parse('http://localhost:$skinPort/'),
          skinPort: skinPort,
          expectedNonce: 'a-newer-generation-nonce',
        ),
        isFalse,
      );
    });

    test('never accepts an empty expected nonce', () {
      expect(
        isTrustedSkinSwitchRequest(
          target: target('streamline.js', withNonce: ''),
          isForMainFrame: true,
          topLevelUri: Uri.parse('http://localhost:$skinPort/'),
          skinPort: skinPort,
          expectedNonce: '',
        ),
        isFalse,
      );
    });

    test('still enforces the page trust rules', () {
      expect(
        isTrustedSkinSwitchRequest(
          target: target('streamline.js', withNonce: nonce),
          isForMainFrame: false,
          topLevelUri: Uri.parse('http://localhost:$skinPort/'),
          skinPort: skinPort,
          expectedNonce: nonce,
        ),
        isFalse,
      );
      expect(
        isTrustedSkinSwitchRequest(
          target: target('streamline.js', withNonce: nonce),
          isForMainFrame: true,
          topLevelUri: Uri.parse('http://localhost:24802/'),
          skinPort: skinPort,
          expectedNonce: nonce,
        ),
        isFalse,
      );
    });
  });

  group('isTrustedSkinPageRequest', () {
    test('accepts the active top-level skin page', () {
      expect(
        isTrustedSkinPageRequest(
          isForMainFrame: true,
          topLevelUri: Uri.parse('http://localhost:$skinPort/'),
          skinPort: skinPort,
        ),
        isTrue,
      );
    });

    test('rejects subframes, stale ports and foreign origins', () {
      expect(
        isTrustedSkinPageRequest(
          isForMainFrame: false,
          topLevelUri: Uri.parse('http://localhost:$skinPort/'),
          skinPort: skinPort,
        ),
        isFalse,
      );
      expect(
        isTrustedSkinPageRequest(
          isForMainFrame: true,
          topLevelUri: Uri.parse('http://localhost:24802/'),
          skinPort: skinPort,
        ),
        isFalse,
      );
      expect(
        isTrustedSkinPageRequest(
          isForMainFrame: true,
          topLevelUri: Uri.parse('https://example.com/'),
          skinPort: skinPort,
        ),
        isFalse,
      );
      expect(
        isTrustedSkinPageRequest(
          isForMainFrame: true,
          topLevelUri: Uri.parse('http://user@localhost:$skinPort/'),
          skinPort: skinPort,
        ),
        isFalse,
      );
      expect(
        isTrustedSkinPageRequest(
          isForMainFrame: true,
          topLevelUri: null,
          skinPort: skinPort,
        ),
        isFalse,
      );
    });
  });
}
