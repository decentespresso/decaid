part of '../webserver_service.dart';

class De1Handler {
  final SettingsController _settingsController;
  final De1Controller _controller;
  final ScaleController _scaleController;
  final WorkflowController _workflowController;
  final log = Logger("De1WebHandler");

  De1Handler({
    required De1Controller controller,
    required SettingsController settingsController,
    required ScaleController scaleController,
    required WorkflowController workflowController,
  }) : _controller = controller,
       _settingsController = settingsController,
       _scaleController = scaleController,
       _workflowController = workflowController;

  void addRoutes(RouterPlus app) {
    app.get('/api/v1/machine/info', _infoHandler);
    app.get('/api/v1/machine/state', _stateHandler);
    app.put('/api/v1/machine/state/<newState>', _requestStateHandler);
    app.post('/api/v1/machine/profile', _profileHandler);
    app.options('/api/v1/machine/profile', (Request r) {
      return Response.ok(
        '',
        headers: {
          'Access-Control-Allow-Origin': '*',
          'Access-Control-Allow-Methods': 'GET, POST, OPTIONS',
          'Access-Control-Allow-Headers':
              'Origin, Content-Type, Accept, Authorization',
        },
      );
    });
    app.post('/api/v1/machine/shotSettings', _shotSettingsHandler);

    app.get('/api/v1/machine/capabilities', (Request _) async {
      return withDe1((de1) async {
        final caps = <String>[];
        if (de1 is BengleInterface) {
          caps.addAll([
            'cupWarmer',
            'integratedScale',
            'stopAtWeight',
            'ledStrip',
            'scaleCalibration',
            'preheat',
            'wakeSchedule',
          ]);
        }
        return jsonOk({'capabilities': caps});
      });
    });

    app.get('/api/v1/machine/cupWarmer', (Request _) async {
      return withDe1((de1) async {
        final gate = _bengleFirmwareGate(de1, 'cupWarmer');
        if (gate != null) return gate;
        final bengle = de1 as BengleInterface;
        final t = await bengle.getCupWarmerTemperature();
        return jsonOk({
          'temperature': t.toInt(),
          'enabled': await bengle.getCupWarmerEnabled(),
          'currentTemperature': await bengle.getCupWarmerCurrentTemperature(),
        });
      });
    });

    app.put('/api/v1/machine/cupWarmer', (Request r) async {
      final dynamic json;
      try {
        json = jsonDecode(await r.readAsString());
      } catch (e) {
        return jsonBadRequest({'error': 'Invalid JSON body'});
      }
      if (json is! Map) {
        return jsonBadRequest({'error': 'invalid JSON body'});
      }
      final hasTemperature = json.containsKey('temperature');
      final hasEnabled = json.containsKey('enabled');
      if (!hasTemperature && !hasEnabled) {
        return jsonBadRequest({'error': 'temperature and/or enabled required'});
      }
      if (hasTemperature) {
        final temperature = json['temperature'];
        if (temperature is! num ||
            !temperature.isFinite ||
            temperature < 0 ||
            temperature > 80 ||
            temperature != temperature.truncate()) {
          return jsonBadRequest({
            'error': 'temperature must be a whole degree from 0 to 80',
          });
        }
      }
      if (hasEnabled && json['enabled'] is! bool) {
        return jsonBadRequest({'error': 'enabled must be a boolean'});
      }
      final temperature = hasTemperature
          ? (json['temperature'] as num).toDouble()
          : null;
      final enabled = hasEnabled ? json['enabled'] as bool : null;
      return withQueuedDe1((de1) async {
        final gate = _bengleFirmwareGate(de1, 'cupWarmer');
        if (gate != null) return gate;
        final bengle = de1 as BengleInterface;
        if (temperature != null) {
          await bengle.setCupWarmerTemperature(temperature);
        }
        if (enabled != null) {
          await bengle.setCupWarmerEnabled(enabled);
        } else if (temperature != null) {
          await bengle.setCupWarmerEnabled(true);
        }
        return jsonOk({'status': 'accepted'});
      }, retryOnReplacement: true);
    });

    app.get('/api/v1/machine/cupWarmer/preheat', (Request _) async {
      return withDe1((de1) async {
        final gate = _bengleFirmwareGate(de1, 'cupWarmer/preheat');
        if (gate != null) return gate;
        final state = await (de1 as BengleInterface).getCupWarmerPreheatState();
        return jsonOk(state.toJson());
      });
    });

    app.put('/api/v1/machine/cupWarmer/preheat', (Request r) async {
      final dynamic json;
      try {
        json = jsonDecode(await r.readAsString());
      } catch (e) {
        return jsonBadRequest({'error': 'Invalid JSON body'});
      }
      if (json is! Map) {
        return jsonBadRequest({'error': 'invalid JSON body'});
      }
      final hasEnabled = json.containsKey('enabled');
      final hasLead = json.containsKey('leadMinutes');
      if (!hasEnabled && !hasLead) {
        return jsonBadRequest({'error': 'enabled and/or leadMinutes required'});
      }
      if (hasEnabled && json['enabled'] is! bool) {
        return jsonBadRequest({'error': 'enabled must be a boolean'});
      }
      if (hasLead) {
        final lead = json['leadMinutes'];
        if (lead is! num ||
            !lead.isFinite ||
            lead != lead.truncate() ||
            lead < 0 ||
            lead > 120) {
          return jsonBadRequest({
            'error': 'leadMinutes must be a whole minute from 0 to 120',
          });
        }
      }
      final enabled = hasEnabled ? json['enabled'] as bool : null;
      final lead = hasLead ? (json['leadMinutes'] as num).toInt() : null;
      return withQueuedDe1((de1) async {
        final gate = _bengleFirmwareGate(de1, 'cupWarmer/preheat');
        if (gate != null) return gate;
        final bengle = de1 as BengleInterface;
        final current = await bengle.getCupWarmerPreheatState();
        await bengle.setCupWarmerPreheat(
          enabled: enabled ?? current.enabled,
          leadMinutes: lead ?? current.leadMinutes,
        );
        return jsonOk({'status': 'accepted'});
      }, retryOnReplacement: true);
    });

    app.get('/ws/v1/machine/snapshot', sws.webSocketHandler(_handleSnapshot));
    app.get(
      '/ws/v1/machine/shotSettings',
      sws.webSocketHandler(_handleShotSettings),
    );
    app.get(
      '/ws/v1/machine/waterLevels',
      sws.webSocketHandler(_handleWaterLevels),
    );
    app.get('/ws/v1/machine/raw', sws.webSocketHandler(_handleRawSocket));
    app.get('/ws/v1/machine/shotState', sws.webSocketHandler(_handleShotState));

    app.get('/api/v1/machine/ledStrip', (Request _) async {
      return withDe1((de1) async {
        final gate = _bengleFirmwareGate(de1, 'ledStrip');
        if (gate != null) return gate;
        final state = await (de1 as BengleInterface).getLedStripState();
        if (state == null) {
          return jsonServiceUnavailable({
            'error':
                'ledStrip state unavailable (hydration failed or not '
                'yet complete)',
          });
        }
        return jsonOk(state.toJson());
      });
    });

    app.put('/api/v1/machine/ledStrip', (Request r) async {
      final dynamic json;
      try {
        json = jsonDecode(await r.readAsString());
      } catch (e) {
        return jsonBadRequest({'error': 'Invalid JSON body'});
      }
      if (json is! Map) {
        return jsonBadRequest({'error': 'invalid JSON body'});
      }
      final state = LedStripState.fromJson(json as Map<String, dynamic>);
      return withQueuedDe1((de1) async {
        final gate = _bengleFirmwareGate(de1, 'ledStrip');
        if (gate != null) return gate;
        await (de1 as BengleInterface).setLedStrip(state);
        return jsonOk({'status': 'accepted'});
      }, retryOnReplacement: true);
    });

    app.post('/api/v1/machine/ledStrip/commit', (Request _) async {
      return withQueuedDe1((de1) async {
        final gate = _bengleFirmwareGate(de1, 'ledStrip');
        if (gate != null) return gate;
        await (de1 as BengleInterface).commitLedStrip();
        return jsonAccepted();
      }, retryOnReplacement: true);
    });

    app.post('/api/v1/machine/ledStrip/reset', (Request _) async {
      return withQueuedDe1((de1) async {
        final gate = _bengleFirmwareGate(de1, 'ledStrip');
        if (gate != null) return gate;
        final state = await (de1 as BengleInterface).resetLedStrip();
        if (state == null) {
          return jsonServiceUnavailable({
            'error': 'ledStrip state unavailable (firmware read failed)',
          });
        }
        return jsonOk(state.toJson());
      }, retryOnReplacement: true);
    });

    app.get('/api/v1/machine/scaleCalibration', (Request _) async {
      return withDe1((de1) async {
        final gate = _bengleFirmwareGate(de1, 'scaleCalibration');
        if (gate != null) return gate;
        final state = await (de1 as BengleInterface).getScaleCalibrationState();
        return jsonOk(state.toJson());
      });
    });

    app.put('/api/v1/machine/scaleCalibration', (Request r) async {
      final dynamic json;
      try {
        json = jsonDecode(await r.readAsString());
      } catch (e) {
        return jsonBadRequest({'error': 'Invalid JSON body'});
      }
      if (json is! Map || json['command'] == null) {
        return jsonBadRequest({'error': 'command required'});
      }
      final ScaleCalibrationCommand command;
      switch (json['command']) {
        case 'abort':
          command = ScaleCalibrationCommand.abort;
        case 'zero':
          command = ScaleCalibrationCommand.zero;
        case 'latch':
          command = ScaleCalibrationCommand.latch;
        default:
          return jsonBadRequest({
            'error': 'command must be one of abort, zero, latch',
          });
      }
      double? weightGrams;
      if (command == ScaleCalibrationCommand.latch) {
        final weight = json['weightGrams'];
        if (weight is! num || !weight.isFinite) {
          return jsonBadRequest({'error': 'weightGrams required for latch'});
        }
        weightGrams = weight.toDouble();
        if (weightGrams < 1 || weightGrams > 10000) {
          return jsonBadRequest({
            'error': 'weightGrams must be 1..10000 grams',
          });
        }
      }
      return withQueuedDe1((de1) async {
        final gate = _bengleFirmwareGate(de1, 'scaleCalibration');
        if (gate != null) return gate;
        final bengle = de1 as BengleInterface;
        final accepted = await bengle.startScaleCalibration(
          command,
          weightGrams: weightGrams,
        );
        final state = await bengle.getScaleCalibrationState();
        if (accepted) {
          return jsonAccepted({'status': 'accepted', 'state': state.toJson()});
        }
        return jsonConflict({
          'status': 'rejected',
          'reason': 'machine busy or shot in progress',
          'state': state.toJson(),
        });
      }, retryOnReplacement: true);
    });

    app.post('/api/v1/machine/waterLevels', (Request r) async {
      final dynamic json;
      try {
        json = jsonDecode(await r.readAsString());
      } catch (e) {
        return jsonBadRequest({'error': 'Invalid JSON body'});
      }
      if (json is! Map) {
        return jsonBadRequest({'error': 'Request body must be a JSON object'});
      }
      final refillLevel = json['refillLevel'] == null
          ? null
          : (json['refillLevel'] as num).toInt();
      return withQueuedDe1((de1) async {
        if (refillLevel != null) {
          await de1.setRefillLevel(refillLevel);
        }
        return jsonAccepted();
      }, retryOnReplacement: true);
    });

    app.post('/api/v1/machine/settings', (Request r) async {
      final dynamic json;
      try {
        json = jsonDecode(await r.readAsString());
      } catch (e) {
        return jsonBadRequest({'error': 'Invalid JSON body'});
      }
      if (json is! Map<String, dynamic>) {
        return jsonBadRequest({'error': 'Request body must be a JSON object'});
      }
      log.info("have: $json");
      final usb = json['usb'] == null ? null : json['usb'] == 'enable';
      final fan = json['fan'] == null ? null : parseInt(json['fan']);
      final flushTemp = json['flushTemp'] == null
          ? null
          : parseDouble(json['flushTemp']);
      final flushFlow = json['flushFlow'] == null
          ? null
          : parseDouble(json['flushFlow']);
      final flushTimeout = json['flushTimeout'] == null
          ? null
          : parseDouble(json['flushTimeout']);
      final hotWaterFlow = json['hotWaterFlow'] == null
          ? null
          : parseDouble(json['hotWaterFlow']);
      final steamFlow = json['steamFlow'] == null
          ? null
          : parseDouble(json['steamFlow']);
      final tankTemp = json['tankTemp'] == null
          ? null
          : parseInt(json['tankTemp']);
      final steamPurgeMode = json['steamPurgeMode'] == null
          ? null
          : parseInt(json['steamPurgeMode']);

      return _mapDe1WriteErrors(() async {
        await _controller.updateMachineSettings(
          usb: usb,
          fan: fan,
          flushTemp: flushTemp,
          flushFlow: flushFlow,
          flushTimeout: flushTimeout,
          hotWaterFlow: hotWaterFlow,
          steamFlow: steamFlow,
          tankTemp: tankTemp,
          steamPurgeMode: steamPurgeMode,
        );
        return jsonAccepted();
      });
    });

    app.get('/api/v1/machine/settings', () async {
      return withDe1((de1) async {
        var json = <String, dynamic>{};
        json['fan'] = await de1.getFanThreshhold();
        json['usb'] = await de1.getUsbChargerMode();
        json['flushTemp'] = await de1.getFlushTemperature();
        json['flushTimeout'] = await de1.getFlushTimeout();
        json['flushFlow'] = await de1.getFlushFlow();
        json['hotWaterFlow'] = await de1.getHotWaterFlow();
        json['steamFlow'] = await de1.getSteamFlow();
        json['tankTemp'] = await de1.getTankTempThreshold();
        json['steamPurgeMode'] = await de1.getSteamPurgeMode();
        return jsonOk(json);
      });
    });

    app.post('/api/v1/machine/settings/advanced', (Request r) async {
      final dynamic json;
      try {
        json = jsonDecode(await r.readAsString());
      } catch (e) {
        return jsonBadRequest({'error': 'Invalid JSON body'});
      }
      if (json is! Map<String, dynamic>) {
        return jsonBadRequest({'error': 'Request body must be a JSON object'});
      }
      final heaterPh1Flow = json['heaterPh1Flow'] == null
          ? null
          : parseDouble(json['heaterPh1Flow']);
      final heaterPh2Flow = json['heaterPh2Flow'] == null
          ? null
          : parseDouble(json['heaterPh2Flow']);
      final heaterIdleTemp = json['heaterIdleTemp'] == null
          ? null
          : parseDouble(json['heaterIdleTemp']);
      final heaterPh2Timeout = json['heaterPh2Timeout'] == null
          ? null
          : parseDouble(json['heaterPh2Timeout']);
      final heaterVoltage = json['heaterVoltage'] == null
          ? null
          : De1HeaterVoltage.fromInt(parseInt(json['heaterVoltage']));
      final refillKitSetting = json['refillKitSetting'] == null
          ? null
          : De1RefillKitSettings.values.firstWhere(
              (e) => e.hex == parseInt(json['refillKitSetting']),
            );

      return withQueuedDe1((de1) async {
        if (heaterPh1Flow != null) {
          await de1.setHeaterPhase1Flow(heaterPh1Flow);
        }
        if (heaterPh2Flow != null) {
          await de1.setHeaterPhase2Flow(heaterPh2Flow);
        }
        if (heaterIdleTemp != null) {
          await de1.setHeaterIdleTemp(heaterIdleTemp);
        }
        if (heaterPh2Timeout != null) {
          await de1.setHeaterPhase2Timeout(heaterPh2Timeout);
        }
        if (heaterVoltage != null) {
          await de1.setHeaterVoltage(heaterVoltage);
        }
        if (refillKitSetting != null) {
          await de1.setRefillKitSettings(refillKitSetting);
        }
        return jsonAccepted();
      }, retryOnReplacement: true);
    });

    app.get('/api/v1/machine/settings/advanced', () async {
      return withDe1((de1) async {
        var json = <String, dynamic>{};
        json['heaterPh1Flow'] = await de1.getHeaterPhase1Flow();
        json['heaterPh2Flow'] = await de1.getHeaterPhase2Flow();
        json['heaterIdleTemp'] = await de1.getHeaterIdleTemp();
        json['heaterPh2Timeout'] = await de1.getHeaterPhase2Timeout();
        json['heaterVoltage'] = (await de1.getHeaterVoltage()).voltage;
        json['refillKitSetting'] = (await de1.getRefillKitSettings()).hex;
        return jsonOk(json);
      });
    });

    app.get('/api/v1/machine/calibration', () async {
      return withDe1((de1) async {
        var json = <String, dynamic>{};
        json['flowMultiplier'] = await de1.getFlowEstimation();
        return jsonOk(json);
      });
    });

    app.post('/api/v1/machine/calibration', (Request r) async {
      final dynamic json;
      try {
        json = jsonDecode(await r.readAsString());
      } catch (e) {
        return jsonBadRequest({'error': 'Invalid JSON body'});
      }
      if (json is! Map) {
        return jsonBadRequest({'error': 'Request body must be a JSON object'});
      }
      final flowMultiplier = json['flowMultiplier'] == null
          ? null
          : parseDouble(json['flowMultiplier']);
      return withQueuedDe1((de1) async {
        if (flowMultiplier != null) {
          await de1.setFlowEstimation(flowMultiplier);
        }
        return jsonAccepted();
      }, retryOnReplacement: true);
    });

    app.delete('/api/v1/machine/settings/reset', (Request r) async {
      return _mapDe1WriteErrors(() async {
        await _controller.runDeviceWrite(
          (device) => _controller.applySettingsDefaults(device),
          retryOnReplacement: true,
        );
        return jsonAccepted();
      });
    });
  }

