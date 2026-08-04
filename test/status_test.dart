import 'package:flutter_test/flutter_test.dart';
import 'package:relay_driver_engine/src/models/status.dart';

void main() {
  test('DriverStatus.value mapping is uppercase', () {
    expect(DriverStatus.online.value, equals('ONLINE'));
    expect(DriverStatus.busy.value, equals('BUSY'));
    expect(DriverStatus.offline.value, equals('OFFLINE'));
  });

  test('DriverStatus.shouldEmit is false only for offline', () {
    expect(DriverStatus.offline.shouldEmit, isFalse);
    expect(DriverStatus.online.shouldEmit, isTrue);
    expect(DriverStatus.busy.shouldEmit, isTrue);
  });

  test('TaskStatus.value mapping matches backend enums', () {
    expect(TaskStatus.pending.value, equals('PENDING'));
    expect(TaskStatus.offered.value, equals('OFFERED'));
    expect(TaskStatus.assigned.value, equals('ASSIGNED'));
    expect(TaskStatus.inProgress.value, equals('IN_PROGRESS'));
    expect(TaskStatus.completed.value, equals('COMPLETED'));
    expect(TaskStatus.cancelled.value, equals('CANCELLED'));
    expect(TaskStatus.failed.value, equals('FAILED'));
    expect(TaskStatus.paymentFailed.value, equals('PAYMENT_FAILED'));
  });

  test('TaskStatus.isActiveTrip only for assigned/inProgress', () {
    expect(TaskStatus.assigned.isActiveTrip, isTrue);
    expect(TaskStatus.inProgress.isActiveTrip, isTrue);

    for (final status in [
      TaskStatus.pending,
      TaskStatus.offered,
      TaskStatus.completed,
      TaskStatus.cancelled,
      TaskStatus.failed,
      TaskStatus.paymentFailed,
    ]) {
      expect(status.isActiveTrip, isFalse, reason: 'status=$status');
    }
  });
}
