/// The online presence state of the driver.
///
/// Maps directly to the DriverPresence TTL model on the Relay backend:
/// - [online]  → presence record is active; location updates are flowing
/// - [busy]    → driver has an active task; presence record remains active
/// - [offline] → engine stops emitting; backend TTL will expire the record
enum DriverStatus { online, busy, offline }

/// The lifecycle status of a task, mirroring Relay's backend task model.
enum TaskStatus {
  pending,
  offered,
  assigned,
  inProgress,
  completed,
  cancelled,
  failed,
  paymentFailed,
}

/// The status of an individual task stage.
enum StageStatus { pending, inProgress, completed }

/// Convenience helpers for converting [TaskStatus] values.
extension TaskStatusX on TaskStatus {
  /// Backend enum string representation for transport payloads.
  String get value => switch (this) {
    TaskStatus.pending => 'PENDING',
    TaskStatus.offered => 'OFFERED',
    TaskStatus.assigned => 'ASSIGNED',
    TaskStatus.inProgress => 'IN_PROGRESS',
    TaskStatus.completed => 'COMPLETED',
    TaskStatus.cancelled => 'CANCELLED',
    TaskStatus.failed => 'FAILED',
    TaskStatus.paymentFailed => 'PAYMENT_FAILED',
  };

  /// Whether this status implies an active trip requiring
  /// high-frequency location updates.
  bool get isActiveTrip =>
      this == TaskStatus.inProgress || this == TaskStatus.assigned;
}

/// Convenience helpers for converting [DriverStatus] values.
extension DriverStatusX on DriverStatus {
  /// Backend enum string representation for transport payloads.
  String get value => name.toUpperCase();

  /// Whether the engine should be emitting location updates.
  bool get shouldEmit => this != DriverStatus.offline;
}