  Future<Response> withDe1(Future<Response> Function(De1Interface) call) async {
    try {
      var de1 = _controller.connectedDe1();
      return await call(de1);
    } on MachineReplacementTimeoutException catch (e) {
      return jsonServiceUnavailable({
        'error': 'Machine unavailable',
        'message': '$e',
      });
    } catch (e, st) {
      return jsonError({'error': e.toString(), 'st': st.toString()});
    }
  }

  Future<Response> _mapDe1WriteErrors(Future<Response> Function() call) async {
    try {
      return await call();
    } on MachineReplacementTimeoutException catch (e) {
      return jsonServiceUnavailable({
        'error': 'Machine unavailable',
        'message': '$e',
      });
    } on DeviceNotConnectedException catch (e) {
      return jsonError({'error': e.toString()});
    } catch (e, st) {
      return jsonError({'error': e.toString(), 'st': st.toString()});
    }
  }

  Response? _bengleFirmwareGate(De1Interface de1, String feature) {
    if (de1 is! BengleInterface) {
      return jsonNotFound({'error': '$feature not supported'});
    }
    return null;
  }

  Future<Response> withQueuedDe1(
    Future<Response> Function(De1Interface device) call, {
    bool retryOnReplacement = false,
  }) {
    return _mapDe1WriteErrors(
      () => _controller.runDeviceWrite(
        call,
        retryOnReplacement: retryOnReplacement,
      ),
    );
  }

