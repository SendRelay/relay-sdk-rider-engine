import 'package:flutter_test/flutter_test.dart';
import 'package:relay_driver_engine/src/filters/emission_policy.dart';
import 'package:relay_driver_engine/src/models/engine_config.dart';

void main() {
  final config = EngineConfig(
    heartbeatInterval: Duration(seconds: 25),
    normalInterval: Duration(seconds: 10),
    fastInterval: Duration(seconds: 3),
    stoppedSpeedThreshold: 0.5,
    fastSpeedThreshold: 12.0,
    normalDistanceFilter: 15.0,
    fastDistanceFilter: 10.0,
    headingThresholdDegrees: 20.0,
  );

  late EmissionPolicy policy;
  late DateTime base;

  setUp(() {
    policy = EmissionPolicy(config);
    base = DateTime(2025, 1, 1, 12, 0, 0);
  });

  // Helper — evaluate and record in one step
  void emit(
    DateTime t, {
    double lat = 6.5244,
    double lng = 3.3792,
    double speed = 5.0,
    double heading = 0.0,
  }) {
    policy.recordEmission(lat: lat, lng: lng, heading: heading, now: t);
  }

  // ---------------------------------------------------------------------------

  group('default mode', () {
    test('starts in heartbeatOnly mode', () {
      expect(policy.mode, EmissionMode.heartbeatOnly);
    });

    test('setMode changes mode', () {
      policy.setMode(EmissionMode.adaptive);
      expect(policy.mode, EmissionMode.adaptive);
    });

    test('reset reverts to heartbeatOnly', () {
      policy.setMode(EmissionMode.adaptive);
      policy.reset();
      expect(policy.mode, EmissionMode.heartbeatOnly);
    });
  });

  // ---------------------------------------------------------------------------

  group('first fix', () {
    test('always emits regardless of mode', () {
      for (final mode in EmissionMode.values) {
        final p = EmissionPolicy(config)..setMode(mode);
        final d = p.evaluate(
          lat: 6.5244,
          lng: 3.3792,
          speed: 0,
          heading: 0,
          now: base,
        );
        expect(
          d.shouldEmit,
          isTrue,
          reason: 'mode=$mode should emit first fix',
        );
        expect(d.reason, EmitReason.firstFix);
      }
    });
  });

  // ---------------------------------------------------------------------------

  group('heartbeatOnly mode', () {
    setUp(() => policy.setMode(EmissionMode.heartbeatOnly));

    test('suppresses movement after first fix', () {
      emit(base);
      final d = policy.evaluate(
        lat: 6.5250,
        lng: 3.3792,
        // moved
        speed: 10.0,
        heading: 0,
        now: base.add(const Duration(seconds: 5)),
      );
      expect(d.shouldEmit, isFalse);
      expect(d.reason, EmitReason.modeHeartbeatOnly);
    });

    test('suppresses heading change', () {
      emit(base, heading: 0);
      final d = policy.evaluate(
        lat: 6.5244,
        lng: 3.3792,
        speed: 2.0,
        heading: 90,
        // 90° turn
        now: base.add(const Duration(seconds: 2)),
      );
      expect(d.shouldEmit, isFalse);
      expect(d.reason, EmitReason.modeHeartbeatOnly);
    });

    test('emits on heartbeat', () {
      emit(base);
      final d = policy.evaluate(
        lat: 6.5244,
        lng: 3.3792,
        speed: 0,
        heading: 0,
        now: base.add(const Duration(seconds: 26)),
      );
      expect(d.shouldEmit, isTrue);
      expect(d.reason, EmitReason.heartbeat);
    });

    test('heartbeat fires in both modes', () {
      for (final mode in EmissionMode.values) {
        final p = EmissionPolicy(config)..setMode(mode);
        p.recordEmission(lat: 6.5244, lng: 3.3792, heading: 0, now: base);
        final d = p.evaluate(
          lat: 6.5244,
          lng: 3.3792,
          speed: 0,
          heading: 0,
          now: base.add(const Duration(seconds: 26)),
        );
        expect(
          d.shouldEmit,
          isTrue,
          reason: 'heartbeat must fire in mode=$mode',
        );
        expect(d.reason, EmitReason.heartbeat);
      }
    });
  });

  // ---------------------------------------------------------------------------

  group('adaptive mode — heartbeat', () {
    setUp(() => policy.setMode(EmissionMode.adaptive));

    test('emits after heartbeatInterval when stopped', () {
      emit(base);
      final d = policy.evaluate(
        lat: 6.5244,
        lng: 3.3792,
        speed: 0,
        heading: 0,
        now: base.add(const Duration(seconds: 26)),
      );
      expect(d.shouldEmit, isTrue);
      expect(d.reason, EmitReason.heartbeat);
    });

    test('does not emit before heartbeatInterval when stopped', () {
      emit(base);
      final d = policy.evaluate(
        lat: 6.5244,
        lng: 3.3792,
        speed: 0,
        heading: 0,
        now: base.add(const Duration(seconds: 10)),
      );
      expect(d.shouldEmit, isFalse);
      expect(d.reason, EmitReason.stopped);
    });
  });

  // ---------------------------------------------------------------------------

  group('adaptive mode — stopped suppression', () {
    setUp(() => policy.setMode(EmissionMode.adaptive));

    test('suppresses when below speed threshold and heading stable', () {
      emit(base, heading: 90);
      final d = policy.evaluate(
        lat: 6.5244,
        lng: 3.3792,
        speed: 0.3,
        heading: 92,
        // 2° — below 20° threshold
        now: base.add(const Duration(seconds: 5)),
      );
      expect(d.shouldEmit, isFalse);
      expect(d.reason, EmitReason.stopped);
    });
  });

  // ---------------------------------------------------------------------------

  group('adaptive mode — heading trigger', () {
    setUp(() => policy.setMode(EmissionMode.adaptive));

    test('emits when heading changes beyond threshold', () {
      emit(base, heading: 90);
      final d = policy.evaluate(
        lat: 6.5244,
        lng: 3.3792,
        // same position
        speed: 2.0,
        heading: 115,
        // 25° change
        now: base.add(const Duration(seconds: 2)),
      );
      expect(d.shouldEmit, isTrue);
      expect(d.reason, EmitReason.heading);
    });

    test('does not emit for heading change below threshold', () {
      emit(base, heading: 90);
      final d = policy.evaluate(
        lat: 6.5244,
        lng: 3.3792,
        speed: 2.0,
        heading: 100,
        // 10° change
        now: base.add(const Duration(seconds: 2)),
      );
      expect(d.shouldEmit, isFalse);
    });

    test('handles 359°→1° wraparound correctly (2° real delta)', () {
      emit(base, heading: 359);
      final d = policy.evaluate(
        lat: 6.5244,
        lng: 3.3792,
        speed: 2.0,
        heading: 1,
        // effectively 2°, not 358°
        now: base.add(const Duration(seconds: 2)),
      );
      expect(d.reason, isNot(EmitReason.heading));
    });

    test('handles 180°→200° (exactly 20° — at boundary)', () {
      emit(base, heading: 180);
      final d = policy.evaluate(
        lat: 6.5244,
        lng: 3.3792,
        speed: 2.0,
        heading: 200,
        now: base.add(const Duration(seconds: 2)),
      );
      expect(d.reason, EmitReason.heading);
    });

    test('stopped driver still emits on large heading change', () {
      emit(base, heading: 0);
      final d = policy.evaluate(
        lat: 6.5244,
        lng: 3.3792,
        speed: 0.2, // below stopped threshold
        heading: 90, // large change
        now: base.add(const Duration(seconds: 2)),
      );
      expect(d.shouldEmit, isTrue);
      expect(d.reason, EmitReason.heading);
    });
  });

  // ---------------------------------------------------------------------------

  group('adaptive mode — normal speed', () {
    setUp(() => policy.setMode(EmissionMode.adaptive));

    test('emits when moved >= 15m AND interval >= 10s', () {
      emit(base, lat: 6.5244, lng: 3.3792);
      final d = policy.evaluate(
        lat: 6.52455,
        lng: 3.3792,
        // ~17m north
        speed: 5.0,
        heading: 0,
        now: base.add(const Duration(seconds: 11)),
      );
      expect(d.shouldEmit, isTrue);
      expect(d.reason, EmitReason.normalMoving);
    });

    test('does not emit when moved enough but interval not met', () {
      emit(base, lat: 6.5244, lng: 3.3792);
      final d = policy.evaluate(
        lat: 6.52455,
        lng: 3.3792,
        speed: 5.0,
        heading: 0,
        now: base.add(const Duration(seconds: 5)),
      );
      expect(d.shouldEmit, isFalse);
      expect(d.reason, EmitReason.intervalNotMet);
    });

    test('does not emit when interval met but not enough movement', () {
      emit(base, lat: 6.5244, lng: 3.3792);
      final d = policy.evaluate(
        lat: 6.52441,
        lng: 3.3792,
        // ~1m
        speed: 5.0,
        heading: 0,
        now: base.add(const Duration(seconds: 11)),
      );
      expect(d.shouldEmit, isFalse);
      expect(d.reason, EmitReason.distanceNotMet);
    });

    test('emits at exact distance + interval thresholds', () {
      emit(base, lat: 6.5244, lng: 3.3792);
      final d = policy.evaluate(
        lat: 6.524535, // ~15m north
        lng: 3.3792,
        speed: 5.0,
        heading: 0,
        now: base.add(const Duration(seconds: 10)),
      );
      expect(d.shouldEmit, isTrue);
      expect(d.reason, EmitReason.normalMoving);
    });
  });

  // ---------------------------------------------------------------------------

  group('adaptive mode — fast speed', () {
    setUp(() => policy.setMode(EmissionMode.adaptive));

    test('emits at faster interval when above fast threshold', () {
      emit(base, lat: 6.5244, lng: 3.3792);
      final d = policy.evaluate(
        lat: 6.52451,
        lng: 3.3792,
        // ~12m north
        speed: 15.0,
        heading: 0,
        now: base.add(const Duration(seconds: 4)),
      );
      expect(d.shouldEmit, isTrue);
      expect(d.reason, EmitReason.fastMoving);
    });

    test(
      'does not emit fast before fastInterval even with enough distance',
      () {
        emit(base, lat: 6.5244, lng: 3.3792);
        final d = policy.evaluate(
          lat: 6.52451,
          lng: 3.3792,
          speed: 15.0,
          heading: 0,
          now: base.add(const Duration(seconds: 2)), // 2s < fastInterval(3s)
        );
        expect(d.shouldEmit, isFalse);
      },
    );

    test('fast tier triggers at speed == fastSpeedThreshold', () {
      emit(base, lat: 6.5244, lng: 3.3792);
      final d = policy.evaluate(
        lat: 6.52451,
        lng: 3.3792,
        speed: 12.0, // exactly fast threshold
        heading: 0,
        now: base.add(const Duration(seconds: 3)),
      );
      expect(d.shouldEmit, isTrue);
      expect(d.reason, EmitReason.fastMoving);
    });
  });

  // ---------------------------------------------------------------------------

  group('reset', () {
    test('reset in adaptive mode causes next call to return firstFix', () {
      policy.setMode(EmissionMode.adaptive);
      emit(base);
      policy.reset();
      final d = policy.evaluate(
        lat: 6.5244,
        lng: 3.3792,
        speed: 5,
        heading: 0,
        now: base.add(const Duration(seconds: 1)),
      );
      expect(d.reason, EmitReason.firstFix);
    });
  });
}
