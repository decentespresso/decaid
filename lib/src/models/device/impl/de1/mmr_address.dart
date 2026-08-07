enum MmrValueKind { int32, int16, scaledFloat, boolean, bytes, string }

abstract class MmrAddress {
  int get address;
  int get length;
  String get name;
  MmrValueKind get kind;

  double get readScale => 1.0;

  double get writeScale => 1.0;

  int? get min => null;

  int? get max => null;
}