  void _withDe1Ws(
    WebSocketChannel socket,
    StreamSubscription<dynamic> Function(De1Interface de1) attach, {
    void Function(De1Interface de1, dynamic message)? onMessage,
  }) {
    final initial = _controller.connectedDe1OrNull;

    De1Interface? attached;
    StreamSubscription<dynamic>? payloadSub;
    StreamSubscription<dynamic>? de1Sub;

    void detach() {
      final sub = payloadSub;
      payloadSub = null;
      attached = null;
      sub?.cancel();
    }

    if (initial != null) {
      attached = initial;
      payloadSub = attach(initial);
    }

    de1Sub = _controller.de1.listen(
      (de1) {
        if (de1 == null) {
          if (attached != null) {
            log.info(
              'machine disconnected — detaching socket until it returns',
            );
            detach();
          }
          return;
        }
        if (identical(de1, attached)) return;
        log.info('binding socket to ${de1.name} (${de1.deviceId})');
        detach();
        attached = de1;
        payloadSub = attach(de1);
      },
      onDone: () {
        detach();
        socket.sink.close();
      },
      onError: (Object e, StackTrace st) {
        log.severe('controller stream error', e, st);
        detach();
        socket.sink.close();
      },
    );

    socket.stream.listen(
      (message) {
        final de1 = attached;
        if (onMessage == null) return;
        if (de1 == null) {
          socket.sink.add(jsonEncode({'error': 'No machine connected'}));
          return;
        }
        onMessage(de1, message);
      },
      onDone: () {
        de1Sub?.cancel();
        de1Sub = null;
        detach();
      },
      onError: (Object e, StackTrace st) {
        de1Sub?.cancel();
        de1Sub = null;
        detach();
      },
    );
  }

