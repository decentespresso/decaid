List<int> framesFromStateChange(List<double> stateChange) {
  final frames = <int>[];
  var frame = 0;
  var previousSign = 0;

  for (final value in stateChange) {
    final sign = value > 0
        ? 1
        : value < 0
        ? -1
        : 0;
    if (sign != 0) {
      if (previousSign != 0 && sign != previousSign) frame++;
      previousSign = sign;
    }
    frames.add(frame);
  }

  return frames;
}
