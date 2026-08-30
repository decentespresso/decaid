// ignore_for_file: constant_identifier_names

import 'package:reaprime/src/models/device/machine.dart';
import 'package:reaprime/src/models/device/impl/de1/mmr_address.dart';
import 'package:reaprime/src/models/device/transport/logical_endpoint.dart';

final String de1ServiceUUID = 'A000';

enum Endpoint implements LogicalEndpoint {
  versions('A001', 'A'),
  requestedState('A002', 'B'),
  setTime('A003', 'C'),
  shotDirectory('A004', 'D'),
  readFromMMR('A005', 'E'),
  writeToMMR('A006', 'F'),
  shotMapRequest('A007', 'G'),
  deleteShotRange('A008', 'H'),
  fwMapRequest('A009', 'I'),
  temperatures('A00A', 'J'),
  shotSettings('A00B', 'K'),
  deprecatedShotDesc('A00C', 'L'),
  shotSample('A00D', 'M'),
  stateInfo('A00E', 'N'),
  headerWrite('A00F', 'O'),
  frameWrite('A010', 'P'),
  waterLevels('A011', 'Q'),
  calibration('A012', 'R'),
  bengleShotSample('A013', 'S');

  @override
  final String uuid;
  @override
  final String representation;

  const Endpoint(this.uuid, this.representation);

  @override
  String get name => (this as Enum).name;

  static Endpoint? fromUuid(String uuid) {
    return Endpoint.values.where((e) => e.uuid == uuid).firstOrNull;
  }
}

enum De1StateEnum {
  sleep(0x0),
  goingToSleep(0x1),
  idle(0x2),
  busy(0x3),
  espresso(0x4),
  steam(0x5),
  hotWater(0x6),
  shortCal(0x7),
  selfTest(0x8),
  longCal(0x9),
  descale(0xA),
  fatalError(0xB),
  init(0xC),
  noRequest(0xD),
  skipToNext(0xE),
  hotWaterRinse(0xF),
  steamRinse(0x10),
  refill(0x11),
  clean(0x12),
  inBootLoader(0x13),
  airPurge(0x14),
  schedIdle(0x15),
  fwUpgrade(0x16),
  unknown(-1);

  final int hexValue;

  const De1StateEnum(this.hexValue);

  static De1StateEnum fromHexValue(int hex) {
    return De1StateEnum.values.firstWhere(
      (e) => e.hexValue == hex,
      orElse: () => De1StateEnum.unknown,
    );
  }

  static De1StateEnum fromMachineState(MachineState state) {
    switch (state) {
      case MachineState.idle:
        return De1StateEnum.idle;
      case MachineState.booting:
        return De1StateEnum.init;
      case MachineState.sleeping:
        return De1StateEnum.sleep;
      case MachineState.heating:
        return De1StateEnum.idle;
      case MachineState.preheating:
        return De1StateEnum.idle;
      case MachineState.espresso:
        return De1StateEnum.espresso;
      case MachineState.hotWater:
        return De1StateEnum.hotWater;
      case MachineState.flush:
        return De1StateEnum.hotWaterRinse;
      case MachineState.steam:
        return De1StateEnum.steam;
      case MachineState.skipStep:
        return De1StateEnum.skipToNext;
      case MachineState.cleaning:
        return De1StateEnum.clean;
      case MachineState.descaling:
        return De1StateEnum.descale;
      case MachineState.airPurge:
        return De1StateEnum.airPurge;
      case MachineState.needsWater:
        return De1StateEnum.refill;
      case MachineState.error:
        return De1StateEnum.fatalError;
      case MachineState.fwUpgrade:
        return De1StateEnum.fwUpgrade;
      case MachineState.busy:
        return De1StateEnum.busy;
      case MachineState.schedIdle:
        return De1StateEnum.schedIdle;
      case MachineState.steamRinse:
        return De1StateEnum.steamRinse;
      case MachineState.calibration:
        return De1StateEnum.shortCal;
      case MachineState.selfTest:
        return De1StateEnum.selfTest;
    }
  }
}

