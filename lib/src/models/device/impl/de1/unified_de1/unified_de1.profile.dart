part of 'unified_de1.dart';

/// Bengle firmware (BLE protocol v2) supports flow rates up to 20 ml/s,
/// versus the DE1's 8 ml/s. de1plus raises `max_flowrate` to 20 when
/// `use_ble_v2` is negotiated (`de1_de1.tcl:778-782`). reaprime is headless
/// — there is no UI slider to bound a flow input — so the profile encoder
/// is the enforcement point for this ceiling.
const double _bengleMaxFlowMlPerSec = 20.0;

extension UnifiedDe1Profile on UnifiedDe1 {
  Future<void> _sendProfile(Profile profile) async {
    await _writeHeader(profile);
    await _writeSteps(profile);
    await _writeTail(profile);
    await _writeMMRInt(MMRItem.tankTemp, profile.tankTemperature.round());
  }

  /// Encode a flow (ml/s) or pressure (bar) profile field to its wire byte,
  /// honouring the negotiated protocol version.
  ///
  /// A Bengle decodes these as **U8D1** (`byte × 0.1`, range 0..25.5); a DE1
  /// uses **U8P4** (`byte / 16`, range 0..15.9375). Encoding a v2 value with
  /// the v1 scale silently mis-commands the machine (`6 ml/s` written as the
  /// v1 `96` reads back as `9.6` on a Bengle). Only the Bengle U8D1 path clamps
  /// (to 0..25.5); the DE1 U8P4 path is unchanged from stock reaprime and wraps
  /// mod-256 above 15.9375 — harmless in practice, as DE1 flow/pressure stays
  /// well within range. Mirrors de1plus `convert_float_to_flow_pressure_byte`
  /// (`binary.tcl`).
  int _encodeFlowPressure(double value) => isBengle
      ? Helper.convert_float_to_U8D1(value)
      : (0.5 + value * 16.0).toInt();

  /// True iff [step] is a HOLD step that carries an ext HOLD Mode byte (3/4/5).
  /// Pressure/flow/power steps honour `transition:hold`; a LEVER step never
  /// does (the editor forces JUMP on lever), so a `hold` marker on a lever step
  /// is treated as a plain lever (Mode 2), NOT HOLD.
  bool _isHoldStep(ProfileStep step) =>
      step.transition == TransitionType.hold && step is! ProfileStepLever;

  Future<void> _writeHeader(Profile profile) async {
    final scale = isBengle ? 10.0 : 16.0;

    Uint8List data = Uint8List(5);

    int index = 0;
    data[index] = isBengle ? 2 : 1;
    index++;
    data[index] = profile.steps.length;
    index++;
    data[index] = profile.targetVolumeCountStart;
    index++;
    data[index] = 0;
    index++;
    data[index] = (0.5 + 12.0 * scale).toInt();

    await _transport.writeWithResponse(Endpoint.headerWrite, data);
  }

