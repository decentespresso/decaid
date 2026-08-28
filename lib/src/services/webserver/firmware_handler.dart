import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:logging/logging.dart';
import 'package:reaprime/src/controllers/de1_controller.dart';
import 'package:reaprime/src/models/device/de1_interface.dart';
import 'package:reaprime/src/models/device/firmware_artifact.dart';
import 'package:reaprime/src/models/device/firmware_update_state.dart';
import 'package:reaprime/src/models/errors.dart';
import 'package:reaprime/src/services/firmware/bundled_firmware_catalog.dart';
import 'package:reaprime/src/services/firmware/firmware_manifest.dart';
import 'package:reaprime/src/services/firmware/firmware_validator.dart';
import 'package:reaprime/src/services/webserver/bounded_request_body.dart';
import 'package:shelf_plus/shelf_plus.dart';

const _maxRawFirmwareBodyBytes = 16 * 1024 * 1024;
const _rawFirmwareBodyReadTimeout = Duration(seconds: 60);
const _maxManagedFirmwareBodyBytes = 64 * 1024;
const _managedFirmwareBodyReadTimeout = Duration(seconds: 10);

class FirmwareHandler {
  final De1Controller _controller;
  final BundledFirmwareCatalog _catalog;
  final FirmwareValidator _validator;
  final Logger _log;
  final int maxRawBodyBytes;
  final Duration rawBodyReadTimeout;
  final int maxManagedBodyBytes;
  final Duration managedBodyReadTimeout;

  FirmwareHandler({
    required De1Controller controller,
    required BundledFirmwareCatalog catalog,
    FirmwareValidator? validator,
    Logger? logger,
    this.maxRawBodyBytes = _maxRawFirmwareBodyBytes,
    this.rawBodyReadTimeout = _rawFirmwareBodyReadTimeout,
    this.maxManagedBodyBytes = _maxManagedFirmwareBodyBytes,
    this.managedBodyReadTimeout = _managedFirmwareBodyReadTimeout,
  }) : _controller = controller,
       _catalog = catalog,
       _validator = validator ?? const FirmwareValidator(),
       _log = logger ?? Logger('FirmwareHandler');

  void addRoutes(RouterPlus app) {
    app.get('/api/v1/machine/firmware', _getCatalog);
    app.post('/api/v1/machine/firmware', _uploadRaw);
    app.post('/api/v1/machine/firmware/apply', _applyManaged);
    app.delete('/api/v1/machine/firmware', _cancelUpdate);
  }

  Future<Response> _getCatalog(Request _) async {
    final manifest = await _catalog.loadManifest();

    String? connectedModel;
    String? installedBuild;
    try {
      final de1 = _controller.connectedDe1();
      final info = de1.machineInfo;
      connectedModel = info.model;
      installedBuild = info.version;
    } catch (_) {}

    final artifacts = <Map<String, dynamic>>[];
    FirmwareArtifact? recommended;
    var hasUnknownEligibility = false;

    for (final entry in manifest.entries) {
      final artifact = entry.artifact;
      final eligibility = _validator.evaluateEligibility(
        artifact,
        connectedModel: connectedModel,
        installedBuild: installedBuild,
      );

      if (eligibility.status == FirmwareEligibilityStatus.applicable &&
          (recommended == null || artifact.build > recommended.build)) {
        recommended = artifact;
      }
      hasUnknownEligibility |=
          eligibility.status == FirmwareEligibilityStatus.unknown;

      artifacts.add({
        ...artifact.toJson(),
        'eligibility': eligibility.toJson(),
      });
    }

    final bool? updateAvailable =
        connectedModel == null || hasUnknownEligibility
        ? null
        : recommended != null;

    return Response.ok(
      jsonEncode({
        'artifacts': artifacts,
        'machine': connectedModel != null
            ? {
                'model': connectedModel,
                'build': int.tryParse(installedBuild ?? ''),
              }
            : null,
        'recommendedArtifactId': recommended?.id,
        'updateAvailable': updateAvailable,
        'operation': {'state': _resolveOperationState().name},
      }),
      headers: {'Content-Type': 'application/json'},
    );
  }

  FirmwareUpdateState _resolveOperationState() {
    try {
      final de1 = _controller.connectedDe1();
      return de1.firmwareUpdateState;
    } catch (_) {
      return FirmwareUpdateState.idle;
    }
  }

  Future<Response> _uploadRaw(Request request) async {
    final Uint8List bodyBytes;
    try {
      bodyBytes = await readBoundedRequestBody(
        request,
        maxBytes: maxRawBodyBytes,
        timeout: rawBodyReadTimeout,
      );
    } on RequestBodyReadException catch (error) {
      return Response(
        error.statusCode,
        body: jsonEncode(
          error.statusCode == 413
              ? {
                  'error': 'payload_too_large',
                  'message': 'Firmware image exceeds the 16 MiB limit',
                }
              : {
                  'error': 'request_timeout',
                  'message':
                      'Firmware body was not received within the time limit',
                },
        ),
        headers: {'Content-Type': 'application/json'},
      );
    }
    if (bodyBytes.isEmpty) {
      return Response.badRequest(
        body: jsonEncode({
          'error': 'invalid_request',
          'message': 'Request body must not be empty',
        }),
      );
    }
    final de1 = _resolveDe1();
    if (de1 == null) return _machineUnavailable();

    return _streamFirmwareUpload(bodyBytes);
  }

