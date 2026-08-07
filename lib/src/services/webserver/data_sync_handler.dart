import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:logging/logging.dart';
import 'package:reaprime/src/services/webserver/data_export/data_export_section.dart';
import 'package:reaprime/src/services/webserver/data_export/data_transfer_result.dart';
import 'package:reaprime/src/services/webserver/data_export_handler.dart';
import 'package:reaprime/src/services/webserver/json_response.dart';
import 'package:reaprime/src/util/temp_archive_files.dart';
import 'package:shelf_plus/shelf_plus.dart';

enum SyncMode { pull, push, twoWay }

class SyncTargetException implements Exception {
  final String error;
  final String message;
  final int? statusCode;

  const SyncTargetException(this.error, this.message, {this.statusCode});

  @override
  String toString() => 'SyncTargetException: $message';
}

class _LocalExportException implements Exception {
  final Object cause;

  const _LocalExportException(this.cause);
}

class DataSyncHandler {
  static const _skippedPushMessage =
      'Push was not attempted because pull did not complete.';

  final DataExportHandler _exportHandler;
  final http.Client _httpClient;
  final Logger _log = Logger('DataSyncHandler');

  DataSyncHandler({
    required DataExportHandler exportHandler,
    required http.Client httpClient,
  }) : _exportHandler = exportHandler,
       _httpClient = httpClient;

  void addRoutes(RouterPlus app) {
    app.post('/api/v1/data/sync', _handleSync);
  }

  Future<Response> _handleSync(Request request) async {
    final dynamic decoded;
    try {
      final body = await _readRequestBody(request);
      decoded = jsonDecode(body);
    } on SyncBodyTooLarge {
      return jsonPayloadTooLarge({
        'error': 'Request body too large',
        'message': 'The sync request body exceeds the size limit.',
      });
    } catch (_) {
      return jsonBadRequest({'error': 'Invalid JSON'});
    }
    if (decoded is! Map) {
      return jsonBadRequest({
        'error': 'Invalid JSON',
        'message': 'The request body must be a JSON object.',
      });
    }
    final body = Map<String, dynamic>.from(decoded);

    final target = body['target'];
    if (target is! String || target.isEmpty) {
      return jsonBadRequest({
        'error': 'Missing required field',
        'message': '"target" is required',
      });
    }
    final targetUri = Uri.tryParse(target);
    if (targetUri == null ||
        !targetUri.hasScheme ||
        (targetUri.scheme != 'http' && targetUri.scheme != 'https')) {
      return jsonBadRequest({
        'error': 'Invalid target URL',
        'message':
            '"target" must be a valid HTTP/HTTPS URL (e.g., http://192.168.1.50:8080)',
      });
    }

    final modeValue = body['mode'];
    if (modeValue is! String) {
      return jsonBadRequest({
        'error': 'Missing required field',
        'message': '"mode" is required. Valid values: pull, push, two_way',
      });
    }
    final mode = _parseMode(modeValue);
    if (mode == null) {
      return jsonBadRequest({
        'error': 'Invalid mode',
        'message': 'Valid values: pull, push, two_way',
      });
    }

    final onConflict = body['onConflict'];
    if (onConflict != null && onConflict is! String) {
      return jsonBadRequest({
        'error': 'Invalid onConflict value',
        'message': 'Valid values: skip, overwrite',
      });
    }
    final strategy = _parseStrategy(onConflict as String? ?? 'skip');
    if (strategy == null) {
      return jsonBadRequest({
        'error': 'Invalid onConflict value',
        'message': 'Valid values: skip, overwrite',
      });
    }

    final continueValue = body['continueOnPullFailure'];
    if (continueValue != null && continueValue is! bool) {
      return jsonBadRequest({
        'error': 'Invalid continueOnPullFailure value',
        'message': 'continueOnPullFailure must be a boolean',
      });
    }
    final continueOnPullFailure = continueValue as bool? ?? false;
    if (continueOnPullFailure && mode != SyncMode.twoWay) {
      return jsonBadRequest({
        'error': 'Invalid continueOnPullFailure value',
        'message': 'continueOnPullFailure applies only to two_way mode',
      });
    }

    final sectionsResult = _parseSections(body['sections']);
    if (sectionsResult.error != null) {
      return jsonBadRequest(sectionsResult.error!);
    }
    final sections = sectionsResult.sections;
    final expectedSections = sections ?? _exportHandler.sectionKeys;

    DataTransferPhaseOutcome? pull;
    DataTransferPhaseOutcome? push;

    if (mode == SyncMode.pull || mode == SyncMode.twoWay) {
      try {
        pull = await _pull(target, strategy, expectedSections);
      } catch (error) {
        pull = _failure(error);
      }
    }

    if (mode == SyncMode.push) {
      try {
        push = await _push(target, strategy, sections, expectedSections);
      } catch (error) {
        push = _failure(error);
      }
    } else if (mode == SyncMode.twoWay) {
      if (pull!.complete || continueOnPullFailure) {
        try {
          push = await _push(target, strategy, sections, expectedSections);
        } catch (error) {
          push = _failure(error);
        }
      } else {
        push = DataTransferPhaseOutcome(
          status: DataTransferStatus.skipped,
          sections: {},
          reason: 'pull_not_complete',
          message: _skippedPushMessage,
        );
      }
    }

    return _response(mode: mode, pull: pull, push: push);
  }