  Future<Response> _infoHandler(Request request) async {
    return withDe1((De1Interface de1) async {
      return jsonOk(de1.machineInfo.toJson());
    });
  }

  Future<Response> _stateHandler(Request request) async {
    return withDe1((De1Interface de1) async {
      var snapshot = await de1.currentSnapshot.first;
      return jsonOk(snapshot.toJson());
    });
  }

  Future<Response> _requestStateHandler(
    Request request,
    String newState,
  ) async {
    return withDe1((de1) async {
      var requestState = MachineState.values.byName(newState);
      final blockOnNoScale = _settingsController.blockOnNoScale;
      final scaleConnected =
          _scaleController.currentConnectionState ==
          device.ConnectionState.connected;
      final isCleaningProfile =
          _workflowController.currentWorkflow.profile.beverageType ==
          BeverageType.cleaning;
      log.fine(
        "Received request to change state to $requestState while scale connected: $scaleConnected, blockOnNoScale: $blockOnNoScale, cleaningProfile: $isCleaningProfile",
      );
      if (requestState == MachineState.espresso &&
          blockOnNoScale &&
          !scaleConnected &&
          !isCleaningProfile) {
        log.warning(
          "Blocking espresso request because no scale detected and blockOnNoScale is enabled",
        );
        return jsonBadRequest({
          'details': 'No scale detected, blocking espresso request',
          'type': 'block_no_scale',
        });
      }
      final stoppingActiveShot =
          requestState == MachineState.idle &&
          _controller.currentShotState.state != ShotState.idle;
      await de1.requestState(requestState);
      if (stoppingActiveShot) {
        _controller.recordStopIntent(ShotDecisionReason.apiStop);
      }
      return jsonOk(null);
    });
  }

