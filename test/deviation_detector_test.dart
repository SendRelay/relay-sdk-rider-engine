import 'package:flutter_test/flutter_test.dart';
import 'package:relay_driver_engine/src/routing/deviation_detector.dart';
import 'package:relay_driver_engine/src/models/engine_config.dart';

void main() {
  final config = EngineConfig(
    deviationThresholdMeters: 80,
    deviationConsecutiveCount: 3,
  );

  late DeviationDetector detector;

  setUp(() => detector = DeviationDetector(config));

  test('does not fire on single off-route reading', () {
    expect(detector.record(100), isFalse);
  });

  test('does not fire on two consecutive off-route readings', () {
    detector.record(100);
    expect(detector.record(100), isFalse);
  });

  test('fires on third consecutive off-route reading', () {
    detector.record(100);
    detector.record(100);
    expect(detector.record(100), isTrue);
  });

  test('fires exactly once per deviation episode', () {
    detector.record(100);
    detector.record(100);
    detector.record(100); // fires
    expect(
      detector.record(100),
      isFalse,
    ); // same episode — should NOT fire again
    expect(detector.record(100), isFalse);
  });

  test('returning to route re-arms — new episode fires again', () {
    detector.record(100);
    detector.record(100);
    detector.record(5); // back on route — episode over, detector re-armed
    detector.record(100);
    detector.record(100);
    expect(
      detector.record(100),
      isTrue,
    ); // fresh episode reaches the threshold and fires
  });

  test('transient sub-threshold blip does not disarm later detection', () {
    // A short excursion (below the consecutive-count threshold) that recovers
    // must not stop a genuine deviation from firing afterwards.
    detector.record(100); // 1 off-route (threshold is 3)
    detector.record(5); // recovered — re-armed
    detector.record(100);
    detector.record(100);
    expect(detector.record(100), isTrue); // genuine deviation still fires
  });

  test('re-fires on a second deviation after returning to route', () {
    detector.record(100);
    detector.record(100);
    expect(detector.record(100), isTrue); // first episode fires
    detector.record(5); // back on route
    detector.record(100);
    detector.record(100);
    expect(detector.record(100), isTrue); // second episode fires too
  });

  test('reset re-arms the detector for next deviation episode', () {
    detector.record(100);
    detector.record(100);
    detector.record(100); // first episode fires

    detector.reset(); // route was updated

    detector.record(100);
    detector.record(100);
    expect(detector.record(100), isTrue); // second episode fires
  });

  test('on-route readings (<=threshold) never fire', () {
    for (int i = 0; i < 10; i++) {
      expect(detector.record(79), isFalse);
    }
  });

  test('exactly at threshold (80m) is treated as on-route', () {
    for (int i = 0; i < 5; i++) {
      expect(detector.record(80), isFalse);
    }
  });

  test('just above threshold (80.1m) counts as off-route', () {
    detector.record(80.1);
    detector.record(80.1);
    expect(detector.record(80.1), isTrue);
  });

  test('fires immediately when consecutiveCount is 1', () {
    final singleConfig = EngineConfig(
      deviationThresholdMeters: 80,
      deviationConsecutiveCount: 1,
    );
    final singleDetector = DeviationDetector(singleConfig);

    expect(singleDetector.record(100), isTrue);
    // Subsequent off-route readings in same episode should not fire again
    expect(singleDetector.record(100), isFalse);
  });
}
