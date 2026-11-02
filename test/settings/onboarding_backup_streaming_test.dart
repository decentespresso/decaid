import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/controllers/persistence_controller.dart';
import 'package:reaprime/src/import/widgets/import_result_view.dart';
import 'package:reaprime/src/import/widgets/import_source_picker.dart';
import 'package:reaprime/src/onboarding_feature/onboarding_controller.dart';
import 'package:reaprime/src/onboarding_feature/steps/import_step.dart';
import 'package:reaprime/src/services/storage/bean_storage_service.dart';
import 'package:reaprime/src/services/storage/grinder_storage_service.dart';
import 'package:reaprime/src/services/storage/profile_storage_service.dart';
import 'package:reaprime/src/services/storage/storage_service.dart';
import 'package:reaprime/src/settings/settings_controller.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

import '../helpers/mock_settings_service.dart';

class _Storage extends Fake implements StorageService {}

class _Profiles extends Fake implements ProfileStorageService {}

class _Beans extends Fake implements BeanStorageService {}

class _Grinders extends Fake implements GrinderStorageService {}

class _FileWithoutReadAsBytes extends Fake implements File {
  final List<int> contents;
  int readAsBytesCalls = 0;

  _FileWithoutReadAsBytes(this.contents);

  @override
  Future<int> length() async => contents.length;

  @override
  Future<Uint8List> readAsBytes() async {
    readAsBytesCalls++;
    throw StateError('The onboarding backup must not be buffered.');
  }

  @override
  Stream<List<int>> openRead([int? start, int? end]) => Stream.fromIterable([
    Uint8List.fromList(contents.take(contents.length ~/ 2).toList()),
    Uint8List.fromList(contents.skip(contents.length ~/ 2).toList()),
  ]);
}

class _Headers extends Fake implements HttpHeaders {
  ContentType? _contentType;

  @override
  ContentType? get contentType => _contentType;

  @override
  set contentType(ContentType? value) => _contentType = value;
}

class _Response extends Fake implements HttpClientResponse {
  final int responseStatusCode;
  final String responseBody;

  _Response(this.responseStatusCode, this.responseBody);

  @override
  int get statusCode => responseStatusCode;

  @override
  StreamSubscription<List<int>> listen(
    void Function(List<int>)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) => Stream<List<int>>.value(Uint8List.fromList(utf8.encode(responseBody)))
      .listen(
        onData,
        onError: onError,
        onDone: onDone,
        cancelOnError: cancelOnError,
      );
}

class _Request extends Fake implements HttpClientRequest {
  final _Headers requestHeaders = _Headers();
  final _Response response;
  List<int> body = [];
  bool closed = false;

  _Request(this.response);

  @override
  HttpHeaders get headers => requestHeaders;

  @override
  int contentLength = -1;

  @override
  Future<void> addStream(Stream<List<int>> stream) async {
    final received = <int>[];
    await for (final chunk in stream) {
      received.addAll(chunk);
    }
    body = received;
  }

  @override
  Future<HttpClientResponse> close() async {
    closed = true;
    return response;
  }
}

class _Client extends Fake implements HttpClient {
  final Uri expectedUri;
  final _Request request;
  bool closed = false;

  _Client({
    required this.expectedUri,
    required int statusCode,
    required String responseBody,
  }) : request = _Request(_Response(statusCode, responseBody));

  @override
  Future<HttpClientRequest> postUrl(Uri url) async {
    expect(url, expectedUri);
    return request;
  }

  @override
  void close({bool force = false}) => closed = true;
}

Future<void> _selectZip(
  WidgetTester tester,
  OnboardingController onboarding,
) async {
  tester
      .widget<ImportSourcePicker>(find.byType(ImportSourcePicker))
      .onZipFileSelected('backup.zip');
  await tester.pumpAndSettle();
  addTearDown(onboarding.dispose);
}