  Future<Response> _profileHandler(Request request) async {
    return withDe1((_) async {
      final payload = await request.readAsString();

      Map<String, dynamic> json;
      try {
        json = jsonDecode(payload);
      } catch (e) {
        return jsonBadRequest({'error': 'Invalid JSON body'});
      }
      Profile profile = Profile.fromJson(json);
      await _controller.runDeviceWrite(
        (device) => device.setProfile(profile),
        retryOnReplacement: true,
      );
      return jsonOk(null);
    });
  }

  Future<Response> _shotSettingsHandler(Request request) async {
    return withDe1((_) async {
      final payload = await request.readAsString();

      Map<String, dynamic> json;
      try {
        json = jsonDecode(payload);
      } catch (e) {
        return jsonBadRequest({'error': 'Invalid JSON body'});
      }
      De1ShotSettings settings = De1ShotSettings.fromJson(json);
      await _controller.runDeviceWrite(
        (device) => device.updateShotSettings(settings),
        retryOnReplacement: true,
      );
      return jsonOk(null);
    });
  }

  Future<void> _handleShotState(
    WebSocketChannel socket,
    String? protocol,
  ) async {
    log.fine("handling shotState websocket connection");
    var sub = _controller.shotState.listen((event) {
      try {
        socket.sink.add(jsonEncode(event.toJson()));
      } catch (e, st) {
        log.severe("failed to send shotState event: ", e, st);
      }
    });
    socket.stream.listen(
      (e) {},
      onDone: () => sub.cancel(),
      onError: (e, st) => sub.cancel(),
    );
  }

