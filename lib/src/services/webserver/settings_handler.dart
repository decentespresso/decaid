part of '../webserver_service.dart';

class SettingsHandler {
  final SettingsController _controller;
  final WebUIService _webUIService;
  final WebUIStorage _webUIStorage;
  final BatteryController? _batteryController;

  SettingsHandler({
    required SettingsController controller,
    required WebUIService service,
    required WebUIStorage webUIStorage,
    BatteryController? batteryController,
  }) : _controller = controller,
       _webUIService = service,
       _webUIStorage = webUIStorage,
       _batteryController = batteryController;

  void addRoutes(RouterPlus app) {
    app.get('/api/v1/settings', () async {
      log.info("handling settings");
      final gatewayMode = _controller.gatewayMode.name;
      final webPath = _webUIService.serverPath();
      final logLevel = _controller.logLevel;
      final weightFlowMultiplier = _controller.weightFlowMultiplier;
      final volumeFlowMultiplier = _controller.volumeFlowMultiplier;
      final hotWaterFlowMultiplier = _controller.hotWaterFlowMultiplier;
      final scalePowerMode = _controller.scalePowerMode.name;
      final blockOnNoScale = _controller.blockOnNoScale;
      final blockTareDuringShot = _controller.blockTareDuringShot;
      final stopHotWaterAtWeight = _controller.stopHotWaterAtWeight;
      final preferredMachineId = _controller.preferredMachineId;
      final preferredScaleId = _controller.preferredScaleId;
      final defaultSkinId = _controller.defaultSkinId;
      final automaticUpdateCheck = _controller.automaticUpdateCheck;
      final result = <String, dynamic>{
        'gatewayMode': gatewayMode,
        'webUiPath': webPath,
        'logLevel': logLevel,
        'weightFlowMultiplier': weightFlowMultiplier,
        'volumeFlowMultiplier': volumeFlowMultiplier,
        'hotWaterFlowMultiplier': hotWaterFlowMultiplier,
        'scalePowerMode': scalePowerMode,
        'blockOnNoScale': blockOnNoScale,
        'blockTareDuringShot': blockTareDuringShot,
        'stopHotWaterAtWeight': stopHotWaterAtWeight,
        'preferredMachineId': preferredMachineId,
        'preferredScaleId': preferredScaleId,
        'defaultSkinId': defaultSkinId,
        'automaticUpdateCheck': automaticUpdateCheck,
        'chargingMode': _controller.chargingMode.name,
        'nightModeEnabled': _controller.nightModeEnabled,
        'nightModeSleepTime': _controller.nightModeSleepTime,
        'nightModeMorningTime': _controller.nightModeMorningTime,
        'lowBatteryBrightnessLimit': _controller.lowBatteryBrightnessLimit,
        'keepAwake': _controller.keepAwake,
        'simulatedDevices': _controller.simulatedDevices
            .map((e) => e.name)
            .toList(),
        'themeMode': _controller.themeMode.name,
      };
      if (_batteryController?.currentChargingState != null) {
        result['chargingState'] = _batteryController!.currentChargingState!
            .toJson();
      }
      return result;
    });
    app.post('/api/v1/settings', (Request request) async {
      final payload = await readBoundedRequestBodyString(
        request,
        maxBytes: largeRequestBodyBytes,
      );
      Map<String, dynamic> json = jsonDecode(payload);
      if (json.containsKey('gatewayMode')) {
        final GatewayMode? gatewayMode = GatewayModeFromString.fromString(
          json['gatewayMode'],
        );
        if (gatewayMode == null) {
          return jsonBadRequest({
            'message': '${json["gatewayMode"]} is not a gateway mode',
          });
        }
        await _controller.updateGatewayMode(gatewayMode);
      }
      if (json.containsKey('webUiPath')) {
        final webUiPath = json['webUiPath'].toString();
        final _ = File.fromUri(Uri.file(webUiPath));
        await _webUIService.serveFolderAtPath(webUiPath);
      }
      if (json.containsKey('logLevel')) {
        await _controller.updateLogLevel(json['logLevel']);
      }
      if (json.containsKey('weightFlowMultiplier')) {
        final value = json['weightFlowMultiplier'];
        if (value is num) {
          await _controller.setWeightFlowMultiplier(value.toDouble());
        } else {
          return jsonBadRequest({
            'message': 'weightFlowMultiplier must be a number',
          });
        }
      }
      if (json.containsKey('volumeFlowMultiplier')) {
        final value = json['volumeFlowMultiplier'];
        if (value is num) {
          await _controller.setVolumeFlowMultiplier(value.toDouble());
        } else {
          return jsonBadRequest({
            'message': 'volumeFlowMultiplier must be a number',
          });
        }
      }
      if (json.containsKey('hotWaterFlowMultiplier')) {
        final value = json['hotWaterFlowMultiplier'];
        if (value is num) {
          await _controller.setHotWaterFlowMultiplier(value.toDouble());
        } else {
          return jsonBadRequest({
            'message': 'hotWaterFlowMultiplier must be a number',
          });
        }
      }
      if (json.containsKey('scalePowerMode')) {
        final ScalePowerMode? mode = ScalePowerModeFromString.fromString(
          json['scalePowerMode'],
        );
        if (mode == null) {
          return jsonBadRequest({
            'message':
                '${json["scalePowerMode"]} is not a valid scale power mode',
          });
        }
        await _controller.setScalePowerMode(mode);
      }
      if (json.containsKey('blockOnNoScale')) {
        final value = json['blockOnNoScale'];
        if (value is bool) {
          await _controller.setBlockOnNoScale(value);
        } else {
          return jsonBadRequest({
            'message': 'blockOnNoScale must be a boolean',
          });
        }
      }
      if (json.containsKey('blockTareDuringShot')) {
        final value = json['blockTareDuringShot'];
        if (value is bool) {
          await _controller.setBlockTareDuringShot(value);
        } else {
          return jsonBadRequest({
            'message': 'blockTareDuringShot must be a boolean',
          });
        }
      }
      if (json.containsKey('stopHotWaterAtWeight')) {
        final value = json['stopHotWaterAtWeight'];
        if (value is bool) {
          await _controller.setStopHotWaterAtWeight(value);
        } else {
          return jsonBadRequest({
            'message': 'stopHotWaterAtWeight must be a boolean',
          });
        }
      }
      if (json.containsKey('preferredMachineId')) {
        final value = json['preferredMachineId'];
        if (value == null || value is String) {
          await _controller.setPreferredMachineId(value);
        } else {
          return jsonBadRequest({
            'message': 'preferredMachineId must be a string or null',
          });
        }
      }
      if (json.containsKey('preferredScaleId')) {
        final value = json['preferredScaleId'];
        if (value == null || value is String) {
          await _controller.setPreferredScaleId(value);
        } else {
          return jsonBadRequest({
            'message': 'preferredScaleId must be a string or null',
          });
        }
      }
      if (json.containsKey('defaultSkinId')) {
        final value = json['defaultSkinId'];
        if (value is String) {
          try {
            await _webUIStorage.setDefaultSkin(value);
          } catch (e) {
            return jsonBadRequest({
              'message': 'Invalid skin ID: ${e.toString()}',
            });
          }
        } else {
          return jsonBadRequest({'message': 'defaultSkinId must be a string'});
        }
      }
      if (json.containsKey('automaticUpdateCheck')) {
        final value = json['automaticUpdateCheck'];
        if (value is bool) {
          await _controller.setAutomaticUpdateCheck(value);
        } else {
          return jsonBadRequest({
            'message': 'automaticUpdateCheck must be a boolean',
          });
        }
      }
      if (json.containsKey('chargingMode')) {
        final mode = ChargingModeFromString.fromString(json['chargingMode']);
        if (mode == null) {
          return jsonBadRequest({
            'message': '${json["chargingMode"]} is not a valid charging mode',
          });
        }
        await _controller.setChargingMode(mode);
      }
      if (json.containsKey('nightModeEnabled')) {
        final value = json['nightModeEnabled'];
        if (value is bool) {
          await _controller.setNightModeEnabled(value);
        } else {
          return jsonBadRequest({
            'message': 'nightModeEnabled must be a boolean',
          });
        }
      }
      if (json.containsKey('nightModeSleepTime')) {
        final value = json['nightModeSleepTime'];
        if (value is int && value >= 0 && value < 1440) {
          await _controller.setNightModeSleepTime(value);
        } else {
          return jsonBadRequest({
            'message': 'nightModeSleepTime must be an integer 0-1439',
          });
        }
      }
      if (json.containsKey('nightModeMorningTime')) {
        final value = json['nightModeMorningTime'];
        if (value is int && value >= 0 && value < 1440) {
          await _controller.setNightModeMorningTime(value);
        } else {
          return jsonBadRequest({
            'message': 'nightModeMorningTime must be an integer 0-1439',
          });
        }
      }
      if (json.containsKey('lowBatteryBrightnessLimit')) {
        final value = json['lowBatteryBrightnessLimit'];
        if (value is bool) {
          await _controller.setLowBatteryBrightnessLimit(value);
        } else {
          return jsonBadRequest({
            'message': 'lowBatteryBrightnessLimit must be a boolean',
          });
        }
      }
      if (json.containsKey('keepAwake')) {
        final value = json['keepAwake'];
        if (value is bool) {
          await _controller.setKeepAwake(value);
        } else {
          return jsonBadRequest({'message': 'keepAwake must be a boolean'});
        }
      }
      if (json.containsKey('simulatedDevices')) {
        final value = json['simulatedDevices'];
        if (value is! List) {
          return jsonBadRequest({'message': 'simulatedDevices must be a list'});
        }
        final devices = <SimulatedDevicesTypes>{};
        for (final item in value) {
          if (item is! String) {
            return jsonBadRequest({
              'message': 'Invalid simulated device type: $item',
            });
          }
          final type = SimulatedDevicesTypesFromString.fromString(item);
          if (type == null) {
            return jsonBadRequest({
              'message': 'Invalid simulated device type: $item',
            });
          }
          devices.add(type);
        }
        await _controller.setSimulatedDevices(devices);
      }
      if (json.containsKey('themeMode')) {
        final value = json['themeMode'];
        if (value is! String) {
          return jsonBadRequest({'message': 'themeMode must be a string'});
        }
        final mode = ThemeMode.values.where((e) => e.name == value).firstOrNull;
        if (mode == null) {
          return jsonBadRequest({
            'message':
                'Invalid theme mode: $value. Valid values: system, light, dark',
          });
        }
        await _controller.updateThemeMode(mode);
      }
      return jsonOk(null);
    });

    app.get('/ws/v1/logs', _handleLogsRequest);
  }

  Future<Response> _handleLogsRequest(Request req) async {
    return admittedWebSocketHandler((
      WebSocketChannel socket,
      String? protocol,
    ) {
      StreamSubscription? sub;
      sub = Logger.root.onRecord.listen((logRecord) {
        socket.sink.add(
          jsonEncode({
            'level': logRecord.level.name,
            'timestamp': logRecord.time.toIso8601String(),
            'name': logRecord.loggerName,
            'message': logRecord.message,
          }),
        );
      });
      socket.stream.listen(
        (msg) {},
        onDone: () {
          sub?.cancel();
        },
        onError: (e, _) {
          sub?.cancel();
        },
      );
    })(req);
  }
}
