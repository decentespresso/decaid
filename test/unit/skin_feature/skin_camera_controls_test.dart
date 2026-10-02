import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/skin_feature/skin_camera_controls.dart';
import 'package:reaprime/src/skin_feature/skin_camera_permission.dart';
import 'package:reaprime/src/skin_feature/skin_camera_webview_access.dart';
import 'package:reaprime/src/theme/theme.dart';
import 'package:shadcn_ui/shadcn_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';

class CameraTestController implements InAppWebViewController {
  @override
  Future<WebUri?> getUrl() async => WebUri('http://localhost:25001/camera');

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  const store = SkinCameraConsentStore();
  const target = SkinCameraTarget(id: 'first', name: 'First', port: 25001);
  final controller = CameraTestController();
  final request = PermissionRequest(
    origin: WebUri('http://localhost:25001'),
    resources: [PermissionResourceType.CAMERA],
  );

  setUp(() => SharedPreferences.setMockInitialValues({}));

  setUpAll(() async {
    if (Platform.environment['DECAID_UI_EVIDENCE'] == null) return;
    for (final family in ['Roboto', 'packages/shadcn_ui/Geist']) {
      await (FontLoader(family)..addFont(
            rootBundle.load('packages/shadcn_ui/fonts/Geist[wght].ttf'),
          ))
          .load();
    }
    await (FontLoader(
      'MaterialIcons',
    )..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'))).load();
  });

  for (final width in [320.0, 800.0]) {
    for (final textScale in [1.0, 2.0]) {
      testWidgets(
        'camera controls fit width $width and text scale $textScale',
        (tester) async {
          await tester.binding.setSurfaceSize(Size(width, 600));
          addTearDown(() => tester.binding.setSurfaceSize(null));
          final boundary = GlobalKey();
          await tester.pumpWidget(
            ShadApp(
              theme: buildDecentTheme(),
              home: MediaQuery(
                data: MediaQueryData(textScaler: TextScaler.linear(textScale)),
                child: RepaintBoundary(
                  key: boundary,
                  child: const Scaffold(
                    body: Padding(
                      padding: EdgeInsets.all(16),
                      child: SkinCameraConsentSetting(skinId: 'first'),
                    ),
                  ),
                ),
              ),
            ),
          );
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull);
          expect(find.text('Camera access'), findsOneWidget);
          final output = Platform.environment['DECAID_UI_EVIDENCE'];
          if (output != null) {
            await tester.runAsync(() async {
              final image =
                  await (boundary.currentContext!.findRenderObject()
                          as RenderRepaintBoundary)
                      .toImage();
              final bytes = await image.toByteData(
                format: ui.ImageByteFormat.png,
              );
              await File(
                '$output/camera-$width-$textScale.png',
              ).writeAsBytes(bytes!.buffer.asUint8List());
              image.dispose();
            });
          }
        },
      );
    }
  }

