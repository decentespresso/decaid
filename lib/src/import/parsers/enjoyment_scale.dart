/// de1app and Visualizer both rate enjoyment 0-100. Decaid's canonical
/// `annotations.enjoyment` is 0-5, the scale its API declares and its clients
/// render.
const double de1appEnjoymentMax = 100.0;
const double enjoymentMax = 5.0;

/// A stored rating above the canonical maximum cannot have been written on the
/// 0-5 scale, so it identifies an un-migrated 0-100 value regardless of which
/// writer produced it.
const double legacyEnjoymentThreshold = enjoymentMax;

double? rescaleDe1appEnjoyment(double? value) {
  if (value == null) return null;
  final scaled = value * enjoymentMax / de1appEnjoymentMax;
  return scaled.clamp(0.0, enjoymentMax);
}
