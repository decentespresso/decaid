part of 'unified_de1.dart';

extension UnifiedDe1Profile on UnifiedDe1 {
  Future<void> _sendProfile(Profile profile) async {
    await _writeHeader(profile);
    await _writeSteps(profile);
    await _writeTail(profile);
    // The tank temperature threshold is a separate MMR (MMRItem.tankTemp), not
    // part of the profile frames — frames go via frameWrite, and there is no
    // MMR for steps. The DE1 expects the tank threshold to be written
    // alongside a profile load; mirror de1app's `de1_send_shot_frames`, which
    // writes the frames then `set_tank_temperature_threshold`
    // (de1_comms.tcl:1505-1514). Writing it on every profile load means the
    // next brew re-sets it from its own tankTemperature, so the cold-maintenance
    // workaround (which loads a tankTemperature:0 profile) needs no separate
    // set-to-0 or restore.
    await _writeMMRInt(MMRItem.tankTemp, profile.tankTemperature.round());
  }

  Future<void> _writeHeader(Profile profile) async {
    final isBengle = implementation == DeviceImplementation.bengle;
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
    final isBengle = implementation == DeviceImplementation.bengle;
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
      data[index] = (0.5 + step.getTarget() * scale).toInt();
      index++; // note to add 0.5, as "round" is used, not truncate
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

    // Ignore writing shot vol limit, it's not compatible with active scale and breaks with high PI flows.
    // Helper.convert_float_to_U10P0_for_tail(profile.targetVolume ?? 0, data, 1);

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
    // there is a mismatch between docs and actual implementation in the firmware
    // instead 0f 0x8000 for ignorePI, 0x400 sets PI counting to enabled.
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

    // if (ix > 255) {
    //   ix = 255;
    // }

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

  static int convertProfileFlags(ProfileStep step) {
    // TODO: maybe don't ignore this if we need to reach high flow values?
    int flag = ignoreLimit;

    if (step is ProfileStepFlow) flag |= ctrlF;
    if (step.sensor == TemperatureSensor.water) flag |= tMixTemp;
    if (step.transition == TransitionType.smooth) flag |= interpolate;

    if (step.exit != null) {
      flag |= doCompare;

      if (step.exit!.type == ExitType.flow) flag |= dcCompF;
      if (step.exit!.condition == ExitCondition.over) flag |= dcGT;
    }

    return flag;
  }
}