  Future<void> _writeSteps(Profile profile) async {
    final scale = isBengle ? 10.0 : 16.0;

    for (var i = 0; i < profile.steps.length; i++) {
      var step = profile.steps[i];
      _log.fine("encoding step ${step.name}");
      _log.fine("limiter: ${step.limiter?.toJson()}");
      _log.fine("exit: ${step.exit?.toJson()}");
      Uint8List data = Uint8List(8);

      int index = 0;
      data[index] = i;
      index++;
      data[index] = Helper.convertProfileFlags(step);
      index++;
      // SetVal: the target flow (ml/s) or pressure (bar). U8D1 on a
      // Bengle, U8P4 on a DE1. A flow-priority target is clamped to the Bengle
      // 20 ml/s ceiling first (pressure targets ride the U8D1 0..25.5 clamp).
      double setVal = step.getTarget();
      // A HOLD step has NO authored target — the firmware latches the previous
      // step's achieved value at frame entry. Its base-frame SetVal is pinned to
      // 0 so that on firmware without the HOLD modes, the ext `Mode>=3` legacy
      // fallback runs this base frame as a benign vent/pause rather than a stale
      // target. LEVER never takes HOLD (editor forces JUMP), so a lever step's
      // `hold` transition keeps its P0 SetVal.
      if (_isHoldStep(step)) {
        setVal = 0.0;
      }
      if (isBengle &&
          step is ProfileStepFlow &&
          setVal > _bengleMaxFlowMlPerSec) {
        setVal = _bengleMaxFlowMlPerSec;
      }
      data[index] = _encodeFlowPressure(setVal);
      index++;
      data[index] = (0.5 + step.temperature * 2.0).toInt();
      index++;
      data[index] = Helper.convert_float_to_F8_1_7(step.seconds);
      index++;
      data[index] = (0.5 + (step.exit?.value ?? 0) * scale).toInt();
      index++;
      Helper.convert_float_to_U10P0(step.volume, data, index);

      await _transport.writeWithResponse(Endpoint.frameWrite, data);
    }

    for (var i = 0; i < profile.steps.length; i++) {
      var step = profile.steps[i];
      int stepIndex = 32 + i;
      Uint8List data = Uint8List(8);

      data[0] = stepIndex;

      // A HOLD step ALWAYS emits an ext frame carrying its dedicated HOLD Mode
      // byte (3=pressure, 4=flow, 5=power) — even a plain pressure/flow step
      // with no limiter, which the legacy limiter-null branch below would
      // otherwise skip. The Mode byte is HOLD's own marker (NOT the base
      // interpolate bit): firmware without the HOLD modes runs any Mode>=3
      // through its existing legacy fallback (the benign base frame), which is
      // HOLD's safe-degrade. These modes assume Bengle protocol v2, so refuse to
      // encode one for a DE1 (the arm-time gate blocks this earlier; this is the
      // wire-boundary belt-and-suspenders). Checked BEFORE the Power/Lever
      // branch so a HOLD-power step emits Mode 5, not Mode 1.
      if (_isHoldStep(step)) {
        if (!isBengle) {
          throw StateError(
            'The HOLD transition requires Bengle firmware (protocol v2); '
            'refusing to encode step "${step.name}" for a DE1.',
          );
        }
        if (step is ProfileStepPressure) {
          // HOLD-pressure (Mode 3): pass the optional flow limiter through
          // data[1]/[2] (else 0/0); MaxFlow stays live over the held pressure.
          final limiter = step.limiter;
          final hasFlowCap = limiter != null && limiter.value != 0;
          data[1] = hasFlowCap ? _encodeFlowPressure(limiter.value) : 0;
          data[2] = hasFlowCap ? _encodeFlowPressure(limiter.range) : 0;
          data[3] = 3; // Mode = HOLD-pressure
          data[4] = 0;
          data[5] = 0;
          data[6] = 0;
          data[7] = 0;
        } else if (step is ProfileStepFlow) {
          // HOLD-flow (Mode 4): pass the optional pressure limiter through
          // data[1]/[2] (else 0/0); MaxPressure stays live over the held flow.
          final limiter = step.limiter;
          final hasPressureCap = limiter != null && limiter.value != 0;
          data[1] = hasPressureCap ? _encodeFlowPressure(limiter.value) : 0;
          data[2] = hasPressureCap ? _encodeFlowPressure(limiter.range) : 0;
          data[3] = 4; // Mode = HOLD-flow
          data[4] = 0;
          data[5] = 0;
          data[6] = 0;
          data[7] = 0;
        } else if (step is ProfileStepPower) {
          // HOLD-power (Mode 5): mandatory pressure cap in data[4] (identical
          // to Power). fromJson guarantees the limiter, but never emit a HOLD
          // Mode-5 frame without its cap.
          final limiter = step.limiter;
          if (limiter == null || limiter.value == 0) {
            throw StateError(
              'HOLD power step "${step.name}" requires a pressure limiter',
            );
          }
          data[1] = 0;
          data[2] = 0;
          data[3] = 5; // Mode = HOLD-power
          data[4] = _encodeFlowPressure(limiter.value); // ModeMaxP cap
          data[5] = 0;
          data[6] = 0;
          data[7] = 0;
        }

        await _transport.writeWithResponse(Endpoint.frameWrite, data);
        continue;
      }

      // Power/Lever steps ALWAYS emit an ext frame carrying the mode + shaper
      // params — the limiter-null skip below must NOT apply to them. These modes
      // assume Bengle protocol v2 (the base-frame U8D1 SetVal reinterpreted as
      // watts / P0), so they cannot exist on a DE1: refuse to encode one (the
      // refusal gate blocks this earlier; this is the belt-and-suspenders at the
      // wire boundary).
      if (step is ProfileStepPower || step is ProfileStepLever) {
        if (!isBengle) {
          throw StateError(
            'Power/Lever pump modes require Bengle firmware (protocol v2); '
            'refusing to encode step "${step.name}" for a DE1.',
          );
        }
        if (step is ProfileStepPower) {
          final limiter = step.limiter;
          if (limiter == null || limiter.value == 0) {
            // fromJson guarantees this, but never emit a Mode-1 frame without
            // its mandatory over-pressure cap.
            throw StateError(
              'power step "${step.name}" requires a pressure limiter',
            );
          }
          // data[1]/[2]: no flow cap for Power.
          data[1] = 0;
          data[2] = 0;
          data[3] = 1; // Mode = Power
          data[4] = _encodeFlowPressure(limiter.value); // ModeMaxP = cap
          data[5] = 0; // LeverSpring n/a
          data[6] = 0; // LeverGive n/a
          data[7] = 0;
        } else if (step is ProfileStepLever) {
          // data[1]/[2]: optional flow cap (stock max-flow machinery), else 0/0.
          final limiter = step.limiter;
          final hasFlowCap = limiter != null && limiter.value != 0;
          data[1] = hasFlowCap ? _encodeFlowPressure(limiter.value) : 0;
          data[2] = hasFlowCap ? _encodeFlowPressure(limiter.range) : 0;
          data[3] = 2; // Mode = Lever
          // ModeMaxP = P0 — byte-identical to this step's base-frame SetVal
          // (getTarget() == pressure, no flow clamp on a non-flow step).
          data[4] = _encodeFlowPressure(step.getTarget());
          // k_V and R_s are always U8D1 (Bengle-native, gated to Bengle above).
          data[5] = Helper.convert_float_to_U8D1(step.leverSpring);
          data[6] = Helper.convert_float_to_U8D1(step.leverGive);
          data[7] = 0;
        }

        await _transport.writeWithResponse(Endpoint.frameWrite, data);
        continue;
      }

      if (step.limiter == null || step.limiter?.value == 0) {
        continue;
      }
      double limiterValue = step.limiter!.value;
      double limiterRange = step.limiter!.range;

      data[1] = (0.5 + limiterValue * scale).toInt();
      data[2] = (0.5 + limiterRange * scale).toInt();

      data[3] = 0;
      data[4] = 0;
      data[5] = 0;
      data[6] = 0;
      data[7] = 0;

      await _transport.writeWithResponse(Endpoint.frameWrite, data);
    }
  }

