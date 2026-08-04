import 'package:equatable/equatable.dart';

/// All tunable parameters for [RelayDriverEngine].
///
/// Sane defaults model a typical Nigerian urban delivery scenario
/// (Lagos / Abuja road density, typical motorcycle/car speeds).
///
/// ### Emission tiers (adaptive mode only)
///
/// | Tier    | Speed        | Max interval        | Min distance |
/// |---------|--------------|---------------------|--------------|
/// | Stopped | < 0.5 m/s    | [heartbeatInterval] | —            |
/// | Normal  | 0.5–12 m/s   | [normalInterval]    | [normalDistanceFilter] |
/// | Fast    | > 12 m/s     | [fastInterval]      | [fastDistanceFilter]   |
///
/// ### Background
/// Set [enableBackground] to `true` for foreground-service tracking
/// (foreground + background, not killed). Full kill-resilient background
/// requires additional native configuration — see README.
class EngineConfig extends Equatable {
  // ignore: prefer_const_constructors_in_immutables
  EngineConfig({
    this.heartbeatInterval = const Duration(seconds: 25),
    this.normalInterval = const Duration(seconds: 10),
    this.fastInterval = const Duration(seconds: 3),
    this.stoppedSpeedThreshold = 0.5,
    this.fastSpeedThreshold = 12.0,
    this.normalDistanceFilter = 15.0,
    this.fastDistanceFilter = 10.0,
    this.headingThresholdDegrees = 20.0,
    this.kalmanProcessNoise = 0.0001,
    this.kalmanMeasurementNoise = 0.0005,
    this.snapToRouteEnabled = true,
    this.deviationThresholdMeters = 80.0,
    this.deviationConsecutiveCount = 3,
    this.enableBackground = false,
    this.backgroundNotificationTitle = 'Relay — Active Delivery',
    this.backgroundNotificationContent = 'Your location is being tracked.',
  }) : assert(
         heartbeatInterval > normalInterval,
         'heartbeatInterval must be longer than normalInterval',
       ),
       assert(
         normalInterval > fastInterval,
         'normalInterval must be longer than fastInterval',
       ),
       assert(stoppedSpeedThreshold > 0, 'stoppedSpeedThreshold must be > 0'),
       assert(
         fastSpeedThreshold > stoppedSpeedThreshold,
         'fastSpeedThreshold must be > stoppedSpeedThreshold',
       ),
       assert(normalDistanceFilter > 0, 'normalDistanceFilter must be > 0'),
       assert(fastDistanceFilter > 0, 'fastDistanceFilter must be > 0'),
       assert(
         headingThresholdDegrees > 0 && headingThresholdDegrees < 180,
         'headingThresholdDegrees must be between 0 and 180',
       ),
       assert(kalmanProcessNoise > 0, 'kalmanProcessNoise must be > 0'),
       assert(kalmanMeasurementNoise > 0, 'kalmanMeasurementNoise must be > 0'),
       assert(
         deviationThresholdMeters > 0,
         'deviationThresholdMeters must be > 0',
       ),
       assert(
         deviationConsecutiveCount >= 1,
         'deviationConsecutiveCount must be >= 1',
       );

  final Duration heartbeatInterval;
  final Duration normalInterval;
  final Duration fastInterval;

  final double stoppedSpeedThreshold; // m/s
  final double fastSpeedThreshold; // m/s

  final double normalDistanceFilter; // metres
  final double fastDistanceFilter; // metres

  final double headingThresholdDegrees;

  /// Kalman filter process noise (Q). Higher → filter trusts new measurements more.
  final double kalmanProcessNoise;

  /// Kalman filter measurement noise (R base). Higher → filter smooths more.
  final double kalmanMeasurementNoise;

  final bool snapToRouteEnabled;

  /// Off-route boundary in metres. Beyond this → candidate for reroute event.
  final double deviationThresholdMeters;

  /// Consecutive off-route readings before [RouteDeviationDetected] fires.
  final int deviationConsecutiveCount;

  final bool enableBackground;
  final String backgroundNotificationTitle;
  final String backgroundNotificationContent;

  EngineConfig copyWith({
    Duration? heartbeatInterval,
    Duration? normalInterval,
    Duration? fastInterval,
    double? stoppedSpeedThreshold,
    double? fastSpeedThreshold,
    double? normalDistanceFilter,
    double? fastDistanceFilter,
    double? headingThresholdDegrees,
    double? kalmanProcessNoise,
    double? kalmanMeasurementNoise,
    bool? snapToRouteEnabled,
    double? deviationThresholdMeters,
    int? deviationConsecutiveCount,
    bool? enableBackground,
    String? backgroundNotificationTitle,
    String? backgroundNotificationContent,
  }) => EngineConfig(
    heartbeatInterval: heartbeatInterval ?? this.heartbeatInterval,
    normalInterval: normalInterval ?? this.normalInterval,
    fastInterval: fastInterval ?? this.fastInterval,
    stoppedSpeedThreshold: stoppedSpeedThreshold ?? this.stoppedSpeedThreshold,
    fastSpeedThreshold: fastSpeedThreshold ?? this.fastSpeedThreshold,
    normalDistanceFilter: normalDistanceFilter ?? this.normalDistanceFilter,
    fastDistanceFilter: fastDistanceFilter ?? this.fastDistanceFilter,
    headingThresholdDegrees:
        headingThresholdDegrees ?? this.headingThresholdDegrees,
    kalmanProcessNoise: kalmanProcessNoise ?? this.kalmanProcessNoise,
    kalmanMeasurementNoise:
        kalmanMeasurementNoise ?? this.kalmanMeasurementNoise,
    snapToRouteEnabled: snapToRouteEnabled ?? this.snapToRouteEnabled,
    deviationThresholdMeters:
        deviationThresholdMeters ?? this.deviationThresholdMeters,
    deviationConsecutiveCount:
        deviationConsecutiveCount ?? this.deviationConsecutiveCount,
    enableBackground: enableBackground ?? this.enableBackground,
    backgroundNotificationTitle:
        backgroundNotificationTitle ?? this.backgroundNotificationTitle,
    backgroundNotificationContent:
        backgroundNotificationContent ?? this.backgroundNotificationContent,
  );

  @override
  List<Object?> get props => [
    heartbeatInterval,
    normalInterval,
    fastInterval,
    stoppedSpeedThreshold,
    fastSpeedThreshold,
    normalDistanceFilter,
    fastDistanceFilter,
    headingThresholdDegrees,
    kalmanProcessNoise,
    kalmanMeasurementNoise,
    snapToRouteEnabled,
    deviationThresholdMeters,
    deviationConsecutiveCount,
    enableBackground,
    backgroundNotificationTitle,
    backgroundNotificationContent,
  ];
}