  /// Streams the local export into a temp ZIP, then imports from the file.
  ///
  /// The target only responds after it has generated its export archive, so
  /// there is no short header timeout; connection establishment is bounded by
  /// the HTTP client's connection timeout, idle gaps by
  /// [DataTransferLimits.syncIdleTimeout], and the network stages (headers
  /// and download) by a deadline of [DataTransferLimits.syncOverallTimeout]
  /// starting at the request. The deadline aborts the request at the
  /// transport level ([http.AbortableRequest]), so a timed-out pull cancels
  /// the download — including while the target is still generating its
  /// export, before any headers arrived — and never starts its import. The
  /// local import itself is NOT cut off: it runs to completion and its
  /// actual result is reported, because abandoning an import mid-write
  /// would leave the database mutating after the caller was told the phase
  /// failed.
  Future<DataTransferPhaseOutcome> _pull(
    String target,
    ConflictStrategy strategy,
    List<String> expectedSections,
  ) async {
    final limits = _exportHandler.limits;
    _log.info('Pulling data from $target');
    final tempDir = await TempArchiveDir.create('reaprime-sync-pull-');
    final deadline = DateTime.now().add(limits.syncOverallTimeout);
    final abortCompleter = Completer<void>();
    final abortTimer = Timer(limits.syncOverallTimeout, () {
      if (!abortCompleter.isCompleted) abortCompleter.complete();
    });
    try {
      final request = http.AbortableRequest(
        'GET',
        Uri.parse('$target/api/v1/data/export'),
        abortTrigger: abortCompleter.future,
      );
      final streamed = await _httpClient
          .send(request)
          .timeout(_remaining(deadline));

      if (streamed.statusCode != 200) {
        throw SyncTargetException(
          'Target error',
          'Target returned status ${streamed.statusCode}',
          statusCode: streamed.statusCode,
        );
      }

      final zipFile = File(tempDir.filePath('pull.zip'));
      final raf = await zipFile.open(mode: FileMode.write);
      var received = 0;
      Object? abortError;
      final done = Completer<void>();
      StreamSubscription<List<int>>? sub;
      try {
        sub = streamed.stream
            .timeout(limits.syncIdleTimeout)
            .listen(
              (chunk) {
                if (abortError != null) return;
                received += chunk.length;
                if (received > limits.maxImportRequestBytes) {
                  abortError = InvalidBackupException(
                    message: 'The pulled archive exceeds the size limit.',
                    reason: 'request_too_large',
                  );
                  sub?.cancel();
                  done.completeError(abortError!);
                  return;
                }
                raf.writeFromSync(chunk);
              },
              onError: (Object e, StackTrace st) {
                if (abortError == null) done.completeError(e, st);
              },
              onDone: () {
                if (abortError != null) {
                  done.completeError(abortError!);
                } else {
                  done.complete();
                }
              },
              cancelOnError: true,
            );
        await done.future.timeout(_remaining(deadline));
      } finally {
        abortTimer.cancel();
        await sub?.cancel();
        await raf.close();
      }

      final outcome = await _exportHandler.importFromZipFile(
        zipFile,
        strategy,
        sections: expectedSections,
      );
      return outcome.phase;
    } finally {
      await tempDir.dispose();
    }
  }