  Future<Response> _applyManaged(Request request) async {
    final Object? decoded;
    try {
      final bytes = await readBoundedRequestBody(
        request,
        maxBytes: maxManagedBodyBytes,
        timeout: managedBodyReadTimeout,
      );
      decoded = jsonDecode(utf8.decode(bytes));
    } on RequestBodyReadException catch (error) {
      return Response(
        error.statusCode,
        body: jsonEncode(
          error.statusCode == 413
              ? {
                  'error': 'payload_too_large',
                  'message':
                      'Managed firmware request exceeds the 64 KiB limit',
                }
              : {
                  'error': 'request_timeout',
                  'message':
                      'Managed firmware request was not received in time',
                },
        ),
        headers: {'Content-Type': 'application/json'},
      );
    } on FormatException {
      return _invalidRequest('Request body must be valid JSON');
    }
    if (decoded is! Map<String, dynamic>) {
      return _invalidRequest('Request body must be a JSON object');
    }

    final artifactId = decoded['artifactId'];
    if (artifactId is! String || artifactId.isEmpty) {
      return _invalidRequest('artifactId is required');
    }
    final forceValue = decoded['force'];
    if (forceValue != null && forceValue is! bool) {
      return _invalidRequest('force must be a boolean');
    }
    final force = forceValue as bool? ?? false;

    if (_resolveDe1() == null) return _machineUnavailable();

    final manifest = await _catalog.loadManifest();
    FirmwareManifestEntry? entry;
    for (final candidate in manifest.entries) {
      if (candidate.artifact.id == artifactId) {
        entry = candidate;
        break;
      }
    }
    if (entry == null) {
      return Response.notFound(
        jsonEncode({
          'error': 'artifact_not_found',
          'message': 'Unknown artifact ID: $artifactId',
        }),
        headers: {'Content-Type': 'application/json'},
      );
    }

    final image = await _catalog.loadImage(artifactId);

    try {
      _validator.validate(entry, image);
    } on FirmwareImageValidationException catch (e) {
      return Response(
        422,
        body: jsonEncode({
          'error': 'artifact_validation_failed',
          'message': e.reason,
        }),
        headers: {'Content-Type': 'application/json'},
      );
    }

    final de1 = _resolveDe1();
    if (de1 == null) return _machineUnavailable();
    final info = de1.machineInfo;
    final eligibility = _validator.evaluateEligibility(
      entry.artifact,
      connectedModel: info.model,
      installedBuild: info.version,
    );

    final modelInvalid = eligibility.reasons.any(
      {
        FirmwareEligibilityReason.modelIncompatible.code,
        FirmwareEligibilityReason.machineModelUnknown.code,
      }.contains,
    );
    if (modelInvalid ||
        (eligibility.status != FirmwareEligibilityStatus.applicable &&
            !force)) {
      return Response(
        422,
        body: jsonEncode({
          'error': 'artifact_not_applicable',
          'reasons': eligibility.reasons,
        }),
        headers: {'Content-Type': 'application/json'},
      );
    }

    return _streamFirmwareUpload(image);
  }

  Future<Response> _cancelUpdate(Request _) async {
    FirmwareUpdateState state = FirmwareUpdateState.idle;
    try {
      await _controller.cancelFirmwareUpload();
      state = _resolveOperationState();
    } catch (_) {}
    return Response(
      202,
      body: jsonEncode({
        'operation': {'state': state.name},
      }),
      headers: {'Content-Type': 'application/json'},
    );
  }

  De1Interface? _resolveDe1() {
    try {
      return _controller.connectedDe1();
    } catch (_) {
      return null;
    }
  }

  Response _invalidRequest(String message) {
    return Response.badRequest(
      body: jsonEncode({'error': 'invalid_request', 'message': message}),
      headers: {'Content-Type': 'application/json'},
    );
  }

  Response _machineUnavailable() {
    return Response(
      503,
      body: jsonEncode({
        'error': 'machine_unavailable',
        'message': 'No machine is connected',
      }),
      headers: {'Content-Type': 'application/json'},
    );
  }

  Response _streamFirmwareUpload(Uint8List image) {
    final progressController = StreamController<List<int>>();

    void emit(Map<String, dynamic> event) {
      if (!progressController.isClosed) {
        progressController.add(utf8.encode('${jsonEncode(event)}\n'));
      }
    }

    progressController.onCancel = () async {
      _log.warning('firmware upload: client disconnected, cancelling');
      await _controller.cancelFirmwareUpload();
    };

    var lastProgress = -1.0;
    try {
      _controller
          .updateFirmware(
            image,
            onStart: () => emit({'status': 'erasing', 'progress': 0.0}),
            onProgress: (progress) {
              if (progress - lastProgress < 0.01) return;
              lastProgress = progress;
              if (!progressController.isClosed) {
                emit({'status': 'uploading', 'progress': progress});
              }
            },
          )
          .then((_) {
            emit({'status': 'done', 'progress': 1.0});
            progressController.close();
          })
          .catchError((Object e) {
            emit({'status': 'error', 'progress': -1.0, 'error': e.toString()});
            progressController.close();
          });
    } on FirmwareUpdateInProgressException {
      unawaited(progressController.close());
      return Response(
        409,
        body: jsonEncode({
          'error': 'firmware_update_in_progress',
          'message': 'A firmware update is already in progress',
        }),
        headers: {'Content-Type': 'application/json'},
      );
    } on De1WriteQueueFullException catch (e) {
      unawaited(progressController.close());
      return Response(
        503,
        body: jsonEncode({
          'error': 'Machine write queue is full',
          'message': '$e',
        }),
        headers: {'Content-Type': 'application/json'},
      );
    }

    return Response.ok(
      progressController.stream,
      headers: {'Content-Type': 'application/x-ndjson'},
    );
  }
}