  Future<void> _handleSnapshot(
    WebSocketChannel socket,
    String? protocol,
  ) async {
    log.fine("handling websocket connection");
    _withDe1Ws(socket, (de1) {
      return de1.currentSnapshot.listen((snapshot) {
        try {
          var json = jsonEncode(snapshot.toJson());
          socket.sink.add(json);
        } catch (e, st) {
          log.severe("failed to send: ", e, st);
        }
      });
    });
  }

  Future<void> _handleShotSettings(
    WebSocketChannel socket,
    String? protocol,
  ) async {
    log.fine('handling shot settings connection');
    _withDe1Ws(socket, (de1) {
      return de1.shotSettings.listen((data) {
        try {
          var json = jsonEncode(data.toJson());
          socket.sink.add(json);
        } catch (e, st) {
          log.severe("failed to send: ", e, st);
        }
      });
    });
  }

  Future<void> _handleWaterLevels(
    WebSocketChannel socket,
    String? protocol,
  ) async {
    log.fine('handling water levels connection');
    _withDe1Ws(socket, (de1) {
      return de1.waterLevels.listen((data) {
        try {
          var json = jsonEncode(data.toJson());
          socket.sink.add(json);
        } catch (e, st) {
          log.severe("failed to send water levels", e, st);
        }
      });
    });
  }

  Future<void> _handleRawSocket(
    WebSocketChannel socket,
    String? protocol,
  ) async {
    _withDe1Ws(
      socket,
      (de1) {
        return de1.rawOutStream.listen((data) {
          try {
            var json = jsonEncode(data.toJson());
            socket.sink.add(json);
          } catch (e) {
            log.severe("Failed to send raw: ", e);
          }
        });
      },
      onMessage: (de1, event) {
        var json = jsonDecode(event.toString());
        final message = De1RawMessage.fromJson(json);
        de1.sendRawMessage(message);
      },
    );
  }
}
