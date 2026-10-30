import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:reaprime/src/plugins/plugin_loader_service.dart';
import 'package:reaprime/src/plugins/plugin_package.dart';
import 'package:reaprime/src/util/remote_error.dart';
import 'package:reaprime/src/util/remote_update_exception.dart';

void main() {
  for (final error in <Object>[
    const SocketException('Failed host lookup: private.example'),
    http.ClientException('Connection closed: https://private.example'),
    const HttpException('Connection closed before full header'),
  ]) {
    test('describes ${error.runtimeType} without transport details', () {
      expect(
        remoteErrorMessage(error, action: 'install the skin'),
        "Couldn't install the skin. Check your internet connection and try again.",
      );
    });
  }

  test('gives timeout and certificate failures different guidance', () {
    expect(
      remoteErrorMessage(
        TimeoutException('private'),
        action: 'download the update',
      ),
      "Couldn't download the update. The connection took too long. Try again.",
    );
    expect(
      remoteErrorMessage(
        const HandshakeException('private'),
        action: 'install the plugin',
      ),
      "Couldn't install the plugin. A secure connection could not be established. Try again later.",
    );
  });

  test('preserves validation without calling it a connection problem', () {
    expect(
      remoteErrorMessage(
        PluginPackageException('No ZIP file in this release'),
        action: 'install the skin',
      ),
      "Couldn't install the skin. No ZIP file in this release",
    );
    expect(
      remoteErrorMessage(
        const FileSystemException('denied', '/private/path'),
        action: 'install the plugin',
      ),
      "Couldn't install the plugin. Check storage space and file permissions, then try again.",
    );
    expect(
      remoteErrorMessage(
        StateError('private implementation detail'),
        action: 'send feedback',
      ),
      "Couldn't send feedback. Try again.",
    );
  });

  test('does not expose parser diagnostics as validation guidance', () {
    const error = FormatException(
      'Invalid input at https://private.example/internal',
      '{ broken source',
      2,
    );
    expect(
      remoteErrorMessage(error, action: 'install the plugin'),
      "Couldn't install the plugin. The downloaded data or package is invalid. Check the source and try again.",
    );
  });

  test('preserves downgrade guidance for installs and batch failures', () {
    final error = PluginDowngradeException(
      'Plugin test 2.0.0 is installed; remove it before installing 1.0.0',
    );
    for (final failure in <Object>[
      error,
      RemoteUpdateException(
        attemptedCount: 1,
        failures: [(item: 'test', error: error)],
      ),
    ]) {
      expect(
        remoteErrorMessage(failure, action: 'install the plugin'),
        "Couldn't install the plugin. ${error.message}",
      );
    }
  });

  test('HTTP failures are not reported as offline', () {
    for (final status in [401, 403, 404, 429, 500]) {
      final message = remoteErrorMessage(
        remoteHttpError(status),
        action: 'install the plugin',
      );
      expect(message, isNot(contains('internet')));
      expect(message, isNot(contains('$status')));
    }
  });

  test('batch failures preserve immutable diagnostic information', () {
    final source = <({String item, Object error})>[
      (item: 'skin', error: const SocketException('private')),
    ];
    final error = RemoteUpdateException(attemptedCount: 2, failures: source);
    source.clear();
    expect(error.failures, hasLength(1));
    expect(() => error.failures.clear(), throwsUnsupportedError);
    expect(
      remoteErrorMessage(error, action: 'check for skin updates'),
      "Some updates couldn't be completed. Check your internet connection and try again.",
    );
  });
}
