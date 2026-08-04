import 'package:flutter_test/flutter_test.dart';
import 'package:relay_driver_engine/src/models/engine_config.dart';

void main() {
  test('EngineConfig is equatable for identical values', () {
    expect(EngineConfig(), equals(EngineConfig()));
  });

  test('copyWith overrides only provided fields', () {
    final base = EngineConfig();
    final updated = base.copyWith(
      fastInterval: const Duration(seconds: 2),
      snapToRouteEnabled: false,
    );

    expect(updated.fastInterval, const Duration(seconds: 2));
    expect(updated.snapToRouteEnabled, isFalse);
    // Unchanged fields remain the same
    expect(updated.heartbeatInterval, base.heartbeatInterval);
    expect(updated.normalInterval, base.normalInterval);
    expect(updated.stoppedSpeedThreshold, base.stoppedSpeedThreshold);
  });

  test('asserts when heartbeatInterval is not greater than normalInterval', () {
    expect(
      () => EngineConfig(
        heartbeatInterval: const Duration(seconds: 10),
        normalInterval: const Duration(seconds: 10),
        fastInterval: const Duration(seconds: 3),
      ),
      throwsA(isA<AssertionError>()),
    );
  });

  test('asserts when headingThresholdDegrees is out of bounds', () {
    expect(
      () => EngineConfig(headingThresholdDegrees: 180),
      throwsA(isA<AssertionError>()),
    );
  });
}