  /// Exports locally into a temp ZIP and streams it to the target with a
  /// known content length.
  ///
  /// The network stages (upload and response) share one deadline of
  /// [DataTransferLimits.syncOverallTimeout] starting at the request; the
  /// local export runs before the deadline and is not cut off. The body is
  /// fed through `sink.addStream`, whose controller pauses the file read
  /// while the transport is backpressured, keeping the upload bounded in
  /// memory. A deadline expiry aborts the transport
  /// ([http.AbortableStreamedRequest]), so a push that is still uploading
  /// cannot complete remotely. If the archive was already fully uploaded
  /// before the deadline, the remote outcome is unknowable (the target may
  /// have begun importing); the phase then reports `timeout_unknown`
  /// instead of claiming the push did not happen.
  Future<DataTransferPhaseOutcome> _push(
    String target,
    ConflictStrategy strategy,
    List<String>? sections,
    List<String> expectedSections,
  ) async {
    final limits = _exportHandler.limits;
    _log.info('Pushing data to $target');
    final tempDir = await TempArchiveDir.create('reaprime-sync-push-');
    try {
      final File zipFile;
      try {
        zipFile = await _exportHandler.exportToZipFile(
          tempDir.directory,
          sections: sections,
        );
      } catch (error) {
        throw _LocalExportException(error);
      }

      final length = await zipFile.length();
      final deadline = DateTime.now().add(limits.syncOverallTimeout);
      final abortCompleter = Completer<void>();
      final request = http.AbortableStreamedRequest(
        'POST',
        Uri.parse('$target/api/v1/data/import?onConflict=${strategy.name}'),
        abortTrigger: abortCompleter.future,
      );
      request.headers['content-type'] = 'application/octet-stream';
      request.contentLength = length;

      // bodySent is set only when the file was fully read (never when the
      // source is cancelled by an abort or errors), so a timeout after the
      // upload completed can be told apart from one mid-upload.
      var bodySent = false;
      var aborted = false;
      Stream<List<int>> bodyStream() async* {
        await for (final chunk in zipFile.openRead()) {
          yield chunk;
        }
        bodySent = true;
      }

      // addStream couples the file read to the transport's consumption:
      // while the sink's listener is paused (backpressure) the source
      // subscription pauses too, so the unsent archive cannot accumulate
      // in memory. The sink closes only after the file is fully read
      // (addStream does not forward the source's done event), and never
      // after an abort, when the controller is already cancelled. A
      // transport abort cancels the generator and with it the file read.
      final bodyStreamDone = request.sink.addStream(bodyStream()).then((
        _,
      ) async {
        if (!aborted) await request.sink.close();
      });

      Future<void> abortUpload() async {
        aborted = true;
        if (!abortCompleter.isCompleted) abortCompleter.complete();
        try {
          await bodyStreamDone;
        } catch (_) {}
      }

      try {
        final completed = await Future.wait<Object?>([
          _httpClient.send(request),
          bodyStreamDone,
        ], eagerError: true).timeout(_remaining(deadline));
        final streamed = completed.first as http.StreamedResponse;
        final statusCode = streamed.statusCode;
        if (statusCode != 200 && statusCode != 207) {
          throw SyncTargetException(
            'Target error',
            'Target returned status $statusCode',
            statusCode: statusCode,
          );
        }

        final body = await _readBoundedResponse(
          streamed.stream,
          limits.maxSyncResponseBytes,
          limits.syncIdleTimeout,
          _remaining(deadline),
        );

        final dynamic decoded;
        try {
          decoded = jsonDecode(body);
        } catch (_) {
          return DataTransferPhaseOutcome.failed(
            error: 'Invalid target response',
            message: 'The target returned invalid JSON.',
            reason: 'invalid_json',
          );
        }
        return DataTransferPhaseOutcome.fromRemote(
          decoded,
          expectedSections,
          minimumStatus: statusCode == 207 ? DataTransferStatus.partial : null,
        );
      } on TimeoutException {
        final uploadComplete = bodySent;
        await abortUpload();
        if (uploadComplete) {
          return DataTransferPhaseOutcome.failed(
            error: 'Sync timed out',
            message:
                'The sync timed out; the target may have already '
                'imported the pushed archive.',
            reason: 'timeout_unknown',
          );
        }
        rethrow;
      } catch (_) {
        await abortUpload();
        rethrow;
      }
    } finally {
      await tempDir.dispose();
    }
  }