  Future<void> _writeTail(Profile profile) async {
    Uint8List data = Uint8List(8);

    data[0] = profile.steps.length;

    data[3] = 0;
    data[4] = 0;
    data[5] = 0;
    data[6] = 0;
    data[7] = 0;
    await _transport.writeWithResponse(Endpoint.frameWrite, data);
  }
}

class Helper {
  // ignore: non_constant_identifier_names
  static double convert_F8_1_7_to_float(int x) {
    if ((x & 128) == 0) {
      return x / 10.0;
    } else {
      return (x & 127).toDouble();
    }
  }

  /// U8D1: unsigned byte, scale ×0.1 (range 0..25.5, step 0.1) — the Bengle
  /// (BLE protocol v2) flow/pressure encoding. Clamps to the byte range so
  /// out-of-range values saturate instead of wrapping. Uses round-half-up (to
  /// match the `+ 0.5` truncation the v1 path uses). Mirrors de1plus
  /// `convert_float_to_U8D1` (`binary.tcl`).
  // ignore: non_constant_identifier_names
  static int convert_float_to_U8D1(double x) {
    final clamped = x < 0.0 ? 0.0 : (x > 25.5 ? 25.5 : x);
    return (clamped * 10).round();
  }

  // ignore: non_constant_identifier_names
  static int convert_float_to_F8_1_7(double x) {
    if (x == 0) {
      return 0;
    }
    var ret = 0;
    if (x >= 12.75) {
      if (x > 127) {
        ret = (127 | 0x80);
      } else {
        ret = (0x80 | (0.5 + x).toInt());
      }
    } else {
      ret = (0.5 + x * 10).toInt();
    }
    return ret;
  }

