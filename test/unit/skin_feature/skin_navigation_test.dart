import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/skin_feature/skin_view.dart';
import 'package:reaprime/src/webui_support/webui_service.dart';

void main() {
  group('classifySkinNavigation', () {
    test('allows the active skin origin and its sub-paths', () {
      expect(
        classifySkinNavigation(
          Uri.parse('http://localhost:43210/'),
          skinPort: 43210,
        ),
        SkinNavDecision.allow,
      );
      expect(
        classifySkinNavigation(
          Uri.parse('http://localhost:43210/foo?x=1'),
          skinPort: 43210,
        ),
        SkinNavDecision.allow,
      );
      expect(
        classifySkinNavigation(
          Uri.parse('http://localhost:3000/'),
          skinPort: 43210,
        ),
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
      final url = skinExitDashboardUrlForPort(43210);
      expect(
        classifySkinNavigation(Uri.parse(url), skinPort: 43210),
        SkinNavDecision.exitDashboard,
      );
    });

    test('blocks extended and malformed skin exit URLs', () {
      final url = skinExitDashboardUrlForPort(43210);
      for (final url in [
        '$url/path',
        '$url?unexpected=true',
        '$url#fragment',
        'http://user@localhost:43210$skinExitDashboardPath',
        'http://localhost:43211$skinExitDashboardPath',
        'http://localhost$skinExitDashboardPath',
        'https://localhost:43210$skinExitDashboardPath',
        'http://example.com:43210$skinExitDashboardPath',
      ]) {
        expect(
          classifySkinNavigation(Uri.parse(url), skinPort: 43210),
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

  group('SkinExitCoordinator', () {
    final target = Uri.parse(skinExitDashboardUrlForPort(43210));
    final trustedPage = Uri.parse('http://localhost:43210/?_=123');

    test('accepts one trusted main-frame request', () {
      final coordinator = SkinExitCoordinator();

      expect(
        coordinator.tryStart(
          target: target,
          isForMainFrame: true,
          topLevelUri: trustedPage,
          skinPort: 43210,
        ),
        isTrue,
      );
      expect(
        coordinator.tryStart(
          target: target,
          isForMainFrame: true,
          topLevelUri: trustedPage,
          skinPort: 43210,
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
          skinPort: 43210,
        ),
        isFalse,
      );
      expect(
        SkinExitCoordinator().tryStart(
          target: target,
          isForMainFrame: true,
          topLevelUri: Uri.parse('http://example.com:43210/'),
          skinPort: 43210,
        ),
        isFalse,
      );
    });
  });
}
