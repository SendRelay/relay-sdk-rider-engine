import 'dart:math';

/// A lightweight 2D Kalman filter that smooths raw GPS coordinates.
///
/// Runs two independent 1D filters (lat + lng) with a shared accuracy-weighted
/// measurement noise term. Accuracy from the device (in metres) is used to
/// dynamically scale R — a poor-accuracy fix is trusted less.
///
/// Reference: Welch & Bishop, "An Introduction to the Kalman Filter" (2006).
class GpsKalmanFilter {
  GpsKalmanFilter({
    required double processNoise,
    required double measurementNoise,
    double maxGapSeconds = 20.0,
  }) : _q = processNoise,
       _rBase = measurementNoise,
       _maxGapSeconds = maxGapSeconds;

  final double _q; // process noise variance (Q) per second
  final double _rBase; // base measurement noise variance (R)

  /// Beyond this gap between fixes the previous estimate is considered stale
  /// (tunnel, app backgrounded, GPS lost) and the filter re-seeds from the new
  /// reading instead of slowly dragging the old estimate across the jump.
  final double _maxGapSeconds;

  // State — lat axis
  double _latEstimate = 0;
  double _latVariance = 1;

  // State — lng axis
  double _lngEstimate = 0;
  double _lngVariance = 1;

  bool _initialised = false;
  DateTime? _lastTimestamp;

  /// Feed a raw GPS reading. Returns the filtered [lat, lng].
  ///
  /// [accuracyMeters] is used to scale measurement noise:
  /// a 3m accurate fix is trusted more than a 50m one.
  ///
  /// [timestamp] (the fix time) lets the filter scale process noise by the
  /// elapsed time since the last fix, so uncertainty grows correctly across
  /// irregular intervals. When omitted, a unit step is assumed (legacy
  /// behaviour). A gap longer than `maxGapSeconds` triggers a re-seed.
  (double lat, double lng) filter(
    double rawLat,
    double rawLng, {
    required double accuracyMeters,
    DateTime? timestamp,
  }) {
    // Resolve the time step. Without a timestamp we assume a unit step so
    // behaviour matches the pre-Δt filter exactly.
    var dtSeconds = 1.0;
    if (timestamp != null) {
      if (_lastTimestamp != null) {
        dtSeconds = timestamp.difference(_lastTimestamp!).inMicroseconds / 1e6;
        if (dtSeconds <= 0) dtSeconds = 0.001; // guard non-monotonic clocks
      }
      // Stale estimate after a long gap → re-seed rather than drag it over.
      if (_initialised && dtSeconds > _maxGapSeconds) _initialised = false;
      _lastTimestamp = timestamp;
    }

    if (!_initialised) {
      _latEstimate = rawLat;
      _lngEstimate = rawLng;
      // Seed variance from initial accuracy
      _latVariance = accuracyMeters * accuracyMeters;
      _lngVariance = accuracyMeters * accuracyMeters;
      _initialised = true;
      return (rawLat, rawLng);
    }

    // Scale R by accuracy: 1m accuracy → R = _rBase, 50m accuracy → R = 50² × _rBase
    final rScaled = max(_rBase, _rBase * accuracyMeters * accuracyMeters);

    // --- Predict step --- (process noise grows with elapsed time)
    final qScaled = _q * dtSeconds;
    final latPredVariance = _latVariance + qScaled;
    final lngPredVariance = _lngVariance + qScaled;

    // --- Update step ---
    final latGain = latPredVariance / (latPredVariance + rScaled);
    final lngGain = lngPredVariance / (lngPredVariance + rScaled);

    _latEstimate = _latEstimate + latGain * (rawLat - _latEstimate);
    _lngEstimate = _lngEstimate + lngGain * (rawLng - _lngEstimate);

    _latVariance = (1 - latGain) * latPredVariance;
    _lngVariance = (1 - lngGain) * lngPredVariance;

    return (_latEstimate, _lngEstimate);
  }

  /// Reset — call when driver goes offline and comes back online,
  /// or after a long gap in readings.
  void reset() {
    _initialised = false;
    _latVariance = 1;
    _lngVariance = 1;
    _lastTimestamp = null;
  }
}
