import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:geolocator/geolocator.dart';
import 'package:relay_driver_engine/relay_driver_engine.dart';

// ---------------------------------------------------------------------------
// Mock transport

class MockTransport implements RelayTransportAdapter {
  final _connectionController = StreamController<bool>.broadcast();
  final List<Map<String, dynamic>> sent = [];
  bool connected = false;

  @override
  void Function(Object error)? onError;

  @override
  Stream<bool> get connectionState => _connectionController.stream;

  @override
  Future<void> connect() async {
    connected = true;
    if (!_connectionController.isClosed) _connectionController.add(true);
  }

  @override
  Future<void> send(Map<String, dynamic> payload) async {
    sent.add(Map.unmodifiable(payload));
  }

  @override
  Future<void> disconnect() async {
    connected = false;
    if (!_connectionController.isClosed) {
      _connectionController.add(false);
      await _connectionController.close();
    }
  }

  void simulateDrop() {
    if (!_connectionController.isClosed) _connectionController.add(false);
  }

  void simulateReconnect() {
    if (!_connectionController.isClosed) _connectionController.add(true);
  }
}

class FailingTransport extends MockTransport {
  @override
  Future<void> send(Map<String, dynamic> payload) async {
    throw Exception('send failed');
  }
}

class FlakyTransport extends MockTransport {
  FlakyTransport({this.failuresBeforeSuccess = 1});

  int failuresBeforeSuccess;

  @override
  Future<void> send(Map<String, dynamic> payload) async {
    if (failuresBeforeSuccess > 0) {
      failuresBeforeSuccess--;
      throw Exception('transient send failure');
    }
    sent.add(Map.unmodifiable(payload));
  }
}

// ---------------------------------------------------------------------------
// Helpers

Position makePosition({
  double lat = 6.5244,
  double lng = 3.3792,
  double speed = 5.0,
  double heading = 0.0,
  double accuracy = 5.0,
}) => Position(
  latitude: lat,
  longitude: lng,
  speed: speed,
  heading: heading,
  accuracy: accuracy,
  altitude: 0,
  altitudeAccuracy: 0,
  headingAccuracy: 0,
  speedAccuracy: 0,
  timestamp: DateTime.now(),
);

/// Creates a test engine with an injected position stream so no real GPS is needed.
RelayDriverEngine makeEngine({
  required MockTransport transport,
  required StreamController<Position> locationCtrl,
  EngineConfig? config,
}) => RelayDriverEngine(
  transport: transport,
  engineConfig: config ?? EngineConfig(),
  locationStream: locationCtrl.stream,
);

/// Puts engine into fully active (adaptive) mode: busy + inProgress task.
Future<void> activateEngine(
  RelayDriverEngine engine, {
  String taskId = 'task_test',
}) async {
  await engine.setDriverStatus(DriverStatus.busy);
  await engine.setTaskContext(taskId: taskId, status: TaskStatus.inProgress);
}

// ---------------------------------------------------------------------------