void main() {
  testWidgets('onboarding streams the selected ZIP on the default path', (
    tester,
  ) async {
    final file = _FileWithoutReadAsBytes([0, 1, 2, 3]);
    final client = _Client(
      expectedUri: Uri.parse(
        'http://localhost:8080/api/v1/data/import?onConflict=skip',
      ),
      statusCode: 200,
      responseBody: '{"profiles":{"imported":1}}',
    );
    final step = createImportStep(
      profileStorageService: _Profiles(),
      beanStorageService: _Beans(),
      grinderStorageService: _Grinders(),
      settingsController: SettingsController(MockSettingsService()),
      persistenceController: PersistenceController(storageService: _Storage()),
    );
    final onboarding = OnboardingController(steps: [step]);
    await IOOverrides.runZoned(() async {
      await HttpOverrides.runZoned(() async {
        await tester.pumpWidget(
          ShadApp(home: ScaffoldMessenger(child: step.builder(onboarding))),
        );
        await _selectZip(tester, onboarding);
      }, createHttpClient: (_) => client);
    }, createFile: (_) => file);

    expect(file.readAsBytesCalls, 0);
    expect(client.request.body, [0, 1, 2, 3]);
    expect(client.request.contentLength, 4);
    expect(
      client.request.requestHeaders.contentType?.mimeType,
      'application/zip',
    );
    expect(find.byType(ImportResultView), findsOneWidget);
    expect(find.text('1 profile imported'), findsOneWidget);
    expect(client.request.closed, isTrue);
    expect(client.closed, isTrue);
  });

  for (final reason in ['invalid_zip', 'too_many_entries']) {
    testWidgets(
      'onboarding preserves $reason import result on the default path',
      (tester) async {
        final file = _FileWithoutReadAsBytes([4, 5]);
        final client = _Client(
          expectedUri: Uri.parse(
            'http://localhost:8080/api/v1/data/import?onConflict=skip',
          ),
          statusCode: 400,
          responseBody: '{"message":"Invalid backup","reason":"$reason"}',
        );
        final step = createImportStep(
          profileStorageService: _Profiles(),
          beanStorageService: _Beans(),
          grinderStorageService: _Grinders(),
          settingsController: SettingsController(MockSettingsService()),
          persistenceController: PersistenceController(
            storageService: _Storage(),
          ),
        );
        final onboarding = OnboardingController(steps: [step]);
        await IOOverrides.runZoned(() async {
          await HttpOverrides.runZoned(() async {
            await tester.pumpWidget(
              ShadApp(home: ScaffoldMessenger(child: step.builder(onboarding))),
            );
            await _selectZip(tester, onboarding);
          }, createHttpClient: (_) => client);
        }, createFile: (_) => file);

        expect(file.readAsBytesCalls, 0);
        expect(client.request.body, [4, 5]);
        expect(client.request.contentLength, 2);
        expect(
          client.request.requestHeaders.contentType?.mimeType,
          'application/zip',
        );
        final resultViewFinder = find.byType(ImportResultView);
        final resultView = tester.widget<ImportResultView>(resultViewFinder);
        final error = resultView.result.errors.single;
        if (reason == 'invalid_zip') {
          expect(error.reason, 'ZIP import failed');
          expect(error.details, contains('Invalid backup'));
          expect(find.byType(SnackBar), findsNothing);
          await tester.tap(
            find.descendant(
              of: resultViewFinder,
              matching: find.text('Show details'),
            ),
          );
          await tester.pump();
          expect(
            find.descendant(
              of: resultViewFinder,
              matching: find.text('ZIP import failed'),
            ),
            findsOneWidget,
          );
        } else {
          expect(error.reason, contains('If it is De1App data'));
          expect(error.reason, contains('extract the archive'));
          expect(error.reason, contains('select the de1plus folder'));
          expect(error.details, isNull);
          await tester.tap(
            find.descendant(
              of: resultViewFinder,
              matching: find.text('Show details'),
            ),
          );
          await tester.pump();
          expect(
            find.descendant(
              of: resultViewFinder,
              matching: find.textContaining('If it is De1App data'),
            ),
            findsOneWidget,
          );
          expect(
            find.descendant(
              of: resultViewFinder,
              matching: find.textContaining('select the de1plus folder'),
            ),
            findsOneWidget,
          );
          expect(find.byType(SnackBar), findsOneWidget);
          final snackBar = tester.widget<SnackBar>(find.byType(SnackBar));
          expect(snackBar.duration, const Duration(seconds: 12));
          expect(snackBar.content, isA<Text>());
          final snackBarText = snackBar.content as Text;
          expect(snackBarText.data, contains('If it is De1App data'));
          expect(snackBarText.data, contains('extract the archive'));
          expect(snackBarText.data, contains('select the de1plus folder'));
        }
        expect(client.request.closed, isTrue);
        expect(client.closed, isTrue);
      },
    );
  }
}
