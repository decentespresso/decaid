import 'package:reaprime/src/models/device/impl/de1/mmr_address.dart';

enum BengleMmr implements MmrAddress {
  matSetPoint(
    0x00803874,
    4,
    MmrValueKind.scaledFloat,
    'MatSetPoint',
    min: 0,
    max: 800,
    readScale: 0.1,
    writeScale: 10.0,
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
  stopAtTemperatureTarget(
    0x00000000,
    4,
    MmrValueKind.scaledFloat,
    'StopAtTemperatureTarget',
    min: 0,
    max: 800,
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
