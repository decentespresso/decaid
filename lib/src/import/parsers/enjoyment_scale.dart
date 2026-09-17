const double _de1appEnjoymentMax = 100.0;
const double _enjoymentMax = 5.0;

double? rescaleDe1appEnjoyment(double? value) {
  if (value == null) return null;
  final scaled = value * _enjoymentMax / _de1appEnjoymentMax;
  return scaled.clamp(0.0, _enjoymentMax);
}
