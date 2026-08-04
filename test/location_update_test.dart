import 'package:flutter_test/flutter_test.dart';
import 'package:relay_driver_engine/src/models/location_update.dart';
import 'package:relay_driver_engine/src/models/status.dart';

void main() {
  final ts = DateTime(2025, 1, 1, 12, 0, 0);

  LocationUpdate buildUpdate({
    TaskStatus? taskStatus,
    String? taskId,
    bool isHeartbeat = false,
  }) {
    return LocationUpdate(
      lat: 6.5244,
      lng: 3.3792,
      rawLat: 6.5245,
      rawLng: 3.3791,
      heading: 12.0,
      speed: 4.2,
      accuracyMeters: 5.0,
      timestamp: ts,
      driverStatus: DriverStatus.busy,
      taskStatus: taskStatus,
      taskId: taskId,
      isSnapped: true,
      snappedSegmentIndex: null,
      deviationMeters: 7.5,
      isHeartbeat: isHeartbeat,
    );
  }

  test('toJson omits task fields when null', () {
    final update = buildUpdate();
    final json = update.toJson();

    expect(json.containsKey('taskStatus'), isFalse);
    expect(json.containsKey('taskId'), isFalse);
    expect(json['isHeartbeat'], isFalse);
  });

  test('toJson includes task fields when provided', () {
    final update = buildUpdate(
      taskStatus: TaskStatus.assigned,
      taskId: 'task_1',
    );
    final json = update.toJson();

    expect(json['taskStatus'], equals('ASSIGNED'));
    expect(json['taskId'], equals('task_1'));
  });

  test('equatable compares all relevant fields', () {
    final a = buildUpdate();
    final b = buildUpdate();
    final c = buildUpdate(isHeartbeat: true);

    expect(a, equals(b));
    expect(a, isNot(equals(c)));
  });
}
