import 'dart:collection';

class WeightedSample {
  final DateTime timestamp;
  final double weight;

  WeightedSample(this.timestamp, this.weight);
}

class FlowCalculator {
  final Duration windowDuration;
  final Queue<WeightedSample> _samples = Queue();
  final double deadband;
  final double maxFlow;

  FlowCalculator({
    this.windowDuration = const Duration(milliseconds: 800),
    this.deadband = 0.05,
    this.maxFlow = 8.0,
  });

  double addSample(DateTime timestamp, double weight) {
    _samples.addLast(WeightedSample(timestamp, weight));

    while (_samples.isNotEmpty &&
        timestamp.difference(_samples.first.timestamp) > windowDuration) {
      _samples.removeFirst();
    }

    // Not enough data
    if (_samples.length < 2) return 0.0;

    final first = _samples.first;
    final last = _samples.last;
    final deltaTimeMs = last.timestamp
        .difference(first.timestamp)
        .inMilliseconds;
    final deltaWeight = last.weight - first.weight;

    // Avoid division by zero
    if (deltaTimeMs <= 0 || deltaWeight.abs() < deadband) return 0.0;

    var flow = (deltaWeight * 1000) / deltaTimeMs;
    return flow.clamp(-maxFlow, maxFlow);
  }
}
