// ignore_for_file: avoid_print

import 'dart:async';

import 'package:geolocator/geolocator.dart';
import 'package:relay_driver_engine/relay_driver_engine.dart';

/// Demonstrates a complete driver lifecycle:
/// online -> busy/inProgress task -> completed -> offline.
Future<void> main() async {
  final transport = _InMemoryTransport();
  final gps = StreamController<Position>.broadcast();

  final engine = RelayDriverEngine(
    transport: transport,
    locationStream: gps.stream,
    engineConfig: EngineConfig(enableBackground: false),
  );

  engine.events.listen((event) {
    switch (event) {
      case DriverStatusChanged(:final previous, :final current):
        print('Status: $previous -> $current');
      case TaskContextChanged(:final taskId, :final taskStatus):
        print('Task context: $taskId $taskStatus');
      case LocationEmitted(:final update):
        print('Location emitted: ${update.toJson()}');
      case RouteDeviationDetected(:final deviationMeters):
        print('Deviation: ${deviationMeters.toStringAsFixed(1)}m');
      case EngineError(:final message, :final error):
        print('Engine error: $message ($error)');
      default:
        break;
    }
  });

  await engine.start();

  // Driver becomes available.
  await engine.setDriverStatus(DriverStatus.online);
  gps.add(_pos(lat: 6.5244, lng: 3.3792, speed: 0));
  await Future<void>.delayed(const Duration(milliseconds: 100));

  // Driver accepts task.
  await engine.setDriverStatus(DriverStatus.busy);
  await engine.setTaskContext(
    taskId: 'task_123',
    status: TaskStatus.inProgress,
  );
  engine.updateRoute(const [
    (lat: 6.5244, lng: 3.3792),
    (lat: 6.5300, lng: 3.3900),
  ]);

  gps.add(_pos(lat: 6.5250, lng: 3.3800, speed: 8, heading: 25));
  await Future<void>.delayed(const Duration(milliseconds: 100));

  // Task completed.
  await engine.clearTaskContext();
  engine.clearRoute();
  await engine.setDriverStatus(DriverStatus.online);

  // Driver clocks out.
  await engine.setDriverStatus(DriverStatus.offline);
  await engine.dispose();
  await gps.close();
}

Position _pos({
  required double lat,
  required double lng,
  double speed = 0,
  double heading = 0,
  double accuracy = 5,
}) {
  return Position(
    latitude: lat,
    longitude: lng,
    timestamp: DateTime.now(),
    accuracy: accuracy,
    altitude: 0,
    altitudeAccuracy: 0,
    heading: heading,
    headingAccuracy: 0,
    speed: speed,
    speedAccuracy: 0,
  );
}

class _InMemoryTransport implements RelayTransportAdapter {
  final _connection = StreamController<bool>.broadcast();

  @override
  Stream<bool> get connectionState => _connection.stream;

  @override
  void Function(Object error)? onError;

  @override
  Future<void> connect() async => _connection.add(true);

  @override
  Future<void> disconnect() async {
    _connection.add(false);
    await _connection.close();
  }

  @override
  Future<void> send(Map<String, dynamic> payload) async {
    print('SEND: $payload');
  }
}
