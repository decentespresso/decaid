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
  _Paths(this.path);
  final String path;
  @override
  Future<String?> getTemporaryPath() async => path;
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

class _Request extends Fake implements HttpClientRequest {
  @override
  Future<HttpClientResponse> close() async => _Response();
}

class _Client extends Fake implements HttpClient {
  @override
  Future<HttpClientRequest> getUrl(Uri url) async {
    expect(url.path, '/api/v1/data/export');
    return _Request();
  }

  @override
  void close({bool force = false}) {}
}

class _Http extends HttpOverrides {
  @override
  HttpClient createHttpClient(SecurityContext? context) => _Client();
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