enum De1SubState {
  noState(0x00, 'No state is relevant'),
  heatWaterTank(0x01, 'Cold water is not hot enough. Heating hot water tank.'),
  heatWaterHeater(0x02, 'Warm up hot water heater for shot.'),
  stabilizeMixTemp(
    0x03,
    'Stabilize mix temp and get entire water path up to temperature.',
  ),
  preInfuse(0x04, 'Espresso only. Hot Water and Steam will skip this state.'),
  pour(0x05, 'Not used in Steam.'),
  end(0x06, 'Espresso only, atm.'),
  steaming(0x07, 'Steam only.'),
  descaleInt(0x08, 'Starting descale.'),
  descaleFillGroup(
    0x09,
    'Get some descaling solution into the group and let it sit.',
  ),
  descaleReturn(0x0A, 'Descaling internals.'),
  descaleGroup(0x0B, 'Descaling group.'),
  descaleSteam(0x0C, 'Descaling steam.'),
  cleanInit(0x0D, 'Starting clean.'),
  cleanFillGroup(0x0E, 'Fill the group.'),
  cleanSoak(0x0F, 'Wait for 60 seconds to soak the group head.'),
  cleanGroup(0x10, 'Flush through group.'),
  refill(0x11, 'Have we given up on a refill?'),
  pausedSteam(0x12, 'Are we paused in steam?'),
  userNotPresent(0x13, 'User is not present.'),
  puffing(0x14, 'Puffing.'),

  errorNaN(200, 'Something died with a NaN.'),
  errorInf(201, 'Something died with an Inf.'),
  errorGeneric(202, 'An error for which we have no more specific description.'),
  errorAcc(203, 'ACC not responding, unlocked, or incorrectly programmed.'),
  errorTSensor(204, 'Probably a broken temperature sensor.'),
  errorPSensor(205, 'Pressure sensor error.'),
  errorWLevel(206, 'Water level sensor error.'),
  errorDip(207, 'DIP switches told us to wait in the error state.'),
  errorAssertion(208, 'Assertion failed.'),
  errorUnsafe(209, 'Unsafe value assigned to variable.'),
  errorInvalidParam(210, 'Invalid parameter passed to function.'),
  errorFlash(211, 'Error accessing external flash.'),
  errorOOM(212, 'Could not allocate memory.'),
  errorDeadline(213, 'Realtime deadline missed.'),
  errorHiCurrent(214, 'Measured a current that is out of bounds.'),
  errorLoCurrent(
    215,
    'Not enough current flowing, despite something being turned on.',
  ),
  errorBootFill(
    216,
    'Could not get up to pressure during boot pressure test, possibly no water.',
  ),
  errorNoAC(217, 'Front button off.');

  final int hexValue;
  final String description;

  const De1SubState(this.hexValue, this.description);

  static De1SubState? fromHexValue(int hex) {
    return De1SubState.values.firstWhere(
      (e) => e.hexValue == hex,
      orElse: () => De1SubState.noState,
    );
  }
}

