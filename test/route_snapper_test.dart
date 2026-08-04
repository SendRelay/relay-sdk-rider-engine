import 'package:flutter_test/flutter_test.dart';
import 'package:relay_driver_engine/src/routing/route_snapper.dart';

void main() {
  // Simple horizontal segment: Lagos Island heading east
  const a = (lat: 6.4550, lng: 3.3900);
  const b = (lat: 6.4550, lng: 3.4000); // ~1100m east of a

  late RouteSnapper snapper;

  setUp(() {
    snapper = RouteSnapper(deviationThresholdMeters: 80);
  });

  group('hasRoute', () {
    test('false before route loaded', () => expect(snapper.hasRoute, isFalse));

    test('true after loading 2+ point route', () {
      snapper.updateRoute([a, b]);
      expect(snapper.hasRoute, isTrue);
    });

    test('false after clearRoute', () {
      snapper.updateRoute([a, b]);
      snapper.clearRoute();
      expect(snapper.hasRoute, isFalse);
    });
  });

  group('snap — no route', () {
    test('returns raw coordinate with 0 deviation', () {
      const raw = (lat: 6.4555, lng: 3.3950);
      final result = snapper.snap(raw);
      expect(result.snapped.lat, equals(raw.lat));
      expect(result.snapped.lng, equals(raw.lng));
      expect(result.deviationMeters, equals(0));
      expect(result.wasSnapped, isFalse);
    });
  });

  group('snap — on route', () {
    setUp(() => snapper.updateRoute([a, b]));

    test('point directly on segment snaps with near-zero deviation', () {
      const onRoute = (lat: 6.4550, lng: 3.3950); // midpoint
      final result = snapper.snap(onRoute);
      expect(result.deviationMeters, lessThan(1.0));
      expect(result.wasSnapped, isTrue);
    });

    test('point slightly off route (20m) is snapped onto road', () {
      // ~20m north of segment midpoint
      const slightlyOff = (lat: 6.45518, lng: 3.3950);
      final result = snapper.snap(slightlyOff);
      expect(result.wasSnapped, isTrue);
      expect(result.deviationMeters, lessThan(80));
      // Snapped lat should be closer to segment lat
      expect(result.snapped.lat, lessThan(slightlyOff.lat));
    });

    test('point slightly beyond endpoint snaps to nearest endpoint', () {
      // ~40m past b (still within 80m threshold)
      const pastEnd = (lat: 6.4550, lng: 3.40036);
      final result = snapper.snap(pastEnd);
      expect(result.wasSnapped, isTrue);
      // Should snap to endpoint b
      expect(result.snapped.lng, closeTo(b.lng, 0.0001));
    });

    test('point slightly before start snaps to start point', () {
      // ~40m before a (still within 80m threshold)
      const beforeStart = (lat: 6.4550, lng: 3.38964);
      final result = snapper.snap(beforeStart);
      expect(result.wasSnapped, isTrue);
      expect(result.snapped.lng, closeTo(a.lng, 0.0001));
    });

    test('deviation at threshold still snaps (inclusive)', () {
      const raw = (lat: 6.45509, lng: 3.3950); // ~10m north of segment
      final deviation = RouteSnapper.haversineMeters(raw, (
        lat: 6.4550,
        lng: 3.3950,
      ));

      snapper = RouteSnapper(deviationThresholdMeters: deviation);
      snapper.updateRoute([a, b]);

      final result = snapper.snap(raw);
      expect(result.wasSnapped, isTrue);
      expect(result.deviationMeters, lessThanOrEqualTo(deviation));
    });
  });

  group('snap — deviation beyond threshold', () {
    setUp(() => snapper.updateRoute([a, b]));

    test('point >80m off route returns raw coordinate', () {
      // ~200m north — genuine deviation
      const farOff = (lat: 6.4568, lng: 3.3950);
      final result = snapper.snap(farOff);
      expect(result.wasSnapped, isFalse);
      expect(result.snapped.lat, equals(farOff.lat));
      expect(result.snapped.lng, equals(farOff.lng));
      expect(result.deviationMeters, greaterThan(80));
    });

    test('point far beyond endpoint on same line does not snap', () {
      // ~1.1km past b: colinear with segment but beyond threshold to endpoint
      const farPastEnd = (lat: 6.4550, lng: 3.4100);
      final result = snapper.snap(farPastEnd);
      expect(result.wasSnapped, isFalse);
      expect(result.snapped.lat, equals(farPastEnd.lat));
      expect(result.snapped.lng, equals(farPastEnd.lng));
      expect(result.deviationMeters, greaterThan(80));
    });
  });

  group('snap — multi-segment polyline', () {
    test('snaps to correct segment out of three', () {
      const c = (lat: 6.4600, lng: 3.4000); // turn north at b
      snapper.updateRoute([a, b, c]);

      // Point near the b→c segment (northward leg)
      const nearNorthLeg = (lat: 6.4575, lng: 3.4005);
      final result = snapper.snap(nearNorthLeg);
      expect(result.wasSnapped, isTrue);
      expect(result.segmentIndex, equals(1)); // second segment (b→c)
    });
  });

  group('snap — windowed search', () {
    test('finds a far segment after a jump beyond the search window', () {
      // ~20-point straight route heading east (~110m between points).
      final pts = <({double lat, double lng})>[
        for (int i = 0; i < 20; i++) (lat: 6.4550, lng: 3.3900 + i * 0.0010),
      ];
      snapper.updateRoute(pts);

      // Snap near the start, advancing the internal cursor toward segment 0.
      snapper.snap((lat: 6.4550, lng: 3.3901));

      // Now a point on vertex 15 — well beyond the 8-segment window. The
      // full-scan fallback must still find it.
      final result = snapper.snap((lat: 6.4550, lng: 3.3900 + 15 * 0.0010));
      expect(result.wasSnapped, isTrue);
      expect(result.segmentIndex, greaterThanOrEqualTo(14));
      expect(result.deviationMeters, lessThan(1.0));
    });
  });

  group('snap — zero-length segment', () {
    test('handles duplicate points without crashing', () {
      snapper.updateRoute([a, a, b]); // first segment has zero length
      const nearA = (lat: 6.4550, lng: 3.3900);
      final result = snapper.snap(nearA);

      expect(result.wasSnapped, isTrue);
      expect(result.segmentIndex, equals(0));
      expect(result.snapped.lat, closeTo(a.lat, 0.000001));
      expect(result.snapped.lng, closeTo(a.lng, 0.000001));
    });
  });

  group('updateRoute hot-swap', () {
    test('snapper uses new polyline after updateRoute', () {
      snapper.updateRoute([a, b]);
      // New route goes north from a
      const c = (lat: 6.4600, lng: 3.3900);
      snapper.updateRoute([a, c]);

      // Point on the new north route
      const onNewRoute = (lat: 6.4575, lng: 3.3900);
      final result = snapper.snap(onNewRoute);
      expect(result.deviationMeters, lessThan(10));
    });
  });

  group('haversineMeters', () {
    test('distance between same point is 0', () {
      expect(RouteSnapper.haversineMeters(a, a), equals(0));
    });

    test('distance between Lagos and Abuja is ~526km', () {
      const lagos = (lat: 6.5244, lng: 3.3792);
      const abuja = (lat: 9.0765, lng: 7.3986);
      final dist = RouteSnapper.haversineMeters(lagos, abuja);
      expect(dist, greaterThan(500000));
      expect(dist, lessThan(560000));
    });
  });
}