  // ignore: non_constant_identifier_names
  static void convert_float_to_U10P0_for_tail(
    double maxTotalVolume,
    Uint8List data,
    int index,
  ) {
    if (maxTotalVolume == 0) {
      return;
    }
    int ix = maxTotalVolume.toInt();

    if (ix > 1023) {
      ix = 1023;
    }
    data[index] = ix >> 8;
    data[index + 1] = (ix & 0xff);
  }

  // ignore: non_constant_identifier_names
  static double convert_bottom_10_of_U10P0(int x) {
    return (x & 1023).toDouble();
  }

  // ignore: non_constant_identifier_names
  static void convert_float_to_U10P0(double x, Uint8List data, int index) {
    Uint8List d = Uint8List(2);

    int ix = x.toInt() | 1024;
    d.buffer.asByteData().setInt16(0, ix);

    data[index] = d.buffer.asByteData().getUint8(0);
    data[index + 1] = d.buffer.asByteData().getUint8(1);
  }

  static int ctrlF = 0x01;
  // ignore: constant_identifier_names
  static int doCompare = 0x02;
  // ignore: constant_identifier_names
  static int dcGT = 0x04;
  // ignore: constant_identifier_names
  static int dcCompF = 0x08;
  // ignore: constant_identifier_names
  static int tMixTemp = 0x10;
  // ignore: constant_identifier_names
  static int interpolate = 0x20;
  // ignore: constant_identifier_names
  static int ignoreLimit = 0x40;
  // ignore: constant_identifier_names
  static int comparePower =
      0x80; // Exit when measured hydraulic power (0.1*P*F) crosses TriggerVal

  static int convertProfileFlags(ProfileStep step) {
    int flag = ignoreLimit;

    if (step is ProfileStepFlow) flag |= ctrlF;
    if (step.sensor == TemperatureSensor.water) flag |= tMixTemp;
    // ONLY `smooth` sets the interpolate/ramp bit. `hold` deliberately leaves
    // the base frame a JUMP: HOLD is carried by its own ext Mode byte, and the
    // base frame is the benign legacy-fallback frame that runs on firmware
    // without the HOLD modes.
    if (step.transition == TransitionType.smooth) flag |= interpolate;

    if (step.exit != null) {
      if (step.exit!.type == ExitType.power) {
        // A power exit uses the independent comparePower bit and deliberately
        // does NOT set doCompare or dcCompF: firmware/apps that predate the
        // power exit gate the pressure/flow compare block on doCompare, so with
        // doCompare clear they skip that block entirely and run the frame to its
        // time/volume limits (a benign base frame) rather than comparing a
        // watts TriggerVal against pressure/flow and exiting at the wrong time.
        // over/under still ride dcGT; TriggerVal (data[5]) is U8D1 watts.
        flag |= comparePower;
        if (step.exit!.condition == ExitCondition.over) flag |= dcGT;
      } else {
        flag |= doCompare;
        if (step.exit!.type == ExitType.flow) flag |= dcCompF;
        if (step.exit!.condition == ExitCondition.over) flag |= dcGT;
      }
    }

    return flag;
  }
}
