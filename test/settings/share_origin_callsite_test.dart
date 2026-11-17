import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';
import 'package:reaprime/src/controllers/de1_controller.dart';
import 'package:reaprime/src/controllers/device_controller.dart';
import 'package:reaprime/src/controllers/persistence_controller.dart';
import 'package:reaprime/src/database_failure_view.dart';
import 'package:reaprime/src/import/import_result.dart';
import 'package:reaprime/src/import/widgets/import_result_view.dart';
import 'package:reaprime/src/services/export/support_package.dart';
import 'package:reaprime/src/services/storage/database_recovery.dart';
import 'package:reaprime/src/services/storage/storage_service.dart';
import 'package:reaprime/src/settings/data_management_page.dart';
import 'package:reaprime/src/settings/settings_controller.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

import '../helpers/mock_settings_service.dart';

class _Storage extends Fake implements StorageService {}

class _Paths extends PathProviderPlatform with MockPlatformInterfaceMixin {
  _Paths(this.path, [this.preparation]);
  final String path;
  final _Preparation? preparation;
  @override
  Future<String?> getTemporaryPath() async {
    preparation?.started.complete();
    if (preparation != null) await preparation!.resume.future;
    return path;
  }

  @override
  Future<String?> getApplicationDocumentsPath() async => path;
}

class _Headers extends Fake implements HttpHeaders {
  @override
  ContentType? get contentType => ContentType('application', 'zip');
}

class _Response extends Stream<List<int>> implements HttpClientResponse {
  @override
  int get statusCode => 200;
  @override
  HttpHeaders get headers => _Headers();
  @override
  StreamSubscription<List<int>> listen(
    void Function(List<int>)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) => Stream.value([1, 2, 3]).listen(
    onData,
    onError: onError,
    onDone: onDone,
    cancelOnError: cancelOnError,
  );
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Preparation {
  final started = Completer<void>.sync();
  final resume = Completer<void>.sync();
}

class _Request extends Fake implements HttpClientRequest {
  _Request(this.preparation);
  final _Preparation? preparation;

  @override
  Future<HttpClientResponse> close() async {
    preparation?.started.complete();
    if (preparation != null) await preparation!.resume.future;
    return _Response();
  }
}

class _Client extends Fake implements HttpClient {
  _Client(this.preparation);
  final _Preparation? preparation;
  @override
  Future<HttpClientRequest> getUrl(Uri url) async {
    expect(url.path, '/api/v1/data/export');
    return _Request(preparation);
  }

  @override
  void close({bool force = false}) {}
}

class _Http extends HttpOverrides {
  _Http([this.preparation]);
  final _Preparation? preparation;

