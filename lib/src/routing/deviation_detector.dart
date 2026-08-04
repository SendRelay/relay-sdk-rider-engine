import '../models/engine_config.dart';

/// Tracks consecutive off-route readings and fires when the driver has
/// genuinely deviated — not just a single noisy GPS blip.
///
/// An "episode" is a contiguous run of off-route readings. The event fires at
/// most once per episode (when the run reaches `deviationConsecutiveCount`).
/// Returning to the route ends the episode and **re-arms** the detector, so a
/// later genuine deviation on the same route still fires. Crucially, a short
/// sub-threshold blip that recovers does not permanently disarm detection.
class DeviationDetector {
  DeviationDetector(this._config);

  final EngineConfig _config;

  int _consecutiveOffRoute = 0;
  bool _deviationFired = false;

  /// Returns true exactly once when an off-route episode reaches
  /// `deviationConsecutiveCount` consecutive readings.
  bool record(double deviationMeters) {
    if (deviationMeters > _config.deviationThresholdMeters) {
      _consecutiveOffRoute++;

      if (_consecutiveOffRoute >= _config.deviationConsecutiveCount &&
          !_deviationFired) {
        _deviationFired = true;
        return true; // fire the event exactly once per deviation episode
      }
    } else {
      // Back on route — the episode is over. Re-arm so the next genuine
      // deviation can fire again (a transient blip must not disable detection
      // for the rest of the trip).
      _consecutiveOffRoute = 0;
      _deviationFired = false;
    }

    return false;
  }

  /// Call when a new route polyline is loaded. Re-arms the detector.
  void reset() {
    _consecutiveOffRoute = 0;
    _deviationFired = false;
  }
}
