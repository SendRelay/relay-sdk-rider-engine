import 'dart:math';
import '../models/engine_config.dart';

/// Controls how aggressively the engine emits location updates.
///
/// The engine switches mode automatically based on driver + task state:
///
/// | Driver status | Task status         | Mode            |
/// |---------------|---------------------|-----------------|
/// | offline       | any                 | (no emit)       |
/// | online        | any                 | heartbeatOnly   |
/// | busy          | assigned/inProgress | adaptive        |
/// | busy          | other               | heartbeatOnly   |
enum EmissionMode {
  /// Full speed/distance/heading adaptive logic. Use when driver has an active task.
  adaptive,

  /// Only emits on heartbeat intervals. Use for idle/available drivers.
  /// Keeps backend DriverPresence TTL alive without spamming the server.
  heartbeatOnly,
}

/// Determines whether a new GPS reading warrants an emission.
///
/// ### adaptive mode decision tree (evaluated in order):
/// 1. First fix → always emit
/// 2. Heartbeat → elapsed ≥ heartbeatInterval → emit (keeps backend TTL alive)
/// 3. Stopped suppression → speed < threshold and heading stable → suppress
/// 4. Heading trigger → delta ≥ threshold → emit (driver is turning)
/// 5. Speed-adaptive distance/interval gate
///
/// ### heartbeatOnly mode:
/// Only emits on first fix and heartbeat. All movement triggers are suppressed.
class EmissionPolicy {
  EmissionPolicy(this._config) : _mode = EmissionMode.heartbeatOnly;

  final EngineConfig _config;
  EmissionMode _mode;

  DateTime? _lastEmitTime;
  double? _lastLat;
  double? _lastLng;
  double? _lastHeading;

  EmissionMode get mode => _mode;

  /// Switch emission mode. Called by the engine when driver/task state changes.
  void setMode(EmissionMode mode) => _mode = mode;

  /// Evaluate whether the current position warrants an emission.
  EmissionDecision evaluate({
    required double lat,
    required double lng,
    required double speed,
    required double heading,
    required DateTime now,
  }) {
    // First fix — always emit regardless of mode
    if (_lastEmitTime == null) {
      return const EmissionDecision(
        shouldEmit: true,
        reason: EmitReason.firstFix,
      );
    }

    final elapsed = now.difference(_lastEmitTime!);

    // Heartbeat — keeps backend DriverPresence TTL alive; applies in both modes
    if (elapsed >= _config.heartbeatInterval) {
      return const EmissionDecision(
        shouldEmit: true,
        reason: EmitReason.heartbeat,
      );
    }

    // heartbeatOnly mode — suppress everything else
    if (_mode == EmissionMode.heartbeatOnly) {
      return const EmissionDecision(
        shouldEmit: false,
        reason: EmitReason.modeHeartbeatOnly,
      );
    }

    // ---- adaptive mode below ------------------------------------------------

    // Stopped suppression
    final isStopped = speed < _config.stoppedSpeedThreshold;
    final headingStable =
        _lastHeading == null ||
        _angleDelta(heading, _lastHeading!) < _config.headingThresholdDegrees;

    if (isStopped && headingStable) {
      return const EmissionDecision(
        shouldEmit: false,
        reason: EmitReason.stopped,
      );
    }

    // Heading trigger — driver is turning
    if (_lastHeading != null &&
        _angleDelta(heading, _lastHeading!) >=
            _config.headingThresholdDegrees) {
      return const EmissionDecision(
        shouldEmit: true,
        reason: EmitReason.heading,
      );
    }

    // Speed-adaptive distance + interval gate
    final isFast = speed >= _config.fastSpeedThreshold;
    final minInterval = isFast ? _config.fastInterval : _config.normalInterval;
    final minDistance = isFast
        ? _config.fastDistanceFilter
        : _config.normalDistanceFilter;

    final movedEnough =
        _lastLat != null &&
        _haversineMeters(_lastLat!, _lastLng!, lat, lng) >= minDistance;
    final intervalElapsed = elapsed >= minInterval;

    if (movedEnough && intervalElapsed) {
      return EmissionDecision(
        shouldEmit: true,
        reason: isFast ? EmitReason.fastMoving : EmitReason.normalMoving,
      );
    }

    if (movedEnough) {
      return const EmissionDecision(
        shouldEmit: false,
        reason: EmitReason.intervalNotMet,
      );
    }

    return const EmissionDecision(
      shouldEmit: false,
      reason: EmitReason.distanceNotMet,
    );
  }

  /// Must be called after a successful emission to update internal state.
  void recordEmission({
    required double lat,
    required double lng,
    required double heading,
    required DateTime now,
  }) {
    _lastEmitTime = now;
    _lastLat = lat;
    _lastLng = lng;
    _lastHeading = heading;
  }

  /// Reset all state. Call when driver goes offline or engine stops.
  void reset() {
    _lastEmitTime = null;
    _lastLat = null;
    _lastLng = null;
    _lastHeading = null;
    _mode = EmissionMode.heartbeatOnly;
  }

  // ---------------------------------------------------------------------------

  static double _angleDelta(double a, double b) {
    final diff = (a - b).abs() % 360;
    return diff > 180 ? 360 - diff : diff;
  }

  static double _haversineMeters(
    double lat1,
    double lng1,
    double lat2,
    double lng2,
  ) {
    const r = 6371000.0;
    final dLat = (lat2 - lat1) * pi / 180;
    final dLng = (lng2 - lng1) * pi / 180;
    final a =
        sin(dLat / 2) * sin(dLat / 2) +
        cos(lat1 * pi / 180) *
            cos(lat2 * pi / 180) *
            sin(dLng / 2) *
            sin(dLng / 2);
    return r * 2 * atan2(sqrt(a), sqrt(1 - a));
  }
}

enum EmitReason {
  firstFix,
  heartbeat,
  modeHeartbeatOnly,
  stopped,
  heading,
  fastMoving,
  normalMoving,
  intervalNotMet,
  distanceNotMet,
}

class EmissionDecision {
  const EmissionDecision({required this.shouldEmit, required this.reason});
  final bool shouldEmit;
  final EmitReason reason;

  @override
  String toString() => 'EmissionDecision(emit=$shouldEmit, reason=$reason)';
}