  @override
  HttpClient createHttpClient(SecurityContext? context) => _Client(preparation);
}

void main() {
  const channel = MethodChannel('dev.fluttercommunity.plus/share');
  late Directory temp;
  late Completer<Map<dynamic, dynamic>> shared;
  late PathProviderPlatform originalPaths;

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('share-callsite-');
    originalPaths = PathProviderPlatform.instance;
    PathProviderPlatform.instance = _Paths(temp.path);
    shared = Completer();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          expect(call.method, 'share');
          shared.complete(call.arguments as Map);
          return '';
        });
  });
  tearDown(() async {
    PathProviderPlatform.instance = originalPaths;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
    await temp.delete(recursive: true);
  });

  Future<void> assertShare(WidgetTester tester, String label) async {
    final button = find.ancestor(
      of: find.text(label),
      matching: find.byType(ShadButton),
    );
    await tester.ensureVisible(button);
    await tester.pumpAndSettle();
    final expected = tester.getRect(button);
    expect(expected.isEmpty, isFalse);
    final args = await tester.runAsync(() async {
      await tester.tap(button);
      return shared.future.timeout(const Duration(seconds: 10));
    });
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(args!['originX'], expected.left);
    expect(args['originY'], expected.top);
    expect(args['originWidth'], expected.width);
    expect(args['originHeight'], expected.height);
  }

  testWidgets(
    'Export Full Backup propagates its button bounds to sharing',
    (tester) async {
      tester.view.physicalSize = const Size(1180, 820);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final storage = _Storage();
      await tester.pumpWidget(
        ShadApp(
          home: DataManagementPage(
            controller: SettingsController(MockSettingsService()),
            persistenceController: PersistenceController(
              storageService: storage,
            ),
            de1Controller: De1Controller(
              controller: DeviceController(const []),
            ),
            decentAccountService: null,
          ),
        ),
      );
      await HttpOverrides.runZoned(
        () => assertShare(tester, 'Export Full Backup'),
        createHttpClient: _Http().createHttpClient,
      );
      expect(find.text('Full backup exported successfully'), findsNothing);
      expect(find.text('Preparing full backup...'), findsNothing);
    },
    variant: TargetPlatformVariant({
      TargetPlatform.iOS,
      TargetPlatform.android,
    }),
  );

  testWidgets(
    'Export Full Backup shares post-resize bounds after preparation',
    (tester) async {
      tester.view.physicalSize = const Size(1180, 820);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        ShadApp(
          home: DataManagementPage(
            controller: SettingsController(MockSettingsService()),
            persistenceController: PersistenceController(
              storageService: _Storage(),
            ),
            de1Controller: De1Controller(
              controller: DeviceController(const []),
            ),
            decentAccountService: null,
          ),
        ),
      );
      final button = find.ancestor(
        of: find.text('Export Full Backup'),
        matching: find.byType(ShadButton),
      );
      await tester.ensureVisible(button);
      await tester.pumpAndSettle();
      final tapBounds = tester.getRect(button);
      final preparation = _Preparation();
      await HttpOverrides.runZoned(() async {
        await tester.runAsync(() async {
          await tester.tap(button);
          await preparation.started.future.timeout(const Duration(seconds: 10));
        });
        tester.view.physicalSize = const Size(500, 820);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));
        final shareBounds = tester.getRect(button);
        expect(shareBounds, isNot(tapBounds));
        final args = await tester.runAsync(() async {
          preparation.resume.complete();
          return shared.future.timeout(const Duration(seconds: 10));
        });
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        expect(args!['originX'], shareBounds.left);
        expect(args['originY'], shareBounds.top);
        expect(args['originWidth'], shareBounds.width);
        expect(args['originHeight'], shareBounds.height);
      }, createHttpClient: _Http(preparation).createHttpClient);
      expect(find.text('Preparing full backup...'), findsNothing);
    },
    variant: TargetPlatformVariant({
      TargetPlatform.iOS,
      TargetPlatform.android,
    }),
  );

  testWidgets(
    'Export Full Backup handles an action offscreen after window shrink',
    (tester) async {
      tester.view.physicalSize = const Size(1180, 820);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        ShadApp(
          home: ScaffoldMessenger(
            child: DataManagementPage(
              controller: SettingsController(MockSettingsService()),
              persistenceController: PersistenceController(
                storageService: _Storage(),
              ),
              de1Controller: De1Controller(
                controller: DeviceController(const []),
              ),
              decentAccountService: null,
            ),
          ),
        ),
      );
      final button = find.ancestor(
        of: find.text('Export Full Backup'),
        matching: find.byType(ShadButton),
      );
      final preparation = _Preparation();
      await HttpOverrides.runZoned(() async {
        late Future<void> pending;
        await tester.runAsync(() async {
          pending = (tester.widget<ShadButton>(button).onPressed as dynamic)();
          await preparation.started.future.timeout(const Duration(seconds: 10));
        });
        tester.view.physicalSize = const Size(1180, 100);
        await tester.pump();
        expect(tester.getRect(button).top, greaterThan(100));
        await tester.runAsync(() async {
          preparation.resume.complete();
          await pending.timeout(const Duration(seconds: 10));
        });
        await tester.pumpAndSettle();
      }, createHttpClient: _Http(preparation).createHttpClient);
      expect(tester.takeException(), isNull);
      expect(shared.isCompleted, isFalse);
      expect(find.text('Preparing full backup...'), findsNothing);
      expect(
        find.textContaining('Failed to export full backup:'),
        findsOneWidget,
      );
      expect(
        find.textContaining('must be visible within the view'),
        findsOneWidget,
      );
    },
    variant: TargetPlatformVariant({
      TargetPlatform.iOS,
      TargetPlatform.android,
    }),
  );

  testWidgets(
    'recovery package propagates button bounds through saveSupportPackage',
    (tester) async {
      await tester.pumpWidget(
        DatabaseFailureApp(
          logFilePath: '${temp.path}/log.txt',
          onSavePackage: (origin) =>
              saveSupportPackage(sharePositionOrigin: origin),
          onResetDatabase: () async => const ResetReport(),
        ),
      );
      await assertShare(tester, 'Save recovery package');
      expect(find.text('Recovery package saved.'), findsNothing);
    },
    variant: TargetPlatformVariant({
      TargetPlatform.iOS,
      TargetPlatform.android,
    }),
  );

  for (final change in ['resize', 'hide', 'unmount']) {
    testWidgets(
      'Share Report handles $change during preparation',
      (tester) async {
        tester.view.physicalSize = const Size(1180, 820);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final preparation = _Preparation();
        PathProviderPlatform.instance = _Paths(temp.path, preparation);
        await tester.pumpWidget(
          ShadApp(
            home: ScaffoldMessenger(
              child: Scaffold(
                body: ImportResultView(
                  result: const ImportResult(
                    errors: [
                      ImportError(filename: 'shot.json', reason: 'invalid'),
                    ],
                  ),
                  onContinue: () {},
                ),
              ),
            ),
          ),
        );
        await tester.tap(find.text('Show details'));
        await tester.pumpAndSettle();
        final button = find.ancestor(
          of: find.text('Share Report'),
          matching: find.byType(ShadButton),
        );
        final tapBounds = tester.getRect(button);
        late Future<void> pending;
        await tester.runAsync(() async {
          pending = (tester.widget<ShadButton>(button).onPressed as dynamic)();
          await preparation.started.future.timeout(const Duration(seconds: 10));
        });
        Rect? shareBounds;
        if (change == 'resize') {
          tester.view.physicalSize = const Size(500, 820);
          await tester.pumpAndSettle();
          shareBounds = tester.getRect(button);
          expect(shareBounds, isNot(tapBounds));
        } else if (change == 'hide') {
          await tester.tap(find.text('Hide details'));
          await tester.pumpAndSettle();
          expect(button, findsNothing);
        } else {
          await tester.pumpWidget(const SizedBox.shrink());
        }
        await tester.runAsync(() async {
          preparation.resume.complete();
          await pending.timeout(const Duration(seconds: 10));
        });
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        if (change == 'resize') {
          final args = await tester.runAsync(
            () => shared.future.timeout(const Duration(seconds: 10)),
          );
          expect(args!['originX'], shareBounds!.left);
          expect(args['originY'], shareBounds.top);
          expect(args['originWidth'], shareBounds.width);
          expect(args['originHeight'], shareBounds.height);
        } else {
          expect(shared.isCompleted, isFalse);
          if (change == 'hide') {
            expect(
              find.textContaining('Failed to share report:'),
              findsOneWidget,
            );
            expect(
              find.textContaining('must still be mounted'),
              findsOneWidget,
            );
          }
        }
      },
      variant: TargetPlatformVariant({
        TargetPlatform.iOS,
        TargetPlatform.android,
      }),
    );
  }

  for (final change in ['resize', 'offscreen', 'unmount']) {
    testWidgets(
      'recovery package handles $change during preparation',
      (tester) async {
        tester.view.physicalSize = const Size(1180, 820);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final preparation = _Preparation();
        await tester.pumpWidget(
          DatabaseFailureApp(
            logFilePath: '${temp.path}/log.txt',
            onSavePackage: (origin) async {
              preparation.started.complete();
              await preparation.resume.future;
              return saveSupportPackage(sharePositionOrigin: origin);
            },
            onResetDatabase: () async => const ResetReport(),
          ),
        );
        final button = find.ancestor(
          of: find.text('Save recovery package'),
          matching: find.byType(ShadButton),
        );
        await tester.ensureVisible(button);
        await tester.pumpAndSettle();
        final tapBounds = tester.getRect(button);
        late Future<void> pending;
        await tester.runAsync(() async {
          pending = (tester.widget<ShadButton>(button).onPressed as dynamic)();
          await preparation.started.future.timeout(const Duration(seconds: 10));
        });
        Rect? shareBounds;
        if (change == 'resize') {
          tester.view.physicalSize = const Size(500, 820);
          await tester.pumpAndSettle();
          shareBounds = tester.getRect(button);
          expect(shareBounds, isNot(tapBounds));
        } else if (change == 'offscreen') {
          tester.view.physicalSize = const Size(1180, 100);
          await tester.pumpAndSettle();
          expect(tester.getRect(button).top, greaterThan(100));
        } else {
          await tester.pumpWidget(const SizedBox.shrink());
        }
        await tester.runAsync(() async {
          preparation.resume.complete();
          await pending.timeout(const Duration(seconds: 10));
        });
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        if (change == 'resize') {
          final args = await tester.runAsync(
            () => shared.future.timeout(const Duration(seconds: 10)),
          );
          expect(args!['originX'], shareBounds!.left);
          expect(args['originY'], shareBounds.top);
          expect(args['originWidth'], shareBounds.width);
          expect(args['originHeight'], shareBounds.height);
        } else {
          expect(shared.isCompleted, isFalse);
          if (change == 'offscreen') {
            expect(
              find.textContaining('Could not save the recovery package:'),
              findsOneWidget,
            );
            expect(
              find.textContaining('must be visible within the view'),
              findsOneWidget,
            );
            expect(tester.widget<ShadButton>(button).enabled, isTrue);
          }
        }
      },
      variant: TargetPlatformVariant({
        TargetPlatform.iOS,
        TargetPlatform.android,
      }),
    );
  }

  testWidgets(
    'Share Report propagates its button bounds and preserves report logs',
    (tester) async {
      File('${temp.path}/log.txt').writeAsStringSync('example log');
      await tester.pumpWidget(
        ShadApp(
          home: Scaffold(
            body: ImportResultView(
              result: const ImportResult(
                shotsImported: 2,
                errors: [
                  ImportError(filename: 'shot.json', reason: 'invalid shot'),
                ],
              ),
              onContinue: () {},
            ),
          ),
        ),
      );
      await tester.tap(find.text('Show details'));
      await tester.pumpAndSettle();
      await assertShare(tester, 'Share Report');
      final report = File('${temp.path}/import_report.txt').readAsStringSync();
      expect(report, contains('Shots imported:    2'));
      expect(report, contains('shot.json: invalid shot'));
      expect(report, contains('--- App Logs ---\nexample log'));
    },
    variant: TargetPlatformVariant({
      TargetPlatform.iOS,
      TargetPlatform.android,
    }),
  );
}
