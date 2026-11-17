import 'dart:async';

import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/skin_feature/skin_camera_permission.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late SkinCameraConsentStore store;
  late SkinCameraPermission gate;
  late SkinCameraTarget? target;
  late Uri? topLevel;
  late bool active;
  late bool? decision;
  late bool osAllowed;
  late int prompts;
  late int osRequests;
  Future<bool?> Function()? pendingPrompt;
  Future<bool> Function()? pendingOs;

  const first = SkinCameraTarget(id: 'first', name: 'First', port: 25001);
  final origin = Uri.parse('http://localhost:25001');

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    store = const SkinCameraConsentStore();
    target = first;
    topLevel = origin.replace(path: '/camera');
    active = true;
    decision = true;
    osAllowed = true;
    prompts = 0;
    osRequests = 0;
    pendingPrompt = null;
    pendingOs = null;
    gate = SkinCameraPermission(
      store: store,
      currentTarget: () => target,
      isActive: () => active,
      prompt: (_) async {
        prompts++;
        return pendingPrompt == null ? decision : await pendingPrompt!();
      },
      requestSystemCamera: () async {
        osRequests++;
        return pendingOs == null ? osAllowed : await pendingOs!();
      },
    );
  });

  Future<PermissionResponse> request({
    Uri? from,
    List<PermissionResourceType>? resources,
  }) => gate.handle(
    PermissionRequest(
      origin: WebUri.uri(from ?? origin),
      resources: resources ?? [PermissionResourceType.CAMERA],
    ),
    readTopLevel: () async => topLevel,
  );

  test('camera needs skin consent and system permission', () async {
    final response = await request();
    expect(response.action, PermissionResponseAction.GRANT);
    expect(response.resources, [PermissionResourceType.CAMERA]);
    expect(prompts, 1);
    expect(osRequests, 1);
    expect(await store.read(first.id), isTrue);
  });

  test('remembered consent still checks system permission', () async {
    await store.write(first.id, true);
    expect((await request()).action, PermissionResponseAction.GRANT);
    expect(prompts, 0);
    expect(osRequests, 1);
  });

  test('consent is isolated by skin id and survives a new store', () async {
    await store.write(first.id, true);
    const reloaded = SkinCameraConsentStore();
    expect(await reloaded.read(first.id), isTrue);
    expect(await reloaded.read('other'), isNull);
    await reloaded.write(first.id, null);
    expect(await store.read(first.id), isNull);
  });

  for (final denied in [false, null]) {
    test('decision $denied denies without requesting system access', () async {
      decision = denied;
      expect((await request()).action, PermissionResponseAction.DENY);
      expect(osRequests, 0);
      expect(await store.read(first.id), denied);
    });
  }

  test('stored denial does not prompt again', () async {
    await store.write(first.id, false);
    expect((await request()).action, PermissionResponseAction.DENY);
    expect(prompts, 0);
    expect(osRequests, 0);
  });

  test('system denial never grants the WebView', () async {
    osAllowed = false;
    expect((await request()).action, PermissionResponseAction.DENY);
  });

  for (final url in [
    'https://localhost:25001',
    'http://localhost:3000',
    'http://localhost:8080',
    'http://localhost:25002',
    'http://127.0.0.1:25001',
    'http://localhost.example:25001',
    'http://user@localhost:25001',
    'file:///camera.html',
  ]) {
    test('denies untrusted requesting origin $url', () async {
      expect(
        (await request(from: Uri.parse(url))).action,
        PermissionResponseAction.DENY,
      );
      expect(prompts, 0);
      expect(osRequests, 0);
    });
  }

  for (final resources in [
    <PermissionResourceType>[],
    [PermissionResourceType.MICROPHONE],
    [PermissionResourceType.CAMERA, PermissionResourceType.MICROPHONE],
    [PermissionResourceType.CAMERA_AND_MICROPHONE],
  ]) {
    test('denies unsupported resources $resources', () async {
      expect(
        (await request(resources: resources)).action,
        PermissionResponseAction.DENY,
      );
      expect(prompts, 0);
    });
  }

  test('requires an active skin and matching top-level page', () async {
    topLevel = Uri.parse('http://localhost:8080/api/v1/plugins/settings');
    expect((await request()).action, PermissionResponseAction.DENY);
    topLevel = origin;
    active = false;
    expect((await request()).action, PermissionResponseAction.DENY);
    active = true;
    target = null;
    expect((await request()).action, PermissionResponseAction.DENY);
    expect(prompts, 0);
  });

  test('navigation invalidates a pending consent dialog', () async {
    final answer = Completer<bool?>();
    final opened = Completer<void>();
    pendingPrompt = () {
      opened.complete();
      return answer.future;
    };
    final response = request();
    await opened.future;
    gate.invalidate();
    answer.complete(true);
    expect((await response).action, PermissionResponseAction.DENY);
    expect(osRequests, 0);
    expect(await store.read(first.id), isNull);
  });

  test(
    'skin switch during system prompt denies the original request',
    () async {
      final answer = Completer<bool>();
      final opened = Completer<void>();
      pendingOs = () {
        opened.complete();
        return answer.future;
      };
      final response = request();
      await opened.future;
      target = const SkinCameraTarget(id: 'other', name: 'Other', port: 25001);
      answer.complete(true);
      expect((await response).action, PermissionResponseAction.DENY);
    },
  );

  test('revocation during system prompt wins over a pending grant', () async {
    final answer = Completer<bool>();
    final opened = Completer<void>();
    pendingOs = () {
      opened.complete();
      return answer.future;
    };
    final response = request();
    await opened.future;
    await store.write(first.id, false);
    answer.complete(true);
    expect((await response).action, PermissionResponseAction.DENY);
  });

  test('concurrent requests do not stack dialogs', () async {
    final answer = Completer<bool?>();
    final opened = Completer<void>();
    pendingPrompt = () {
      opened.complete();
      return answer.future;
    };
    final firstRequest = request();
    await opened.future;
    expect((await request()).action, PermissionResponseAction.DENY);
    answer.complete(true);
    expect((await firstRequest).action, PermissionResponseAction.GRANT);
    expect(prompts, 1);
  });

  test('permission and storage errors fail closed', () async {
    pendingOs = () async => throw StateError('permission unavailable');
    expect((await request()).action, PermissionResponseAction.DENY);
    SharedPreferences.setMockInitialValues({
      'skinCameraConsent.first': 'invalid',
    });
    pendingOs = null;
    expect((await request()).action, PermissionResponseAction.DENY);
  });

  test(
    'explicit capture asks even with remembered live-camera consent',
    () async {
      await store.write(first.id, true);
      expect(await gate.capture(readTopLevel: () async => topLevel), isTrue);
      expect(prompts, 1);
      expect(osRequests, 1);
    },
  );

  test(
    'explicit capture is independent of stored live-camera denial',
    () async {
      await store.write(first.id, false);
      expect(await gate.capture(readTopLevel: () async => topLevel), isTrue);
      expect(prompts, 1);
      expect(osRequests, 1);
      expect(await store.read(first.id), isFalse);
      expect((await request()).action, PermissionResponseAction.DENY);
      expect(prompts, 1);
      expect(osRequests, 1);
    },
  );

  test(
    'live-camera denial during capture does not revoke its confirmation',
    () async {
      await store.write(first.id, true);
      pendingOs = () async {
        await store.write(first.id, false);
        return true;
      };
      expect(await gate.capture(readTopLevel: () async => topLevel), isTrue);
      expect(prompts, 1);
      expect(osRequests, 1);
      expect(await store.read(first.id), isFalse);
    },
  );

  test(
    'capture after live-camera denial still requires system permission',
    () async {
      await store.write(first.id, false);
      osAllowed = false;
      expect(await gate.capture(readTopLevel: () async => topLevel), isFalse);
      expect(prompts, 1);
      expect(osRequests, 1);
      expect(await store.read(first.id), isFalse);
    },
  );

  test('navigation cancels capture after a live-camera denial', () async {
    await store.write(first.id, false);
    pendingOs = () async {
      gate.invalidate();
      return true;
    };
    expect(await gate.capture(readTopLevel: () async => topLevel), isFalse);
    expect(prompts, 1);
    expect(osRequests, 1);
  });

  for (final denied in [false, null]) {
    test(
      'capture decision $denied preserves stored live-camera denial',
      () async {
        await store.write(first.id, false);
        decision = denied;
        expect(await gate.capture(readTopLevel: () async => topLevel), isFalse);
        expect(prompts, 1);
        expect(osRequests, 0);
        expect(await store.read(first.id), isFalse);
      },
    );
  }
}
