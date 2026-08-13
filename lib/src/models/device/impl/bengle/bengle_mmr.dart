import 'package:reaprime/src/models/device/impl/de1/mmr_address.dart';

enum BengleMmr implements MmrAddress {
  matSetPoint(
    0x00803874,
    4,
    MmrValueKind.scaledFloat,
    'MatSetPoint',
    min: 0,
    max: 80,
    readScale: 1.0,
    writeScale: 1.0,
  ),

  // Rows 39-41: load-cell calibration (verified against
  // BengleMainCPUFirmware src/Classes/System.cpp startScaleCalStep /
  // CLoadCellCal.hpp at 2377c7e0).
  scaleCalCmd(0x00803880, 4, MmrValueKind.int32, 'ScaleCalCmd', min: 0, max: 5),
  scaleCalState(0x00803884, 4, MmrValueKind.int32, 'ScaleCalState'),
  scaleCalWeight(
    0x00803888,
    4,
    MmrValueKind.scaledFloat,
    'ScaleCalWeight',
    min: 0,
    max: 100000,
    readScale: 0.1,
    writeScale: 10.0,
  ),

  // Rows 45-48: persistent LED palette (APIView.cpp F_LEDStoreColor,
  // applyLEDsForGivenState). 0x00RRGGBB, applied by the firmware on
  // sleep/wake transitions.
  frontLedAwake(
    0x00803898,
    4,
    MmrValueKind.int32,
    'FrontLEDAwake',
    min: 0,
    max: 0xFFFFFF,
  ),
  rearLedAwake(
    0x0080389C,
    4,
    MmrValueKind.int32,
    'RearLEDAwake',
    min: 0,
    max: 0xFFFFFF,
  ),
  frontLedSleep(
    0x008038A0,
    4,
    MmrValueKind.int32,
    'FrontLEDSleep',
    min: 0,
    max: 0xFFFFFF,
  ),
  rearLedSleep(
    0x008038A4,
    4,
    MmrValueKind.int32,
    'RearLEDSleep',
    min: 0,
    max: 0xFFFFFF,
  ),

  // Row 50: manual cup-warmer enable. RAM-only; boots to 0.
  cupWarmerMode(
    0x008038AC,
    4,
    MmrValueKind.int32,
    'CupWarmerMode',
    min: 0,
    max: 1,
  ),

  // Row 54: autonomous inactivity sleep (0 = disabled, max 240). Persisted.
  inactivitySleepTimeout(
    0x008038BC,
    4,
    MmrValueKind.int32,
    'InactivitySleepTimeout',
    min: 0,
    max: 240,
  ),

  // Rows 55-57: tablet-synced wall clock + weekly wake schedule (RAM-only).
  setLocalTimeOfWeek(
    0x008038C0,
    4,
    MmrValueKind.int32,
    'SetLocalTimeOfWeek',
    min: 0,
    max: 604800,
  ),
  scheduleEntry(
    0x008038C4,
    4,
    MmrValueKind.int32,
    'ScheduleEntry',
    min: 0,
    max: 0x7FFFFFFF,
  ),
  scheduleControl(
    0x008038C8,
    4,
    MmrValueKind.int32,
    'ScheduleControl',
    min: 0,
    max: 255,
  ),

  // Row 58: live mat temperature, wire = deg C * 10; 0 = no valid reading.
  matCurrentTemp(
    0x008038CC,
    4,
    MmrValueKind.scaledFloat,
    'MatCurrentTemp',
    min: 0,
    max: 16000,
    readScale: 0.1,
    writeScale: 10.0,
  ),

  // Rows 59-61: scheduled cup-warmer pre-warm (persisted config + read-only
  // active flag).
  matPreheatEnable(
    0x008038D0,
    4,
    MmrValueKind.int32,
    'MatPreheatEnable',
    min: 0,
    max: 1,
  ),
  matPreheatLeadMin(
    0x008038D4,
    4,
    MmrValueKind.int32,
    'MatPreheatLeadMin',
    min: 0,
    max: 120,
  ),
  matPreheatActive(
    0x008038D8,
    4,
    MmrValueKind.int32,
    'MatPreheatActive',
    min: 0,
    max: 1,
  );

  const BengleMmr(
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

  @override
  String get name => (this as Enum).name;
}

enum BengleSteamMmr implements MmrAddress {
  targetMilkTemp(
    0x008038A8,
    4,
    MmrValueKind.scaledFloat,
    'TargetMilkTemp',
    min: 0,
    max: 850,
    readScale: 0.1,
    writeScale: 10.0,
  );

  const BengleSteamMmr(
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

  @override
  String get name => (this as Enum).name;
}
