class KalmanFlowEstimator {
  double _weight;
  double _flow;

  double _p11, _p12, _p21, _p22;

  DateTime? _lastTimestamp;

  double _r;

  final double _q;

  static const double _alphaUp = 0.05;

  static const double _alphaDown = 0.1;

  static const double _rMin = 0.01;

  static const double _rMax = 15.0;

  static const double _initialR = 3.0;

  static const double _initialCovariance = 30.0;

  static const double _pMin = 0.01;

  KalmanFlowEstimator({
    required double initialWeight,
    double processNoiseIntensity = 2.5,
  }) : _weight = initialWeight,
       _flow = 0.0,
       _p11 = _initialCovariance,
       _p12 = 0.0,
       _p21 = 0.0,
       _p22 = _initialCovariance,
       _q = processNoiseIntensity,
       _r = _initialR;

  double get weight => _weight;

  double get flow => _flow;

  (double weight, double flow) addSample(DateTime timestamp, double rawWeight) {
    if (_lastTimestamp == null) {
      _lastTimestamp = timestamp;
      _weight = rawWeight;
      return (_weight, _flow);
    }

    final dtMs = timestamp.difference(_lastTimestamp!).inMilliseconds;
    _lastTimestamp = timestamp;

    if (dtMs <= 0) {
      return (_weight, _flow);
    }

    final dt = dtMs / 1000.0;

    final predWeight = _weight + _flow * dt;
    final predFlow = _flow;

    final fp11 = _p11 + dt * _p21;
    final fp12 = _p12 + dt * _p22;
    final fp21 = _p21;
    final fp22 = _p22;

    final pp11 = fp11 + fp12 * dt;
    final pp12 = fp12;
    final pp21 = fp21 + fp22 * dt;
    final pp22 = fp22;

    final dt2 = dt * dt;
    final q11 = _q * dt2 * dt / 3.0;
    final q12 = _q * dt2 / 2.0;
    final q22 = _q * dt;

    final predP11 = pp11 + q11;
    final predP12 = pp12 + q12;
    final predP21 = pp21 + q12;
    final predP22 = pp22 + q22;

    final innovation = rawWeight - predWeight;

    final clipped = innovation.clamp(-3.0, 3.0);
    final innovSq = clipped * clipped;
    final alpha = innovSq > _r ? _alphaUp : _alphaDown;
    _r = alpha * innovSq + (1.0 - alpha) * _r;
    _r = _r.clamp(_rMin, _rMax);

    final s = predP11 + _r;

    final k1 = predP11 / s;
    final k2 = predP21 / s;

    _weight = predWeight + k1 * innovation;
    _flow = predFlow + k2 * innovation;

    _p11 = (1.0 - k1) * predP11;
    _p12 = (1.0 - k1) * predP12;
    _p21 = predP21 - k2 * predP11;
    _p22 = predP22 - k2 * predP12;

    if (_p11 < _pMin) _p11 = _pMin;
    if (_p22 < _pMin) _p22 = _pMin;

    return (_weight, _flow);
  }

  void reset(double initialWeight) {
    _weight = initialWeight;
    _flow = 0.0;
    _p11 = _initialCovariance;
    _p12 = 0.0;
    _p21 = 0.0;
    _p22 = _initialCovariance;
    _lastTimestamp = null;
    _r = _initialR;
  }
}
