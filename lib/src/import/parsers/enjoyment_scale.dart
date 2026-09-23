const double de1appEnjoymentMax = 100.0;
const double enjoymentMax = 10.0;
const double legacyEnjoymentThreshold = enjoymentMax;

double? rescaleDe1appEnjoyment(double? value) {
  if (value == null) return null;
  final scaled = value * enjoymentMax / de1appEnjoymentMax;
  return scaled.clamp(0.0, enjoymentMax);
}
