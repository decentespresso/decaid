import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:logging/logging.dart';
import 'package:reaprime/src/controllers/de1_controller.dart';
import 'package:reaprime/src/controllers/workflow_controller.dart';
import 'package:reaprime/src/models/data/json_utils.dart';
import 'package:reaprime/src/models/data/workflow.dart';
import 'package:reaprime/src/models/errors.dart';
import 'package:reaprime/src/services/webserver/json_patch.dart';
import 'package:reaprime/src/services/webserver/json_response.dart';
import 'package:shelf_plus/shelf_plus.dart';

const _workflowBodyReadTimeout = Duration(seconds: 30);
const _workflowQueueWaitTimeout = Duration(seconds: 30);
const _workflowMaxBodyBytes = 1024 * 1024;
const _workflowMaxPendingRequests = 8;

class _WorkflowPayloadTooLarge implements Exception {}

class WorkflowHandler {
  final WorkflowController _controller;
  final De1Controller _de1controller;
  final Duration bodyReadTimeout;
  final Duration queueWaitTimeout;
  final int maxBodyBytes;
  final int maxPendingRequests;

  static final _log = Logger('WorkflowHandler');
  Future<void> _workflowQueue = Future<void>.value();
  int _pendingRequests = 0;

  WorkflowHandler({
    required WorkflowController controller,
    required De1Controller de1controller,
    this.bodyReadTimeout = _workflowBodyReadTimeout,
    this.queueWaitTimeout = _workflowQueueWaitTimeout,
    this.maxBodyBytes = _workflowMaxBodyBytes,
    this.maxPendingRequests = _workflowMaxPendingRequests,
  }) : _controller = controller,
       _de1controller = de1controller;

  void addRoutes(RouterPlus app) {
    app.get('/api/v1/workflow', _getWorkflow);
    app.put('/api/v1/workflow', _updateWorkflow);
  }

  Future<Response> _getWorkflow(Request req) async {
    final workflow = _controller.currentWorkflow;
    return jsonOk(workflow.toJson());
  }

  Future<Response> _updateWorkflow(Request req) {
    if (_pendingRequests >= maxPendingRequests) {
      return Future.value(
        jsonTooManyRequests({'error': 'Workflow request queue is full'}),
      );
    }
    _pendingRequests++;
    final payload = _readPayload(req);
    unawaited(
      payload.then<void>(
        (_) {},
        onError: (Object error, StackTrace stackTrace) {},
      ),
    );
    var expired = false;
    var slotReleased = false;
    void releaseSlot() {
      if (slotReleased) return;
      slotReleased = true;
      _pendingRequests--;
    }

    final response = Completer<Response>();
    late final Timer waitTimer;
    final operation = _workflowQueue.then((_) async {
      if (expired) return;
      waitTimer.cancel();
      try {
        final result = await _applyPayload(payload);
        if (!response.isCompleted) response.complete(result);
      } finally {
        releaseSlot();
      }
    });
    _workflowQueue = operation.then<void>(
      (_) {},
      onError: (Object error, StackTrace stackTrace) {
        _log.severe('Error completing workflow queue entry', error, stackTrace);
        releaseSlot();
      },
    );
    waitTimer = Timer(queueWaitTimeout, () {
      expired = true;
      releaseSlot();
      if (!response.isCompleted) {
        response.complete(
          jsonServiceUnavailable({'error': 'Workflow request queue timed out'}),
        );
      }
    });
    return response.future;
  }

  Future<String> _readPayload(Request req) async {
    final declaredLength = int.tryParse(req.headers['content-length'] ?? '');
    if (declaredLength != null && declaredLength > maxBodyBytes) {
      throw _WorkflowPayloadTooLarge();
    }
    final deadline = Stopwatch()..start();
    final bytes = BytesBuilder(copy: false);
    final iterator = StreamIterator<List<int>>(req.read());
    try {
      while (true) {
        final remaining = bodyReadTimeout - deadline.elapsed;
        if (remaining <= Duration.zero) {
          throw TimeoutException('Workflow request body timed out');
        }
        if (!await iterator.moveNext().timeout(remaining)) break;
        final chunk = iterator.current;
        if (bytes.length + chunk.length > maxBodyBytes) {
          throw _WorkflowPayloadTooLarge();
        }
        bytes.add(chunk);
      }
      return utf8.decode(bytes.takeBytes());
    } finally {
      await iterator.cancel();
    }
  }

  Future<Response> _applyPayload(Future<String> payloadFuture) async {
    try {
      final decoded = jsonDecode(await payloadFuture);
      if (decoded is! Map<String, dynamic>) {
        return jsonBadRequest({'error': 'Request body must be a JSON object'});
      }
      return await _applyUpdate(Map<String, dynamic>.from(decoded));
    } on _WorkflowPayloadTooLarge {
      return jsonPayloadTooLarge({
        'error': 'Workflow request body is too large',
      });
    } on TimeoutException {
      return jsonRequestTimeout({
        'error': 'Request timeout',
        'message': 'Client did not finish sending the request body',
      });
    } on FormatException catch (e) {
      return jsonBadRequest({'error': 'Invalid request', 'message': '$e'});
    } catch (e, st) {
      _log.severe('Error reading workflow request', e, st);
      return jsonError({'error': 'Internal server error', 'message': '$e'});
    }
  }

  Future<Response> _applyUpdate(Map<String, dynamic> merge) async {
    try {
      rejectExplicitNulls(merge, const ['steamSettings']);
      if (merge['steamSettings'] case final Map<String, dynamic> settings) {
        rejectExplicitNulls(settings, const [
          'targetTemperature',
          'duration',
          'flow',
          'stopAtTemperature',
        ]);
      } else if (merge.containsKey('steamSettings')) {
        throw const FormatException('Field "steamSettings" must be an object');
      }

      while (true) {
        final oldWorkflow = _controller.currentWorkflow;
        final revision = _controller.revision;
        final currentJson = oldWorkflow.toJson();
        final resultJson = deepMergeJson(currentJson, merge);
        final updatedWorkflow = Workflow.fromJson(resultJson);

        await _de1controller.updateWorkflowSettings(
          oldWorkflow,
          updatedWorkflow,
        );
        if (_controller.setWorkflowIfRevision(updatedWorkflow, revision)) {
          return jsonOk(updatedWorkflow.toJson());
        }
      }
    } on De1WriteQueueFullException catch (e) {
      return jsonServiceUnavailable({
        'error': 'Machine write queue is full',
        'message': '$e',
      });
    } on De1WriteSupersededException catch (e) {
      return jsonConflict({
        'error': 'Workflow update was superseded',
        'message': '$e',
      });
    } on MachineReplacementTimeoutException catch (e) {
      return jsonServiceUnavailable({
        'error': 'Machine unavailable',
        'message': '$e',
      });
    } on TimeoutException catch (e) {
      return jsonServiceUnavailable({
        'error': 'Machine unavailable',
        'message': '$e',
      });
    } on ArgumentError catch (e) {
      return jsonBadRequest({'error': 'Invalid request', 'message': '$e'});
    } on FormatException catch (e) {
      return jsonBadRequest({'error': 'Invalid request', 'message': '$e'});
    } catch (e, st) {
      _log.severe('Error in workflow queue entry', e, st);
      return jsonError({'error': 'Internal server error', 'message': '$e'});
    }
  }
}