  /// Time remaining on the phase deadline (zero when it has expired).
  Duration _remaining(DateTime deadline) {
    final left = deadline.difference(DateTime.now());
    return left.isNegative ? Duration.zero : left;
  }

  Response _response({
    required SyncMode mode,
    required DataTransferPhaseOutcome? pull,
    required DataTransferPhaseOutcome? push,
  }) {
    final phases = [pull, push].whereType<DataTransferPhaseOutcome>().toList();
    final status = _operationStatus(mode, phases);
    final result = <String, dynamic>{
      'status': status.name,
      'complete': status == DataTransferStatus.complete,
      'partial': status == DataTransferStatus.partial,
      'mode': _wireMode(mode),
      if (pull != null) 'pull': _legacyPhaseResult(pull),
      if (push != null) 'push': _legacyPhaseResult(push),
      'phases': {
        if (pull != null) 'pull': pull.toMetadata(),
        if (push != null) 'push': push.toMetadata(),
      },
    };

    if (status == DataTransferStatus.complete) return jsonOk(result);
    if (mode == SyncMode.twoWay && status == DataTransferStatus.partial) {
      return jsonMultiStatus(result);
    }
    return jsonBadGateway(result);
  }

  Map<String, dynamic> _legacyPhaseResult(DataTransferPhaseOutcome phase) {
    if (phase.status == DataTransferStatus.skipped) return {};
    if (phase.sections.isNotEmpty) return phase.sectionResults;
    final result = phase.toMetadata();
    if (phase.statusCode != null) result['status'] = phase.statusCode;
    return result;
  }

  DataTransferStatus _operationStatus(
    SyncMode mode,
    List<DataTransferPhaseOutcome> phases,
  ) {
    if (phases.every((phase) => phase.complete)) {
      return DataTransferStatus.complete;
    }
    if (mode == SyncMode.twoWay &&
        phases.any(
          (phase) =>
              phase.status == DataTransferStatus.complete ||
              phase.status == DataTransferStatus.partial,
        )) {
      return DataTransferStatus.partial;
    }
    if (mode != SyncMode.twoWay &&
        phases.any((phase) => phase.status == DataTransferStatus.partial)) {
      return DataTransferStatus.partial;
    }
    return DataTransferStatus.failed;
  }

  DataTransferPhaseOutcome _failure(Object error) {
    if (error is InvalidBackupException) {
      return DataTransferPhaseOutcome.failed(
        error: 'Invalid backup archive',
        message: error.message,
        reason: error.reason,
      );
    }
    if (error is _LocalExportException) {
      return DataTransferPhaseOutcome.failed(
        error: 'Local export failed',
        message: '${error.cause}',
        reason: 'local_export_failed',
      );
    }
    if (error is SyncTargetException) {
      return DataTransferPhaseOutcome.failed(
        error: error.error,
        message: error.message,
        reason: 'target_error',
        statusCode: error.statusCode,
      );
    }
    if (error is http.RequestAbortedException) {
      return DataTransferPhaseOutcome.failed(
        error: 'Target unreachable',
        message: 'Request timed out',
        reason: 'timeout',
      );
    }
    if (error is http.ClientException) {
      return DataTransferPhaseOutcome.failed(
        error: 'Target unreachable',
        message: error.message,
        reason: 'target_unreachable',
      );
    }
    if (error is TimeoutException) {
      return DataTransferPhaseOutcome.failed(
        error: 'Target unreachable',
        message: 'Request timed out',
        reason: 'timeout',
      );
    }
    return DataTransferPhaseOutcome.failed(
      error: 'Sync failed',
      message: '$error',
      reason: 'unexpected_error',
    );
  }

