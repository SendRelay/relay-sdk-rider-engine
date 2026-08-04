import 'package:flutter_test/flutter_test.dart';
import 'package:relay_driver_engine/src/filters/kalman_filter.dart';

void main() {
  group('GpsKalmanFilter', () {
    late GpsKalmanFilter filter;

    setUp(() {
      filter = GpsKalmanFilter(processNoise: 0.0001, measurementNoise: 0.0005);
    });

    test('returns raw coordinate on first fix', () {
      final (lat, lng) = filter.filter(6.5244, 3.3792, accuracyMeters: 5);
      expect(lat, equals(6.5244));
      expect(lng, equals(3.3792));
    });

    test('converges toward true position over successive readings', () {
      // Simulate a stationary driver with noisy GPS (±30m scale)
      const trueLat = 6.5244;
      const trueLng = 3.3792;
      final noisy = [
        (6.5244 + 0.0003, 3.3792 - 0.0002),
        (6.5244 - 0.0002, 3.3792 + 0.0003),
        (6.5244 + 0.0002, 3.3792 + 0.0001),
        (6.5244 - 0.0001, 3.3792 - 0.0002),
        (6.5244 + 0.0001, 3.3792 + 0.0001),
      ];

      double firstLatError = double.infinity;
      double lastLat = 0, lastLng = 0;

      for (int i = 0; i < noisy.length; i++) {
        final (rawLat, rawLng) = noisy[i];
        final (lat, lng) = filter.filter(rawLat, rawLng, accuracyMeters: 10);
        if (i == 0) firstLatError = (lat - trueLat).abs();
        lastLat = lat;
        lastLng = lng;
      }

      final finalLatError = (lastLat - trueLat).abs();
      final finalLngError = (lastLng - trueLng).abs();

      // Kalman guarantees convergence over a sequence — not per-sample.
      // After 5 readings the estimate should be closer than the first filtered output.
      expect(
        finalLatError,
        lessThan(firstLatError),
        reason: 'Filter must converge toward truth over multiple readings',
      );

      // And overall error should be small after 5 readings
      expect(finalLatError, lessThan(0.0002));
      expect(finalLngError, lessThan(0.0002));
    });

    test('trusts high-accuracy fix more than low-accuracy fix', () {
      // Seed filter
      filter.filter(6.5244, 3.3792, accuracyMeters: 5);

      // Same offset reading — high accuracy vs low accuracy
      const offset = 0.001;

      final filterA = GpsKalmanFilter(
        processNoise: 0.0001,
        measurementNoise: 0.0005,
      );
      filterA.filter(6.5244, 3.3792, accuracyMeters: 5);
      final (latA, _) = filterA.filter(
        6.5244 + offset,
        3.3792,
        accuracyMeters: 3,
      );

      final filterB = GpsKalmanFilter(
        processNoise: 0.0001,
        measurementNoise: 0.0005,
      );
      filterB.filter(6.5244, 3.3792, accuracyMeters: 5);
      final (latB, _) = filterB.filter(
        6.5244 + offset,
        3.3792,
        accuracyMeters: 50,
      );

      // High accuracy filter should pull toward measurement more aggressively
      expect(latA, greaterThan(latB));
    });

    test('re-seeds after a long gap when timestamps are provided', () {
      final t0 = DateTime(2024, 1, 1, 12, 0, 0);
      filter.filter(6.5244, 3.3792, accuracyMeters: 5, timestamp: t0);
      filter.filter(
        6.5244,
        3.3792,
        accuracyMeters: 5,
        timestamp: t0.add(const Duration(seconds: 1)),
      );

      // 31s gap exceeds the default maxGapSeconds (20) → estimate is stale,
      // so the filter re-seeds and returns the new fix unchanged.
      final (lat, lng) = filter.filter(
        9.0765,
        7.3986,
        accuracyMeters: 5,
        timestamp: t0.add(const Duration(seconds: 32)),
      );
      expect(lat, equals(9.0765));
      expect(lng, equals(7.3986));
    });

    test('reset causes next reading to be returned as-is', () {
      filter.filter(6.5244, 3.3792, accuracyMeters: 5);
      filter.filter(6.5244, 3.3792, accuracyMeters: 5);
      filter.reset();

      const newLat = 9.0765;
      const newLng = 7.3986;
      final (lat, lng) = filter.filter(newLat, newLng, accuracyMeters: 5);
      expect(lat, equals(newLat));
      expect(lng, equals(newLng));
    });

    test(
      'does not diverge on large sudden jump (driver resumes after gap)',
      () {
        // Stationary in Lagos
        for (int i = 0; i < 10; i++) {
          filter.filter(6.5244, 3.3792, accuracyMeters: 5);
        }
        // Jumps to Abuja
        final (lat, lng) = filter.filter(9.0765, 7.3986, accuracyMeters: 10);
        // Should be between old and new estimate, pulled toward Abuja
        expect(lat, greaterThan(6.5244));
        expect(lng, greaterThan(3.3792));
      },
    );
  });
}
