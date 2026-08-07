/// A 1-D constant-velocity Kalman filter estimating flow (g/s) from noisy
/// scale weight measurements.
///
/// The filter maintains a 2-element state vector `[weight, flow]` internally,
/// but only the **flow** estimate should be consumed by callers. Raw weight
/// passes through to consumers unfiltered — the Kalman state tracks weight
/// solely to derive a smooth, low-lag flow estimate via the constant-velocity
/// model.
///
/// ## Design
///
/// - **Adaptive measurement noise `R`** — tracked online from innovation
///   (residual) variance with **asymmetric EMA**: transients inflate R slowly
///   (reject noise), recovery deflates R quickly (re-trust sensor fast).
/// - **Fixed process noise `Q`** from flow physics (0–10 g/s, bounded ramp
///   rate). We adapt trust in the sensor, not the physics model.
/// - **Variable `dt`** in every predict step — fixes the count-based window
///   bug of the old [MovingAverage].
/// - **Signed flow** — no `.abs()` (un-breaks the cup-removal branch in
///   [ShotSequencer._refineStoppingYield]).
/// - **Hard re-init at tare** via [reset] — re-seeds weight to current, flow
///   to 0, covariance moderate (the filter re-converges quickly from the new
///   baseline).
///
/// ## Tuning rationale
///
/// These parameters are a middle ground between two extremes. The
/// original filter (R_max=50, P_init=100, Q=2.0) produced smooth flow but
/// a severely laggy *weight* estimate (10s convergence on a 99g test
/// weight, overshooting to 130g). The aggressive retune (R_max=5,
/// P_init=10, Q=4.0) fixed weight convergence but doubled per-sample
/// flow jitter (0.49 vs 0.23 g/s mean |Δflow| at native 10 Hz). Since
/// weight is now raw-passthrough in [ScaleController], R only affects
/// flow smoothness. These values target the smoothest flow that still
/// converges within ~5 samples at native 10 Hz.
///
/// ## Multi-scale
///
/// Adaptive `R` auto-calibrates its baseline to whatever scale's noise floor
/// is connected (no per-scale `R` table). Variable-`dt` handles a slower
/// scale's larger intervals. Two mechanisms, two axes (noise vs rate).
class KalmanFlowEstimator {
  double _weight;
  double _flow;

  double _p11, _p12, _p21, _p22;

  // -- Timestamp of the last sample --

  DateTime? _lastTimestamp;

  double _r;

  final double _q;

  /// EMA smoothing factor when innovation² > current R (noise rising).
  /// Slow rise → don't over-react to a single spike.
  static const double _alphaUp = 0.05;

  /// EMA smoothing factor when innovation² < current R (noise falling).
  /// Moderate decay — re-trust the sensor after a transient without
  /// snapping back so fast that per-sample flow jitter returns.
  static const double _alphaDown = 0.1;

  /// Floor for R — prevents filter divergence when the scale is dead-quiet.
  static const double _rMin = 0.01;

  /// Ceiling for R — limits how much the filter can distrust the sensor.
  /// 15 is a middle ground: high enough to attenuate taps/knocks, low
  /// enough that genuine level changes are tracked without excessive lag.
  /// The original filter used R = 50 (over-damped, flow too smooth but
  /// weight laggy); the aggressive retune used R = 5 (snappy but flow
  /// jittery). Since weight is now raw-passthrough, R only affects flow.
  static const double _rMax = 15.0;

  /// Initial measurement noise. Typical scale noise is 0.01–0.1 g; starting
  /// at 3.0 gives the filter a few samples to calibrate while damping the
  /// initial per-sample flow jitter. Higher than the aggressive retune
  /// (1.0) but well below the original (10.0).
  static const double _initialR = 3.0;

  /// Initial covariance diagonal — high enough for quick convergence from
  /// a cold start, not so high as to cause excessive initial lag. A middle
  /// ground between the original (100, over-damped) and the aggressive
  /// retune (10, jittery).
  static const double _initialCovariance = 30.0;

  /// Minimum covariance diagonal — prevents the filter from becoming
  /// overconfident. 0.01 keeps the Kalman gain responsive while damping
  /// per-sample flow jitter more than the aggressive retune (0.001).
  static const double _pMin = 0.01;