void main() {
  group('RelayDriverEngine — lifecycle', () {
    late MockTransport transport;
    late StreamController<Position> locationCtrl;
    late RelayDriverEngine engine;

    setUp(() {
      transport = MockTransport();
      locationCtrl = StreamController<Position>.broadcast();
      engine = makeEngine(transport: transport, locationCtrl: locationCtrl);
    });

    tearDown(() async {
      await engine.dispose();
      await locationCtrl.close();
    });

    test('does not emit when offline', () async {
      await engine.start();
      // driver stays offline — never call setDriverStatus
      locationCtrl.add(makePosition());
      await Future.delayed(const Duration(milliseconds: 50));
      // Only the driver:offline signal (if any) should be present — no location payloads
      final locationPayloads = transport.sent.where(
        (p) => !p.containsKey('event'),
      );
      expect(locationPayloads, isEmpty);
    });

    test('emits first fix in heartbeatOnly (online) mode', () async {
      await engine.start();
      await engine.setDriverStatus(DriverStatus.online);

      locationCtrl.add(makePosition());
      await Future.delayed(const Duration(milliseconds: 50));

      expect(transport.sent.length, equals(1));
    });

    test(
      'heartbeatOnly mode suppresses movement-based emissions after first fix',
      () async {
        await engine.start();
        await engine.setDriverStatus(DriverStatus.online);

        // First fix — emits
        locationCtrl.add(makePosition(heading: 0));
        await Future.delayed(const Duration(milliseconds: 30));
        final afterFirst = transport.sent.length;

        // Movement and heading change — should be suppressed in heartbeatOnly
        locationCtrl.add(makePosition(heading: 90));
        locationCtrl.add(makePosition(lat: 6.5250, heading: 45));
        await Future.delayed(const Duration(milliseconds: 50));

        expect(transport.sent.length, equals(afterFirst));
      },
    );

    test('adaptive mode emits when driver is busy + inProgress', () async {
      await engine.start();
      await activateEngine(engine);

      expect(engine.emissionMode, EmissionMode.adaptive);

      locationCtrl.add(makePosition());
      await Future.delayed(const Duration(milliseconds: 50));

      expect(transport.sent.length, equals(1));
    });

    test(
      'emissionMode reverts to heartbeatOnly after clearTaskContext',
      () async {
        await engine.start();
        await activateEngine(engine);
        await engine.clearTaskContext();

        expect(engine.emissionMode, EmissionMode.heartbeatOnly);
      },
    );

    test('going offline sends driver:offline signal', () async {
      await engine.start();
      await engine.setDriverStatus(DriverStatus.online);
      await engine.setDriverStatus(DriverStatus.offline);

      expect(transport.sent.any((p) => p['event'] == 'driver:offline'), isTrue);
    });

    test('offline gate stops emissions immediately', () async {
      await engine.start();
      await activateEngine(engine);
      await engine.setDriverStatus(DriverStatus.offline);

      final countBefore = transport.sent.length;
      locationCtrl.add(makePosition());
      await Future.delayed(const Duration(milliseconds: 50));

      expect(transport.sent.length, equals(countBefore));
    });

    test('resumes emitting after offline → online (GPS re-subscribes)', () async {
      await engine.start();
      await engine.setDriverStatus(DriverStatus.online);

      locationCtrl.add(makePosition());
      await Future.delayed(const Duration(milliseconds: 30));
      final afterOnline = transport.sent.length;
      expect(afterOnline, greaterThan(0));

      // Clock out (cancels the GPS subscription) then back in (re-subscribes).
      await engine.setDriverStatus(DriverStatus.offline);
      await engine.setDriverStatus(DriverStatus.online);

      locationCtrl.add(makePosition(lat: 6.5300));
      await Future.delayed(const Duration(milliseconds: 30));
      expect(transport.sent.length, greaterThan(afterOnline));
    });

    test('stop cancels location subscription', () async {
      await engine.start();
      await activateEngine(engine);
      await engine.stop();

      final countBefore = transport.sent.length;
      locationCtrl.add(makePosition());
      await Future.delayed(const Duration(milliseconds: 50));

      expect(transport.sent.length, equals(countBefore));
    });

    test('start is idempotent', () async {
      await engine.start();
      await engine.start();
      expect(engine.isRunning, isTrue);
    });

    test('stop is idempotent', () async {
      await engine.start();
      await engine.stop();
      await engine.stop(); // should not throw
      expect(engine.isRunning, isFalse);
    });

    test('setDriverStatus is a no-op if status unchanged', () async {
      await engine.start();

      // Subscribe BEFORE any status changes so we can observe all events
      final stateEvents = <DriverStatusChanged>[];
      engine.events
          .where((e) => e is DriverStatusChanged)
          .listen((e) => stateEvents.add(e as DriverStatusChanged));

      await engine.setDriverStatus(DriverStatus.online); // fires event
      final countAfterFirst = stateEvents.length;
      expect(countAfterFirst, equals(1)); // one event fired

      await engine.setDriverStatus(DriverStatus.online); // duplicate — no-op

      await Future.delayed(const Duration(milliseconds: 30));

      // Duplicate call must not emit a second event
      expect(stateEvents.length, equals(countAfterFirst));
    });

    test(
      'task context does not enable adaptive mode while driver is online',
      () async {
        await engine.start();
        await engine.setDriverStatus(DriverStatus.online);
        await engine.setTaskContext(
          taskId: 'task_online',
          status: TaskStatus.inProgress,
        );

        expect(engine.emissionMode, EmissionMode.heartbeatOnly);
      },
    );
  });

  // ---------------------------------------------------------------------------

  group('RelayDriverEngine — adaptive emission suppression', () {
    late MockTransport transport;
    late StreamController<Position> locationCtrl;

    final fastConfig = EngineConfig(
      heartbeatInterval: Duration(seconds: 25),
      normalInterval: Duration(seconds: 10),
      fastInterval: Duration(seconds: 3),
      normalDistanceFilter: 15.0,
      stoppedSpeedThreshold: 0.5,
      fastSpeedThreshold: 12.0,
    );

    setUp(() {
      transport = MockTransport();
      locationCtrl = StreamController<Position>.broadcast();
    });

    tearDown(() async => locationCtrl.close());

    test('stopped driver does not emit beyond first fix (adaptive)', () async {
      final engine = makeEngine(
        transport: transport,
        locationCtrl: locationCtrl,
        config: fastConfig,
      );

      await engine.start();
      await activateEngine(engine);

      // First fix
      locationCtrl.add(makePosition(speed: 0.0));
      await Future.delayed(const Duration(milliseconds: 30));

      // Subsequent stopped readings — no heading change
      for (int i = 0; i < 5; i++) {
        locationCtrl.add(makePosition(speed: 0.1, heading: 0));
        await Future.delayed(const Duration(milliseconds: 10));
      }

      expect(transport.sent.length, equals(1));
      await engine.dispose();
    });

    test('heading change triggers emission in adaptive mode', () async {
      final engine = makeEngine(
        transport: transport,
        locationCtrl: locationCtrl,
        config: fastConfig,
      );

      await engine.start();
      await activateEngine(engine);

      locationCtrl.add(makePosition(speed: 0.3, heading: 0));
      await Future.delayed(const Duration(milliseconds: 30));
      final afterFirst = transport.sent.length;

      // Big heading change — driver turned
      locationCtrl.add(makePosition(speed: 0.3, heading: 90));
      await Future.delayed(const Duration(milliseconds: 30));

      expect(transport.sent.length, greaterThan(afterFirst));
      await engine.dispose();
    });

    test('heading change does NOT emit in heartbeatOnly mode', () async {
      final engine = makeEngine(
        transport: transport,
        locationCtrl: locationCtrl,
        config: fastConfig,
      );

      await engine.start();
      await engine.setDriverStatus(DriverStatus.online); // heartbeatOnly

      locationCtrl.add(makePosition(speed: 0.3, heading: 0));
      await Future.delayed(const Duration(milliseconds: 30));
      final afterFirst = transport.sent.length;

      locationCtrl.add(makePosition(speed: 0.3, heading: 90));
      await Future.delayed(const Duration(milliseconds: 30));

      expect(transport.sent.length, equals(afterFirst)); // no extra emit
      await engine.dispose();
    });
  });

  // ---------------------------------------------------------------------------

  group('RelayDriverEngine — task context', () {
    late MockTransport transport;
    late StreamController<Position> locationCtrl;
    late RelayDriverEngine engine;

    setUp(() async {
      transport = MockTransport();
      locationCtrl = StreamController<Position>.broadcast();
      engine = makeEngine(transport: transport, locationCtrl: locationCtrl);
      await engine.start();
      await activateEngine(engine); // busy + inProgress → adaptive
    });

    tearDown(() async {
      await engine.dispose();
      await locationCtrl.close();
    });

    test('taskId and taskStatus appear in payload', () async {
      locationCtrl.add(makePosition());
      await Future.delayed(const Duration(milliseconds: 50));

      final payload = transport.sent.last;
      expect(payload['taskId'], equals('task_test'));
      expect(payload['taskStatus'], equals('IN_PROGRESS'));
    });

    test('driverStatus appears in payload', () async {
      locationCtrl.add(makePosition());
      await Future.delayed(const Duration(milliseconds: 50));

      expect(transport.sent.last['driverStatus'], equals('BUSY'));
    });

    test('clearTaskContext removes task fields from emitted payload', () async {
      await engine.clearTaskContext();

      // After clearTaskContext, mode = heartbeatOnly.
      // makePosition(heading:0) = first fix → always emits regardless of mode.
      locationCtrl.add(makePosition(heading: 0));
      await Future.delayed(const Duration(milliseconds: 50));

      // heading:90 would be suppressed in heartbeatOnly — that's expected.
      // We already have the first-fix payload to check.
      final locationPayloads = transport.sent
          .where((p) => !p.containsKey('event'))
          .toList();

      // First fix guarantees at least one payload
      expect(locationPayloads, isNotEmpty);
      final last = locationPayloads.last;
      expect(last.containsKey('taskId'), isFalse);
      expect(last.containsKey('taskStatus'), isFalse);
    });

    test('TaskContextChanged event fires on setTaskContext', () async {
      final events = <EngineEvent>[];
      engine.events.listen(events.add);

      await engine.setTaskContext(
        taskId: 'task_xyz',
        status: TaskStatus.assigned,
      );

      final taskEvents = events.whereType<TaskContextChanged>().toList();
      expect(taskEvents.length, equals(1));
      expect(taskEvents.first.taskId, equals('task_xyz'));
      expect(taskEvents.first.taskStatus, equals(TaskStatus.assigned));
    });

    test('TaskStatus.assigned also triggers adaptive mode', () async {
      await engine.setTaskContext(
        taskId: 'task_xyz',
        status: TaskStatus.assigned,
      );
      expect(engine.emissionMode, EmissionMode.adaptive);
    });

    test('completed task status reverts to heartbeatOnly', () async {
      await engine.setTaskContext(
        taskId: 'task_test',
        status: TaskStatus.completed,
      );
      expect(engine.emissionMode, EmissionMode.heartbeatOnly);
    });
  });

  // ---------------------------------------------------------------------------

  group('RelayDriverEngine — route deviation', () {
    late MockTransport transport;
    late StreamController<Position> locationCtrl;
    late RelayDriverEngine engine;

    final config = EngineConfig(
      deviationThresholdMeters: 80,
      deviationConsecutiveCount: 3,
      snapToRouteEnabled: true,
    );

    // Horizontal segment in Lagos
    final polyline = [(lat: 6.4550, lng: 3.3900), (lat: 6.4550, lng: 3.4000)];

    setUp(() async {
      transport = MockTransport();
      locationCtrl = StreamController<Position>.broadcast();
      engine = makeEngine(
        transport: transport,
        locationCtrl: locationCtrl,
        config: config,
      );
      await engine.start();
      await activateEngine(engine);
      engine.updateRoute(polyline);
    });

    tearDown(() async {
      await engine.dispose();
      await locationCtrl.close();
    });

    test(
      'RouteDeviationDetected fires after N consecutive off-route readings',
      () async {
        final events = <EngineEvent>[];
        engine.events.listen(events.add);

        // ~200m north of the route, heading changes to trigger adaptive emission
        for (int i = 0; i < 3; i++) {
          locationCtrl.add(
            makePosition(
              lat: 6.4568,
              lng: 3.3950,
              heading: (i * 30).toDouble(),
            ),
          );
          await Future.delayed(const Duration(milliseconds: 50));
        }

        expect(events.whereType<RouteDeviationDetected>().length, equals(1));
      },
    );

    test('deviation event fires exactly once per episode', () async {
      final events = <EngineEvent>[];
      engine.events.listen(events.add);

      for (int i = 0; i < 6; i++) {
        locationCtrl.add(
          makePosition(lat: 6.4568, lng: 3.3950, heading: (i * 20).toDouble()),
        );
        await Future.delayed(const Duration(milliseconds: 50));
      }

      expect(events.whereType<RouteDeviationDetected>().length, equals(1));
    });

    test('updateRoute re-arms deviation detector', () async {
      final events = <EngineEvent>[];
      engine.events.listen(events.add);

      // First episode
      for (int i = 0; i < 3; i++) {
        locationCtrl.add(
          makePosition(lat: 6.4568, lng: 3.3950, heading: (i * 30).toDouble()),
        );
        await Future.delayed(const Duration(milliseconds: 50));
      }

      // App got new route from backend
      engine.updateRoute([
        (lat: 6.4568, lng: 3.3900),
        (lat: 6.4568, lng: 3.4000),
      ]);

      // Second episode on new route
      for (int i = 0; i < 3; i++) {
        locationCtrl.add(
          makePosition(lat: 6.4590, lng: 3.3950, heading: (i * 30).toDouble()),
        );
        await Future.delayed(const Duration(milliseconds: 50));
      }

      expect(events.whereType<RouteDeviationDetected>().length, equals(2));
    });

    test('updateRoute with < 2 points is a no-op', () async {
      final events = <EngineEvent>[];
      engine.events.listen(events.add);

      engine.updateRoute([(lat: 6.4550, lng: 3.3900)]); // single point

      expect(events.whereType<RouteUpdated>(), isEmpty);
    });

    test('RouteUpdated event fires with correct waypoint count', () async {
      final events = <EngineEvent>[];
      engine.events.listen(events.add);

      engine.updateRoute([
        (lat: 6.4550, lng: 3.3900),
        (lat: 6.4550, lng: 3.3950),
        (lat: 6.4560, lng: 3.4000),
      ]);

      expect(events.whereType<RouteUpdated>().first.waypointCount, equals(3));
    });

    test('snapped coordinate appears in payload when on route', () async {
      // Point slightly off route (within snap threshold)
      locationCtrl.add(makePosition(lat: 6.4552, lng: 3.3950));
      await Future.delayed(const Duration(milliseconds: 50));

      final payload = transport.sent.last;
      expect(payload['isSnapped'], isTrue);
    });
  });

  // ---------------------------------------------------------------------------

  group('RelayDriverEngine — transport events', () {
    test('TransportStateChanged events fire on connect/disconnect', () async {
      final transport = MockTransport();
      final locationCtrl = StreamController<Position>.broadcast();
      final engine = makeEngine(
        transport: transport,
        locationCtrl: locationCtrl,
      );

      final events = <EngineEvent>[];
      engine.events.listen(events.add);

      await engine.start();
      transport.simulateDrop();
      transport.simulateReconnect();

      await Future.delayed(const Duration(milliseconds: 50));

      final stateEvents = events.whereType<TransportStateChanged>().toList();
      expect(stateEvents.any((e) => e.connected), isTrue);
      expect(stateEvents.any((e) => !e.connected), isTrue);

      await engine.dispose();
      await locationCtrl.close();
    });
  });

  // ---------------------------------------------------------------------------

  group('RelayDriverEngine — payload shape', () {
    test('LocationUpdate.toJson contains all required fields', () async {
      final transport = MockTransport();
      final locationCtrl = StreamController<Position>.broadcast();
      final engine = makeEngine(
        transport: transport,
        locationCtrl: locationCtrl,
      );

      await engine.start();
      await activateEngine(engine, taskId: 'task_001');

      locationCtrl.add(
        makePosition(lat: 6.5244, lng: 3.3792, speed: 8.0, heading: 45.0),
      );
      await Future.delayed(const Duration(milliseconds: 50));

      expect(transport.sent, isNotEmpty);
      final p = transport.sent.first;

      expect(p['lat'], isA<double>());
      expect(p['lng'], isA<double>());
      expect(p['rawLat'], isA<double>());
      expect(p['rawLng'], isA<double>());
      expect(p['heading'], isA<double>());
      expect(p['speed'], isA<double>());
      expect(p['ts'], isA<int>());
      expect(p['driverStatus'], equals('BUSY'));
      expect(p['taskStatus'], equals('IN_PROGRESS'));
      expect(p['taskId'], equals('task_001'));
      expect(p['isSnapped'], isA<bool>());
      expect(p['isHeartbeat'], isA<bool>());
      expect(p['accuracyMeters'], isA<double>());

      await engine.dispose();
      await locationCtrl.close();
    });

    test('negative speed and heading values are clamped to 0', () async {
      final transport = MockTransport();
      final locationCtrl = StreamController<Position>.broadcast();
      final engine = makeEngine(
        transport: transport,
        locationCtrl: locationCtrl,
      );

      await engine.start();
      await activateEngine(engine);

      // Geolocator returns -1 when speed/heading unavailable on some devices
      locationCtrl.add(makePosition(speed: -1.0, heading: -1.0));
      await Future.delayed(const Duration(milliseconds: 50));

      // First fix always emits — unconditional assertion
      final locationPayloads = transport.sent
          .where((p) => !p.containsKey('event'))
          .toList();
      expect(
        locationPayloads,
        isNotEmpty,
        reason: 'First fix must always emit',
      );
      expect(locationPayloads.first['speed'], equals(0.0));
      expect(locationPayloads.first['heading'], equals(0.0));

      await engine.dispose();
      await locationCtrl.close();
    });
  });

  // ---------------------------------------------------------------------------

  group('RelayDriverEngine — heartbeat + errors', () {
    test('heartbeat emissions are marked with isHeartbeat', () async {
      final transport = MockTransport();
      final locationCtrl = StreamController<Position>.broadcast();
      final config = EngineConfig(
        heartbeatInterval: const Duration(milliseconds: 50),
        normalInterval: const Duration(milliseconds: 30),
        fastInterval: const Duration(milliseconds: 10),
        normalDistanceFilter: 1.0,
        fastDistanceFilter: 1.0,
      );
      final engine = makeEngine(
        transport: transport,
        locationCtrl: locationCtrl,
        config: config,
      );

      await engine.start();
      await engine.setDriverStatus(DriverStatus.online);

      locationCtrl.add(makePosition());
      await Future.delayed(const Duration(milliseconds: 20));

      final first = transport.sent.last;
      expect(first['isHeartbeat'], isFalse);

      await Future.delayed(const Duration(milliseconds: 60));
      locationCtrl.add(makePosition());
      await Future.delayed(const Duration(milliseconds: 20));

      final heartbeat = transport.sent.last;
      expect(heartbeat['isHeartbeat'], isTrue);

      await engine.dispose();
      await locationCtrl.close();
    });

    test('send failures surface as EngineError events', () async {
      final transport = FailingTransport();
      final locationCtrl = StreamController<Position>.broadcast();
      final engine = makeEngine(
        transport: transport,
        locationCtrl: locationCtrl,
      );

      final errors = <EngineError>[];
      engine.events
          .where((e) => e is EngineError)
          .cast<EngineError>()
          .listen(errors.add);

      await engine.start();
      await activateEngine(engine);

      locationCtrl.add(makePosition());
      await Future.delayed(const Duration(milliseconds: 30));

      expect(errors, isNotEmpty);

      await engine.dispose();
      await locationCtrl.close();
    });

    test('failed send does not advance emission state', () async {
      final transport = FlakyTransport(failuresBeforeSuccess: 1);
      final locationCtrl = StreamController<Position>.broadcast();
      final engine = makeEngine(
        transport: transport,
        locationCtrl: locationCtrl,
      );

      await engine.start();
      await engine.setDriverStatus(DriverStatus.online); // heartbeatOnly mode

      // First fix attempts to emit but transport fails.
      locationCtrl.add(makePosition());
      await Future.delayed(const Duration(milliseconds: 30));
      expect(transport.sent, isEmpty);

      // Second immediate fix should still be treated as first-fix and emit,
      // not suppressed as heartbeatOnly movement.
      locationCtrl.add(makePosition());
      await Future.delayed(const Duration(milliseconds: 30));
      expect(transport.sent.length, equals(1));

      await engine.dispose();
      await locationCtrl.close();
    });

    test('going offline never throws when transport send fails', () async {
      final transport = FailingTransport();
      final locationCtrl = StreamController<Position>.broadcast();
      final engine = makeEngine(
        transport: transport,
        locationCtrl: locationCtrl,
      );

      await engine.start();
      await engine.setDriverStatus(DriverStatus.online);

      await expectLater(
        () => engine.setDriverStatus(DriverStatus.offline),
        returnsNormally,
      );

      await engine.dispose();
      await locationCtrl.close();
    });
  });
}
