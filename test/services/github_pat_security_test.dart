import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:logging/logging.dart';
import 'package:reaprime/src/models/feedback/feedback_request.dart';
import 'package:reaprime/src/services/account/decent_account_service.dart';
import 'package:reaprime/src/services/feedback_service.dart';
import 'package:reaprime/src/services/github_credentials.dart';
import 'package:reaprime/src/services/webserver/data_export_handler.dart';
import 'package:reaprime/src/services/webserver/data_export/settings_export_section.dart';
import 'package:reaprime/src/services/webserver_service.dart';
import 'package:reaprime/src/settings/settings_controller.dart';
import 'package:reaprime/src/webui_support/webui_service.dart';
import 'package:reaprime/src/webui_support/webui_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shelf_plus/shelf_plus.dart';

import '../helpers/mock_settings_service.dart';

class _Store implements CredentialStore {
  _Store(this.value);

  String? value;

  @override
  Future<String?> read({required String key}) async => value;

  @override
  Future<void> write({required String key, required String value}) async {
    this.value = value;
  }

  @override
  Future<void> delete({required String key}) async {
    value = null;
  }
}

class _Account extends Fake implements DecentAccountService {
  @override
  Future<DecentAccountStatus> verifyStoredCredentialsStatus() async =>
      DecentAccountStatus.authenticated;
}

class _WebUI extends Fake implements WebUIService {
  @override
  String serverPath() => '/';
}

class _WebUIStorage extends Fake implements WebUIStorage {}

void main() {
  test(
    'PAT stays out of settings endpoint, SharedPreferences, and backup',
    () async {
      const pat = 'security-test-pat-123';
      SharedPreferences.setMockInitialValues({});
      final preferences = await SharedPreferences.getInstance();
      final credentials = GithubCredentialProvider(store: _Store(null));
      await credentials.save(pat);

      expect(preferences.getKeys(), isEmpty);

      final settings = SettingsController(MockSettingsService());
      await settings.loadSettings();
      final router = Router().plus;
      SettingsHandler(
        controller: settings,
        service: _WebUI(),
        webUIStorage: _WebUIStorage(),
      ).addRoutes(router);
      final response = await router.call(
        Request('GET', Uri.parse('http://localhost/api/v1/settings')),
      );
      final settingsBody = await response.readAsString();
      expect(settingsBody, isNot(contains(pat)));

      final tempDir = await Directory.systemTemp.createTemp('pat-security-');
      addTearDown(() => tempDir.delete(recursive: true));
      final export = DataExportHandler(
        sections: [SettingsExportSection(controller: settings)],
      );
      final zip = await export.exportToZipFile(tempDir);
      final archive = ZipDecoder().decodeBytes(await zip.readAsBytes());
      final settingsEntry = archive.findFile('settings.json');
      expect(settingsEntry, isNotNull);
      expect(
        utf8.decode(settingsEntry!.content as List<int>),
        isNot(contains(pat)),
      );
    },
  );

  test(
    'PAT is absent from generated HTML and rejected-transport logs',
    () async {
      const pat = 'security-test-pat-456';
      final credentials = GithubCredentialProvider(store: _Store(pat));
      await credentials.load();
      final service = FeedbackService(
        githubToken: 'bundled-pat',
        credentials: credentials,
        currentSerialNumbers: () => const [],
        installedComponents: () => ['component $pat'],
        accountService: _Account(),
        httpClient: MockClient(
          (_) async => http.Response('malicious response $pat', 401),
        ),
      );

      final report = await service.generateHtmlReport(
        FeedbackRequest(
          description: 'report $pat',
          type: FeedbackType.bug,
          includeLogs: false,
          includeSystemInfo: true,
        ),
      );
      expect(report, isNot(contains(pat)));

      final records = <LogRecord>[];
      final subscription = Logger.root.onRecord.listen(records.add);
      addTearDown(subscription.cancel);
      final result = await service.submitFeedback(
        FeedbackRequest(
          description: 'submit $pat',
          type: FeedbackType.bug,
          includeLogs: false,
          includeSystemInfo: false,
        ),
      );
      expect(result.success, isFalse);
      expect(result.errorMessage, isNot(contains(pat)));
      expect(
        records.map((record) => '${record.message} ${record.error}'),
        everyElement(isNot(contains(pat))),
      );
    },
  );
}