  /// Creates a Kalman flow estimator seeded with [initialWeight].
  ///
  /// [processNoiseIntensity] is the continuous-time acceleration variance `q`.
  /// Default 2.5 ≈ ±1.6 g/s² RMS. A middle ground between the original
  /// (2.0, smoother flow) and the aggressive retune (4.0, snappier but
  /// jittery). Lower Q → filter expects slower state changes → smoother
  /// flow at the cost of slightly slower ramp tracking.
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

  /// The current filtered weight estimate (internal — prefer raw weight).
  double get weight => _weight;

  /// The current flow estimate (signed, g/s).
  double get flow => _flow;

  /// Feed a new raw weight sample and return the updated (weight, flow)
  /// estimates.
  ///
  /// The first call initialises the internal timestamp without running a
  /// filter update — only the state is seeded to [rawWeight]. Subsequent
  /// calls use the actual inter-sample `dt` for the predict step.
  (double weight, double flow) addSample(DateTime timestamp, double rawWeight) {
    if (_lastTimestamp == null) {
      _lastTimestamp = timestamp;
      _weight = rawWeight;
      return (_weight, _flow);
    }

    final dtMs = timestamp.difference(_lastTimestamp!).inMilliseconds;
    _lastTimestamp = timestamp;

    // Guard against zero or negative dt (e.g. BLE re-transmits).
    if (dtMs <= 0) {
      return (_weight, _flow);
    }

    final dt = dtMs / 1000.0;

    // ── Predict ──────────────────────────────────────────────────────
    // State transition (constant velocity):
    //   x_pred = F @ x
    //   where F = [[1, dt],
    //              [0, 1]]

    final predWeight = _weight + _flow * dt;
    final predFlow = _flow;

    // P_pred = F @ P @ F^T + Q
    // F @ P = [[p11 + dt·p21,  p12 + dt·p22],
    //          [p21,           p22]]
    final fp11 = _p11 + dt * _p21;
    final fp12 = _p12 + dt * _p22;
    final fp21 = _p21;
    final fp22 = _p22;

    // (F@P) @ F^T = [[fp11 + fp12·dt,  fp12],
    //                [fp21 + fp22·dt,  fp22]]
    final pp11 = fp11 + fp12 * dt;
    final pp12 = fp12;
    final pp21 = fp21 + fp22 * dt;
    final pp22 = fp22;

    // Q = q · [[dt³/3,  dt²/2],
    //          [dt²/2,  dt   ]]
    // (discrete white-noise acceleration model)
    final dt2 = dt * dt;
    final q11 = _q * dt2 * dt / 3.0;
    final q12 = _q * dt2 / 2.0;
    final q22 = _q * dt;

    final predP11 = pp11 + q11;
    final predP12 = pp12 + q12;
    final predP21 = pp21 + q12;
    final predP22 = pp22 + q22;

    // ── Update ───────────────────────────────────────────────────────
    // Measurement model:
    //   z = rawWeight  (we only observe weight)
    //   H = [1, 0]

    final innovation = rawWeight - predWeight;

    // Adaptive R — asymmetric EMA of squared innovation.
    // Clip innovation before squaring so a single large step (cup placement)
    // doesn't dominate the R tracker. ±3g covers the range of per-sample
    // weight changes during espresso (up to ~1g/sample at 10 Hz, 8 g/s).
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

    // Covariance update: P = (I - K@H) @ P_pred
    //   I - K@H = [[1-k1, 0],
    //              [-k2,  1]]
    _p11 = (1.0 - k1) * predP11;
    _p12 = (1.0 - k1) * predP12;
    _p21 = predP21 - k2 * predP11;
    _p22 = predP22 - k2 * predP12;

    // Floor P to prevent overconfidence.
    if (_p11 < _pMin) _p11 = _pMin;
    if (_p22 < _pMin) _p22 = _pMin;

    return (_weight, _flow);
  }

  /// Hard re-initialisation — call at tare.
  ///
  /// Resets weight to [initialWeight], flow to 0, and covariance to moderate
  /// (the filter re-converges quickly from the new baseline). Also resets
  /// the adaptive-R tracker so a post-tare spike doesn't inherit a stale
  /// noise estimate.
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