  Future<String> _readRequestBody(Request request) async {
    final limits = _exportHandler.limits;
    final builder = BytesBuilder(copy: false);
    await for (final chunk in request.read()) {
      builder.add(chunk);
      if (builder.length > limits.maxSyncRequestBytes) {
        throw const SyncBodyTooLarge();
      }
    }
    return utf8.decode(builder.takeBytes());
  }

  /// Reads a response body with an idle timeout between events and an overall
  /// timeout for the whole body. Either timeout cancels the subscription so
  /// the connection is released even if the caller has already given up on
  /// the phase.
  Future<String> _readBoundedResponse(
    Stream<List<int>> stream,
    int maxBytes,
    Duration idleTimeout,
    Duration overallTimeout,
  ) async {
    final builder = BytesBuilder(copy: false);
    final done = Completer<String>();
    StreamSubscription<List<int>>? sub;
    sub = stream
        .timeout(idleTimeout)
        .listen(
          (chunk) {
            builder.add(chunk);
            if (builder.length > maxBytes) {
              sub?.cancel();
              done.completeError(
                SyncTargetException(
                  'Target error',
                  'Target response is too large.',
                ),
              );
            }
          },
          onError: (Object e, StackTrace st) => done.completeError(e, st),
          onDone: () => done.complete(utf8.decode(builder.takeBytes())),
          cancelOnError: true,
        );
    try {
      return await done.future.timeout(overallTimeout);
    } finally {
      await sub.cancel();
    }
  }

  _SectionsResult _parseSections(dynamic value) {
    if (value == null) return const _SectionsResult(null);
    if (value is! List || value.any((section) => section is! String)) {
      return _SectionsResult.errorResult({
        'error': 'Invalid sections value',
        'message': 'sections must be an array of section names',
      });
    }

    final sections = <String>[];
    for (final section in value.cast<String>()) {
      if (!sections.contains(section)) sections.add(section);
    }
    if (sections.isEmpty) {
      return _SectionsResult.errorResult({
        'error': 'Invalid sections value',
        'message': 'sections must not be empty',
      });
    }
    final unknown = sections
        .where((section) => !_exportHandler.sectionKeys.contains(section))
        .toList(growable: false);
    if (unknown.isNotEmpty) {
      return _SectionsResult.errorResult({
        'error': 'Unknown section',
        'message': 'Unknown data section(s): ${unknown.join(', ')}',
      });
    }
    return _SectionsResult(sections);
  }

  SyncMode? _parseMode(String value) => switch (value) {
    'pull' => SyncMode.pull,
    'push' => SyncMode.push,
    'two_way' => SyncMode.twoWay,
    _ => null,
  };

  String _wireMode(SyncMode mode) => switch (mode) {
    SyncMode.pull => 'pull',
    SyncMode.push => 'push',
    SyncMode.twoWay => 'two_way',
  };

  ConflictStrategy? _parseStrategy(String value) => switch (value) {
    'skip' => ConflictStrategy.skip,
    'overwrite' => ConflictStrategy.overwrite,
    _ => null,
  };
}

class SyncBodyTooLarge implements Exception {
  const SyncBodyTooLarge();
}

class _SectionsResult {
  final List<String>? sections;
  final Map<String, dynamic>? error;

  const _SectionsResult(this.sections) : error = null;

  const _SectionsResult.errorResult(this.error) : sections = null;
}
