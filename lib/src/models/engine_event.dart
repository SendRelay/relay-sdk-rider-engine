import 'location_update.dart';
import 'status.dart';

/// All events the [RelayDriverEngine] can emit to the app via [Stream].
sealed class EngineEvent {
  const EngineEvent();
}

/// A location update was processed and transmitted to the transport layer.
final class LocationEmitted extends EngineEvent {
  const LocationEmitted(this.update);
  final LocationUpdate update;
}

/// Driver went significantly off the known route. The app should request a
/// new polyline from the backend and call [RelayDriverEngine.updateRoute].
final class RouteDeviationDetected extends EngineEvent {
  const RouteDeviationDetected({
    required this.currentLat,
    required this.currentLng,
    required this.deviationMeters,
    required this.taskId,
  });
  final double currentLat;
  final double currentLng;
  final double deviationMeters;
  final String? taskId;
}

/// Route was updated via [RelayDriverEngine.updateRoute].
final class RouteUpdated extends EngineEvent {
  const RouteUpdated(this.waypointCount);
  final int waypointCount;
}

/// Driver status changed.
final class DriverStatusChanged extends EngineEvent {
  /// Creates a status transition event from [previous] to [current].
  const DriverStatusChanged(this.previous, this.current);

  /// Driver status before the transition.
  final DriverStatus previous;

  /// Driver status after the transition.
  final DriverStatus current;
}

/// Task context changed (new task assigned, task completed, etc).
final class TaskContextChanged extends EngineEvent {
  const TaskContextChanged({this.taskId, this.taskStatus});
  final String? taskId;
  final TaskStatus? taskStatus;
}

/// Transport connection state changed.
final class TransportStateChanged extends EngineEvent {
  const TransportStateChanged(this.connected);
  final bool connected;
}

/// A non-fatal error occurred (e.g. transport send failure).
/// Engine continues operating.
final class EngineError extends EngineEvent {
  const EngineError(this.message, {this.error});
  final String message;
  final Object? error;
}
