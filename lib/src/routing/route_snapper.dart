import 'dart:math';

/// A lat/lng coordinate pair.
typedef LatLng = ({double lat, double lng});

/// Result of a snap operation.
class SnapResult {
  const SnapResult({
    required this.snapped,
    required this.deviationMeters,
    required this.segmentIndex,
    required this.wasSnapped,
  });

  /// The road-snapped coordinate (or the original if deviation > threshold).
  final LatLng snapped;

  /// Distance in metres between the raw GPS point and the nearest road point.
  final double deviationMeters;

  /// Which polyline segment the snap landed on.
  final int segmentIndex;

  /// False if deviation exceeded threshold — raw coordinate was returned.
  final bool wasSnapped;
}

/// Snaps a raw GPS coordinate to the nearest point on a route polyline.
///
/// The snapping is pure geometry — no network call — making it safe to run
/// synchronously in the GPS update hot path.
class RouteSnapper {
  RouteSnapper({this.deviationThresholdMeters = 80.0});

  final double deviationThresholdMeters;

  /// How many segments either side of the last match to search before falling
  /// back to a full scan. Drivers progress monotonically along the route, so
  /// the nearest segment is almost always near the previous one — this turns
  /// the per-fix cost from O(route length) into O(window) on the hot path.
  static const int _searchWindow = 8;

  List<LatLng> _polyline = [];
  int _lastSegment = 0;

  bool get hasRoute => _polyline.length >= 2;

  void updateRoute(List<LatLng> polyline) {
    _polyline = List.unmodifiable(polyline);
    _lastSegment = 0;
  }

  void clearRoute() {
    _polyline = [];
    _lastSegment = 0;
  }

  /// Snap [raw] to the current route polyline.
  ///
  /// If no route is loaded, returns [raw] with 0 deviation.
  /// If deviation > [deviationThresholdMeters], returns [raw] unmodified
  /// (driver is genuinely off-route, not GPS noise).
  SnapResult snap(LatLng raw) {
    if (!hasRoute) {
      return SnapResult(
        snapped: raw,
        deviationMeters: 0,
        segmentIndex: 0,
        wasSnapped: false,
      );
    }

    final lastSegmentIndex = _polyline.length - 2;

    // Longitude degrees shrink with latitude; scale them so the planar
    // projection below is metric-accurate (equirectangular), not skewed by
    // treating 1° lat and 1° lng as equal.
    final cosLat = cos(raw.lat * pi / 180);

    // Search a window around the last matched segment first.
    final lo = max(0, _lastSegment - _searchWindow);
    final hi = min(lastSegmentIndex, _lastSegment + _searchWindow);
    var best = _scanRange(raw, cosLat, lo, hi);

    // If the windowed best is off-route and the window didn't cover the whole
    // route, the driver may have jumped (GPS recovery, manual reroute) — do a
    // full scan so correctness never depends on the monotonic-progress
    // assumption.
    if (best.dist > deviationThresholdMeters &&
        (lo > 0 || hi < lastSegmentIndex)) {
      final full = _scanRange(raw, cosLat, 0, lastSegmentIndex);
      if (full.dist < best.dist) best = full;
    }

    _lastSegment = best.segment;
    final shouldSnap = best.dist <= deviationThresholdMeters;

    return SnapResult(
      snapped: shouldSnap ? best.point : raw,
      deviationMeters: best.dist,
      segmentIndex: best.segment,
      wasSnapped: shouldSnap,
    );
  }

  /// Finds the closest point on segments [lo, hi] (inclusive) to [raw].
  ({double dist, LatLng point, int segment}) _scanRange(
    LatLng raw,
    double cosLat,
    int lo,
    int hi,
  ) {
    var minDist = double.infinity;
    LatLng closest = _polyline[lo];
    int closestSegment = lo;

    for (int i = lo; i <= hi; i++) {
      final a = _polyline[i];
      final b = _polyline[i + 1];

      // Project in scaled planar space (x = lng·cosLat, y = lat)…
      final abx = (b.lng - a.lng) * cosLat, aby = b.lat - a.lat;
      final apx = (raw.lng - a.lng) * cosLat, apy = raw.lat - a.lat;
      final ab2 = abx * abx + aby * aby;

      final t = ab2 == 0 ? 0.0 : (apx * abx + apy * aby) / ab2;
      final clamped = t.clamp(0.0, 1.0);
      // …then map the parameter back onto the real (unscaled) segment.
      final projectedClamped = (
        lat: a.lat + clamped * (b.lat - a.lat),
        lng: a.lng + clamped * (b.lng - a.lng),
      );

      // Deviation is measured against the nearest point on the actual segment,
      // not the infinite line extension.
      final dist = haversineMeters(raw, projectedClamped);

      if (dist < minDist) {
        minDist = dist;
        closest = projectedClamped;
        closestSegment = i;
      }
    }

    return (dist: minDist, point: closest, segment: closestSegment);
  }

  // ---------------------------------------------------------------------------
  // Geometry helpers — kept internal and pure so tests can exercise them easily

  /// Haversine distance in metres between two coordinates.
  static double haversineMeters(LatLng a, LatLng b) {
    const r = 6371000.0;
    final dLat = (b.lat - a.lat) * pi / 180;
    final dLng = (b.lng - a.lng) * pi / 180;
    final sinLat = sin(dLat / 2);
    final sinLng = sin(dLng / 2);
    final chord =
        sinLat * sinLat +
        cos(a.lat * pi / 180) * cos(b.lat * pi / 180) * sinLng * sinLng;
    return r * 2 * atan2(sqrt(chord), sqrt(1 - chord));
  }
}
