import 'package:equatable/equatable.dart';
import 'status.dart';

/// A processed, ready-to-transmit location payload.
///
/// Coordinates here are post-Kalman and post-snap (if enabled).
/// [rawLat]/[rawLng] preserve the original GPS reading for diagnostics.
class LocationUpdate extends Equatable {
  const LocationUpdate({
    required this.lat,
    required this.lng,
    required this.rawLat,
    required this.rawLng,
    required this.heading,
    required this.speed,
    required this.accuracyMeters,
    required this.timestamp,
    required this.driverStatus,
    required this.taskStatus,
    required this.taskId,
    required this.isSnapped,
    required this.deviationMeters,
    required this.snappedSegmentIndex,
    this.isHeartbeat = false,
  });

  final double lat;
  final double lng;
  final double rawLat;
  final double rawLng;
  final double heading; // degrees 0–360
  final double speed; // m/s
  final double accuracyMeters;
  final DateTime timestamp;
  final DriverStatus driverStatus;
  final TaskStatus? taskStatus;
  final String? taskId;
  final bool isSnapped;
  final int? snappedSegmentIndex; // null when not snapped
  final double deviationMeters;

  /// True when emitted purely to keep the backend DriverPresence TTL alive,
  /// not because the driver meaningfully moved.
  final bool isHeartbeat;

  Map<String, dynamic> toJson() => {
    'lat': lat,
    'lng': lng,
    'rawLat': rawLat,
    'rawLng': rawLng,
    'heading': heading,
    'speed': speed,
    'accuracyMeters': accuracyMeters,
    'ts': timestamp.millisecondsSinceEpoch,
    'driverStatus': driverStatus.value,
    if (taskStatus != null) 'taskStatus': taskStatus!.value,
    if (taskId != null) 'taskId': taskId,
    if (snappedSegmentIndex != null) 'segmentIndex': snappedSegmentIndex,
    'isSnapped': isSnapped,
    'deviationMeters': deviationMeters,
    'isHeartbeat': isHeartbeat,
  };

  @override
  List<Object?> get props => [
    lat,
    lng,
    heading,
    speed,
    timestamp,
    driverStatus,
    taskStatus,
    taskId,
    isSnapped,
    snappedSegmentIndex,
    deviationMeters,
    isHeartbeat,
  ];
}
