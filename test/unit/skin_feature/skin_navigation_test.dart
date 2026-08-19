import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/skin_feature/skin_view.dart';
import 'package:reaprime/src/webui_support/webui_service.dart';

void main() {
  test('skin exit guide explains Android navigation and Dashboard purpose', () {
    final instructions = skinExitInstructions(TargetPlatform.android);

    expect(instructions, contains('settings and skin selection'));
    expect(instructions, contains('Swipe inward from either screen edge'));
    expect(instructions, contains('Android Back'));
  });

  group('classifySkinNavigation', () {
    test('allows localhost:3000 and its sub-paths', () {
      expect(
        classifySkinNavigation(Uri.parse('http://localhost:3000/')),
        SkinNavDecision.allow,
      );
      expect(
        classifySkinNavigation(Uri.parse('http://localhost:3000/foo?x=1')),
        SkinNavDecision.allow,
      );
    });

    test('allows the settings plugin path', () {
      expect(
        classifySkinNavigation(
          Uri.parse('http://localhost:8080/api/v1/plugins/settings.reaplugin'),
        ),
        SkinNavDecision.allow,
      );
    });

    test('exits to the dashboard for the exact skin exit URL', () {
      expect(
        classifySkinNavigation(Uri.parse(skinExitDashboardUrl)),
        SkinNavDecision.exitDashboard,
      );
    });

    test('blocks extended and malformed skin exit URLs', () {
      for (final url in [
        '$skinExitDashboardUrl/path',
        '$skinExitDashboardUrl?unexpected=true',
        '$skinExitDashboardUrl#fragment',
        'http://user@localhost:3000$skinExitDashboardPath',
        'http://localhost:3001$skinExitDashboardPath',
        'http://localhost$skinExitDashboardPath',
        'https://localhost:3000$skinExitDashboardPath',
        'http://example.com:3000$skinExitDashboardPath',
      ]) {
        expect(
          classifySkinNavigation(Uri.parse(url)),
          isNot(SkinNavDecision.exitDashboard),
          reason: url,
        );
      }
    });

    test('opens external https links in the browser', () {
      expect(
        classifySkinNavigation(
          Uri.parse('https://decentespresso.com/doc/quickstart/'),
        ),
        SkinNavDecision.openExternal,
      );
    });

    test('opens external (non-localhost) http links in the browser', () {
      expect(
        classifySkinNavigation(Uri.parse('http://example.com/page')),
        SkinNavDecision.openExternal,
      );
    });

    test('blocks non-http schemes', () {
      expect(
        classifySkinNavigation(Uri.parse('mailto:hi@example.com')),
        SkinNavDecision.block,
      );
      expect(
        classifySkinNavigation(Uri.parse('tel:+123')),
        SkinNavDecision.block,
      );
    });

    test('blocks a null url', () {
      expect(classifySkinNavigation(null), SkinNavDecision.block);
    });
  });

  test('only main-frame load errors replace the skin', () {
    expect(shouldShowSkinLoadError(false), isFalse);
    expect(shouldShowSkinLoadError(true), isTrue);
    expect(shouldShowSkinLoadError(null), isTrue);
  });

  group('SkinExitCoordinator', () {
    final target = Uri.parse(skinExitDashboardUrl);
    final trustedPage = Uri.parse('http://localhost:3000/?_=123');

    test('accepts one trusted main-frame request', () {
      final coordinator = SkinExitCoordinator();

      expect(
        coordinator.tryStart(
          target: target,
          isForMainFrame: true,
          topLevelUri: trustedPage,
        ),
        isTrue,
      );
      expect(
        coordinator.tryStart(
          target: target,
          isForMainFrame: true,
          topLevelUri: trustedPage,
        ),
        isFalse,
      );
      expect(coordinator.inProgress, isTrue);
    });

    test('rejects subframes and untrusted top-level origins', () {
      expect(
        SkinExitCoordinator().tryStart(
          target: target,
          isForMainFrame: false,
          topLevelUri: trustedPage,
        ),
        isFalse,
      );
      expect(
        SkinExitCoordinator().tryStart(
          target: target,
          isForMainFrame: true,
          topLevelUri: Uri.parse('http://example.com:3000/'),
        ),
        isFalse,
      );
    });
  });
}