enum MMRItem implements MmrAddress {
  externalFlash(0x00000000, 0xFFFFF, MmrValueKind.bytes, "Flash RW"),
  hwConfig(0x00800000, 4, MmrValueKind.int32, "HWConfig"),
  model(0x00800004, 4, MmrValueKind.int32, "Model"),
  cpuBoardModel(
    0x00800008,
    4,
    MmrValueKind.int32,
    "CPU Board Model * 1000. eg: 1100 = 1.1",
  ),
  v13Model(
    0x0080000C,
    4,
    MmrValueKind.int32,
    "v1.3+ Firmware Model (Unset = 0, DE1 = 1, DE1Plus = 2, DE1Pro = 3, DE1XL = 4, DE1Cafe = 5)",
  ),
  cpuFirmwareBuild(
    0x00800010,
    4,
    MmrValueKind.int32,
    "CPU Board Firmware build number. (Starts at 1000 for 1.3, increments by 1 for every build)",
  ),
  debugLen(
    0x00802800,
    4,
    MmrValueKind.int32,
    "How many characters in debug buffer are valid. Accessing this pauses BLE debug logging.",
  ),
  debugBuffer(
    0x00802804,
    0x1000,
    MmrValueKind.bytes,
    "Last 4K of output. Zero terminated if buffer not full yet. Pauses BLE debug logging.",
  ),
  debugConfig(
    0x00803804,
    4,
    MmrValueKind.int32,
    "BLEDebugConfig. (Reading restarts logging into the BLE log)",
  ),
  fanThreshold(
    0x00803808,
    4,
    MmrValueKind.int32,
    "Fan threshold temp",
    min: 0,
    max: 50,
  ),
  tankTemp(0x0080380C, 4, MmrValueKind.int32, "Tank water temp threshold."),
  heaterUp1Flow(
    0x00803810,
    4,
    MmrValueKind.scaledFloat,
    "HeaterUp Phase 1 Flow Rate",
    readScale: 0.1,
    writeScale: 10.0,
  ),
  heaterUp2Flow(
    0x00803814,
    4,
    MmrValueKind.scaledFloat,
    "HeaterUp Phase 2 Flow Rate",
    readScale: 0.1,
    writeScale: 10.0,
  ),
  waterHeaterIdleTemp(
    0x00803818,
    4,
    MmrValueKind.scaledFloat,
    "Water Heater Idle Temperature",
    readScale: 0.1,
    writeScale: 10.0,
  ),
  ghcInfo(
    0x0080381C,
    4,
    MmrValueKind.int32,
    "GHC Info Bitmask, 0x1 = GHC LED Controller Present, 0x2 = GHC Touch Controller_Present, 0x4 GHC Active, 0x80000000 = Factory Mode",
  ),
  targetSteamFlow(
    0x00803828,
    4,
    MmrValueKind.scaledFloat,
    "Target steam flow rate",
    readScale: 0.01,
    writeScale: 100.0,
  ),
  steamStartSecs(
    0x0080382C,
    4,
    MmrValueKind.scaledFloat,
    "Seconds of high steam flow * 100. Valid range 0.0 - 4.0. 0 may result in an overheated heater. Be careful.",
    readScale: 0.01,
    writeScale: 100.0,
  ),
  serialN(0x00803830, 4, MmrValueKind.int32, "Current serial number"),
  heaterV(
    0x00803834,
    4,
    MmrValueKind.int32,
    "Nominal Heater Voltage (0, 120V or 230V). +1000 if it's a set value.",
  ),
  heaterUp2Timeout(
    0x00803838,
    4,
    MmrValueKind.scaledFloat,
    "HeaterUp Phase 2 Timeout",
    readScale: 0.1,
    writeScale: 10.0,
  ),
  calFlowEst(
    0x0080383C,
    4,
    MmrValueKind.scaledFloat,
    "Flow Estimation Calibration",
    readScale: 0.001,
    writeScale: 1000.0,
    min: 130,
    max: 2000,
  ),
  flushFlowRate(
    0x00803840,
    4,
    MmrValueKind.scaledFloat,
    "Flush Flow Rate",
    readScale: 0.1,
    writeScale: 10.0,
  ),
  flushTemp(
    0x00803844,
    4,
    MmrValueKind.scaledFloat,
    "Flush Temp",
    readScale: 0.1,
    writeScale: 10.0,
  ),
  flushTimeout(
    0x00803848,
    4,
    MmrValueKind.scaledFloat,
    "Flush Timeout",
    readScale: 0.1,
    writeScale: 10.0,
  ),
  hotWaterFlowRate(
    0x0080384C,
    4,
    MmrValueKind.scaledFloat,
    "Hot Water Flow Rate",
    readScale: 0.1,
    writeScale: 10.0,
  ),
  steamPurgeMode(0x00803850, 4, MmrValueKind.int32, "Steam Purge Mode"),
  allowUSBCharging(0x00803854, 4, MmrValueKind.boolean, "Allow USB charging"),
  appFeatureFlags(0x00803858, 4, MmrValueKind.int32, "App Feature Flags"),
  refillKitPresent(0x0080385C, 4, MmrValueKind.int32, "Refill Kit Present"),
  userPresent(0x00803860, 4, MmrValueKind.boolean, "Is User Present");

  @override
  final int address;
  @override
  final int length;
  @override
  final MmrValueKind kind;
  final String description;
  @override
  final double readScale;
  @override
  final double writeScale;
  @override
  final int? min;
  @override
  final int? max;

  const MMRItem(
    this.address,
    this.length,
    this.kind,
    this.description, {
    this.readScale = 1.0,
    this.writeScale = 1.0,
    this.min,
    this.max,
  });

  @override
  String get name => (this as Enum).name;
}

bool isBengleModelValue(int value) => value >= 128;

enum DecentMachineModel {
  Unknown(0),
  DE1(1),
  DE1Plus(2),
  DE1Pro(3),
  DE1XL(4),
  DE1Cafe(5),
  DE1XXL(6),
  DE1XXXL(7),
  Bengle(128);

  final int value;

  const DecentMachineModel(this.value);

  String get displayName => this == DE1Plus ? 'DE1+' : name;

  static DecentMachineModel fromInt(int model) {
    for (final m in values) {
      if (m.value == model) return m;
    }
    return isBengleModelValue(model)
        ? DecentMachineModel.Bengle
        : DecentMachineModel.Unknown;
  }
}
