import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:reaprime/src/settings/backup_import_response.dart';

class BackupTransferException implements Exception {
  final String message;
  final int? statusCode;

  const BackupTransferException(this.message, {this.statusCode});

  @override
  String toString() => 'BackupTransferException: $message';
}

class BackupTransferService {
  final HttpClient _client;
  final int maxResponseBytes;

  BackupTransferService({
    HttpClient? client,
    this.maxResponseBytes = 8 * 1024 * 1024,
  }) : _client = client ?? HttpClient();

  Future<File> downloadExportZip(String url, Directory tempDir) async {
    final request = await _client.getUrl(Uri.parse(url));
    final response = await request.close();

    if (response.statusCode != 200) {
      final message = await _readErrorBody(response);
      throw BackupTransferException(
        message ?? 'The server returned status ${response.statusCode}.',
        statusCode: response.statusCode,
      );
    }
    final mime = response.headers.contentType?.mimeType.toLowerCase();
    if (mime != 'application/zip') {
      throw const BackupTransferException(
        'The server returned an invalid backup archive.',
      );
    }

    final file = File('${tempDir.path}${Platform.pathSeparator}export.zip');
    final raf = await file.open(mode: FileMode.write);
    try {
      await for (final chunk in response) {
        raf.writeFromSync(chunk);
      }
    } finally {
      await raf.close();
    }
    return file;
  }

  Future<BackupImportResponse> uploadZip(
    String url,
    String onConflict, {
    String? filePath,
    Stream<List<int>>? readStream,
    int? contentLength,
  }) async {
    final uri = Uri.parse(url).replace(
      queryParameters: {
        ...Uri.parse(url).queryParameters,
        'onConflict': onConflict,
      },
    );
    final request = await _client.postUrl(uri);
    request.headers.contentType = ContentType('application', 'zip');

    final Stream<List<int>> body;
    if (filePath != null) {
      final file = File(filePath);
      request.contentLength = contentLength ?? await file.length();
      body = file.openRead();
    } else if (readStream != null) {
      body = readStream;
    } else {
      throw const BackupTransferException(
        'Could not access the selected file.',
      );
    }

    await request.addStream(body);
    final response = await request.close();
    final responseBody = await _readBounded(response);
    return BackupImportResponse.fromHttp(response.statusCode, responseBody);
  }

  Future<String?> _readErrorBody(HttpClientResponse response) async {
    try {
      final bytes = await _readBounded(response);
      final decoded = jsonDecode(bytes);
      final message = decoded is Map ? decoded['message'] : null;
      return message is String && message.isNotEmpty ? message : null;
    } catch (_) {
      return null;
    }
  }

  Future<String> _readBounded(HttpClientResponse response) async {
    final builder = BytesBuilder(copy: false);
    await for (final chunk in response) {
      builder.add(chunk);
      if (builder.length > maxResponseBytes) {
        throw const BackupTransferException(
          'The server response is too large.',
        );
      }
    }
    return utf8.decode(builder.takeBytes());
  }

  void close() {
    _client.close(force: true);
  }
}