  testWidgets('ordinary file selection never delegates to capture intents', (
    tester,
  ) async {
    const channel = MethodChannel('miguelruivo.flutter.plugins.filepicker');
    MethodCall? selection;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
      call,
    ) async {
      selection = call;
      return [
        {'name': 'beans.jpg', 'path': '/cache/beans.jpg', 'size': 10},
      ];
    });
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        channel,
        null,
      ),
    );
    final access = SkinCameraWebViewAccess(
      context: () => null,
      currentTarget: () => target,
      requestSystemCamera: () async => throw StateError('Unexpected camera'),
    );
    addTearDown(access.dispose);
    final response = await access.onShowFileChooser(
      controller,
      ShowFileChooserRequest(
        acceptTypes: ['image/*'],
        isCaptureEnabled: false,
        mode: ShowFileChooserRequestMode.OPEN_MULTIPLE,
      ),
    );
    expect(response?.handledByClient, isTrue);
    expect(response?.filePaths, ['file:///cache/beans.jpg']);
    expect(selection?.method, 'image');
    expect(selection?.arguments['allowMultipleSelection'], isTrue);
  });

  for (final width in [320.0, 800.0]) {
    testWidgets('camera consent dialog fits width $width with large text', (
      tester,
    ) async {
      await tester.binding.setSurfaceSize(Size(width, 600));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final boundary = GlobalKey();
      late BuildContext context;
      await tester.pumpWidget(
        RepaintBoundary(
          key: boundary,
          child: ShadApp(
            theme: buildDecentTheme(),
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(
                context,
              ).copyWith(textScaler: const TextScaler.linear(2)),
              child: child!,
            ),
            home: Builder(
              builder: (value) {
                context = value;
                return const Scaffold();
              },
            ),
          ),
        ),
      );
      final response = promptForSkinCamera(context, 'Coffee Bean Scanner');
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      final output = Platform.environment['DECAID_UI_EVIDENCE'];
      if (output != null) {
        await tester.runAsync(() async {
          final image =
              await (boundary.currentContext!.findRenderObject()
                      as RenderRepaintBoundary)
                  .toImage();
          final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
          await File(
            '$output/camera-dialog-$width.png',
          ).writeAsBytes(bytes!.buffer.asUint8List());
          image.dispose();
        });
      }
      await tester.tap(find.text('Deny'));
      await tester.pumpAndSettle();
      expect(await response, isFalse);
    });
  }

  testWidgets('native consent precedes system permission', (tester) async {
    late BuildContext context;
    var osRequests = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (value) {
            context = value;
            return const Scaffold();
          },
        ),
      ),
    );
    final access = SkinCameraWebViewAccess(
      context: () => context,
      currentTarget: () => target,
      requestSystemCamera: () async {
        osRequests++;
        return true;
      },
    );
    addTearDown(access.dispose);
    final result = access.onPermissionRequest(controller, request);
    await tester.pumpAndSettle();
    expect(
      find.text('Allow "First" to receive images from your camera?'),
      findsOneWidget,
    );
    expect(osRequests, 0);
    await tester.tap(find.text('Allow'));
    await tester.pumpAndSettle();
    expect((await result).action, PermissionResponseAction.GRANT);
    expect(osRequests, 1);
  });

  for (final outcome in [
    'cancel',
    'error',
    'navigation',
    'dispose',
    'background',
  ]) {
    testWidgets(
      'file chooser handles $outcome without native capture fallback',
      (tester) async {
        const channel = MethodChannel('miguelruivo.flutter.plugins.filepicker');
        final selected = Completer<List<Map<String, Object>>?>();
        tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          channel,
          (_) => selected.future,
        );
        addTearDown(
          () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
            channel,
            null,
          ),
        );
        final access = SkinCameraWebViewAccess(
          context: () => null,
          currentTarget: () => target,
        );
        addTearDown(access.dispose);
        final chooser = ShowFileChooserRequest(
          acceptTypes: ['image/*'],
          isCaptureEnabled: false,
          mode: ShowFileChooserRequestMode.OPEN,
        );
        final response = access.onShowFileChooser(controller, chooser);
        await tester.pump();
        expect(
          (await access.onShowFileChooser(
            controller,
            chooser,
          ))?.handledByClient,
          isTrue,
        );
        switch (outcome) {
          case 'navigation':
            access.invalidate();
          case 'dispose':
            access.dispose();
          case 'background':
            access.didChangeAppLifecycleState(AppLifecycleState.paused);
        }
        if (outcome == 'error') {
          selected.completeError(PlatformException(code: 'unavailable'));
        } else {
          selected.complete(
            outcome == 'cancel'
                ? null
                : [
                    {
                      'name': 'beans.jpg',
                      'path': '/cache/beans.jpg',
                      'size': 10,
                    },
                  ],
          );
        }
        final result = await response;
        expect(result?.handledByClient, isTrue);
        expect(
          result?.filePaths,
          outcome == 'background' ? ['file:///cache/beans.jpg'] : isNull,
        );
      },
    );
  }

  testWidgets('timed-out consent denies without persisting', (tester) async {
    late BuildContext context;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (value) {
            context = value;
            return const Scaffold();
          },
        ),
      ),
    );
    final result = promptForSkinCamera(context, target.name);
    await tester.pumpAndSettle();
    await tester.pump(const Duration(seconds: 30));
    await tester.pumpAndSettle();
    expect(await result, isNull);
    expect(await store.read(target.id), isNull);
    expect(find.byType(AlertDialog), findsNothing);
  });

  for (final cancel in ['background', 'dispose', 'cancel']) {
    testWidgets('$cancel invalidates a pending system grant', (tester) async {
      late BuildContext context;
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (value) {
              context = value;
              return const Scaffold();
            },
          ),
        ),
      );
      await store.write(target.id, true);
      final osResult = Completer<bool>();
      final access = SkinCameraWebViewAccess(
        context: () => context,
        currentTarget: () => target,
        requestSystemCamera: () => osResult.future,
      );
      final result = access.onPermissionRequest(controller, request);
      await tester.pumpAndSettle();
      switch (cancel) {
        case 'background':
          access.didChangeAppLifecycleState(AppLifecycleState.paused);
        case 'dispose':
          access.dispose();
        case 'cancel':
          access.onPermissionRequestCanceled(controller, request);
      }
      osResult.complete(true);
      await tester.pumpAndSettle();
      expect((await result).action, PermissionResponseAction.DENY);
      access.dispose();
    });
  }

  testWidgets(
    'explicit image capture confirms and gallery uses system picker',
    (tester) async {
      late BuildContext context;
      var osRequests = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (value) {
              context = value;
              return const Scaffold();
            },
          ),
        ),
      );
      await store.write(target.id, true);
      final access = SkinCameraWebViewAccess(
        context: () => context,
        currentTarget: () => target,
        requestSystemCamera: () async {
          osRequests++;
          return true;
        },
      );
      addTearDown(access.dispose);
      ShowFileChooserRequest chooser(bool capture, List<String> types) =>
          ShowFileChooserRequest(
            acceptTypes: types,
            isCaptureEnabled: capture,
            mode: ShowFileChooserRequestMode.OPEN,
          );
      const channel = MethodChannel('miguelruivo.flutter.plugins.filepicker');
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        channel,
        (_) async => null,
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          channel,
          null,
        ),
      );
      expect(
        (await access.onShowFileChooser(
          controller,
          chooser(false, ['image/*']),
        ))?.handledByClient,
        isTrue,
      );
      expect(osRequests, 0);
      expect(
        (await access.onShowFileChooser(
          controller,
          chooser(true, ['video/*']),
        ))?.handledByClient,
        isTrue,
      );
      final denied = access.onShowFileChooser(
        controller,
        chooser(true, ['image/*']),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Deny'));
      await tester.pumpAndSettle();
      expect((await denied)?.handledByClient, isTrue);
      expect(osRequests, 0);
      final allowed = access.onShowFileChooser(
        controller,
        chooser(true, ['image/jpeg']),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Allow'));
      await tester.pumpAndSettle();
      expect(await allowed, isNull);
      expect(osRequests, 1);
    },
  );

  for (final (types, liveConsent) in [
    (['image/jpeg'], false),
    (['.jpg'], true),
    (['image/jpeg', '.jpg'], true),
    ([' .JPG ', 'IMAGE/PNG'], true),
  ]) {
    testWidgets(
      'image capture accepts $types with live-camera consent $liveConsent',
      (tester) async {
        late BuildContext context;
        var osRequests = 0;
        await tester.pumpWidget(
          MaterialApp(
            home: Builder(
              builder: (value) {
                context = value;
                return const Scaffold();
              },
            ),
          ),
        );
        await store.write(target.id, liveConsent);
        final access = SkinCameraWebViewAccess(
          context: () => context,
          currentTarget: () => target,
          requestSystemCamera: () async {
            osRequests++;
            return true;
          },
        );
        addTearDown(access.dispose);
        final result = access.onShowFileChooser(
          controller,
          ShowFileChooserRequest(
            acceptTypes: types,
            isCaptureEnabled: true,
            mode: ShowFileChooserRequestMode.OPEN,
          ),
        );
        await tester.pumpAndSettle();
        expect(find.byType(AlertDialog), findsOneWidget);
        expect(osRequests, 0);
        await tester.tap(find.text('Allow'));
        await tester.pumpAndSettle();
        expect(await result, isNull);
        expect(osRequests, 1);
        expect(await store.read(target.id), liveConsent);
      },
    );
  }

  for (final types in [
    ['.mp4'],
    ['.unknown-image-extension'],
    ['image/jpeg', '.txt'],
    ['.jpg', '.mp4'],
    <String>[],
  ]) {
    testWidgets(
      'capture denies non-image specifiers $types without prompting',
      (tester) async {
        var contextReads = 0;
        final access = SkinCameraWebViewAccess(
          context: () {
            contextReads++;
            return null;
          },
          currentTarget: () => target,
          requestSystemCamera: () async =>
              throw StateError('Unexpected camera'),
        );
        addTearDown(access.dispose);
        final result = await access.onShowFileChooser(
          controller,
          ShowFileChooserRequest(
            acceptTypes: types,
            isCaptureEnabled: true,
            mode: ShowFileChooserRequestMode.OPEN,
          ),
        );
        expect(result?.handledByClient, isTrue);
        expect(result?.filePaths, isNull);
        expect(contextReads, 0);
        expect(find.byType(AlertDialog), findsNothing);
      },
    );
  }

  testWidgets('ordinary image extension selection keeps its exact filter', (
    tester,
  ) async {
    const channel = MethodChannel('miguelruivo.flutter.plugins.filepicker');
    MethodCall? selection;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
      call,
    ) async {
      selection = call;
      return null;
    });
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        channel,
        null,
      ),
    );
    final access = SkinCameraWebViewAccess(
      context: () => null,
      currentTarget: () => target,
      requestSystemCamera: () async => throw StateError('Unexpected camera'),
    );
    addTearDown(access.dispose);
    final response = await access.onShowFileChooser(
      controller,
      ShowFileChooserRequest(
        acceptTypes: ['.jpg'],
        isCaptureEnabled: false,
        mode: ShowFileChooserRequestMode.OPEN,
      ),
    );
    expect(response?.handledByClient, isTrue);
    expect(selection?.method, 'custom');
    expect(selection?.arguments['allowedExtensions'], ['jpg']);
  });

  testWidgets('native setting can revoke and reset per skin', (tester) async {
    await store.write(target.id, true);
    await store.write('other', true);
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(body: SkinCameraConsentSetting(skinId: 'first')),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byType(DropdownButton<String>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Deny').last);
    await tester.pumpAndSettle();
    expect(await store.read(target.id), isFalse);
    expect(await store.read('other'), isTrue);
    await tester.tap(find.byType(DropdownButton<String>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Ask').last);
    await tester.pumpAndSettle();
    expect(await store.read(target.id), isNull);
  });

  testWidgets('corrupt consent displays an error and disables changes', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({
      'skinCameraConsent.first': 'invalid',
    });
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(body: SkinCameraConsentSetting(skinId: 'first')),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Camera permission could not be loaded.'), findsOneWidget);
    expect(
      tester
          .widget<DropdownButton<String>>(find.byType(DropdownButton<String>))
          .onChanged,
      isNull,
    );
  });
}
