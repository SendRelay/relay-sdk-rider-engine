// ignore_for_file: avoid_print

import 'dart:async';

import 'package:geolocator/geolocator.dart';
import 'package:relay_driver_engine/relay_driver_engine.dart';

/// Minimal runnable example for `relay_driver_engine`.
Future<void> main() async {
  final transport = _InMemoryTransport();
  final positionController = StreamController<Position>.broadcast();

  final engine = RelayDriverEngine(
    transport: transport,
    locationStream: positionController.stream,
  );

  engine.events.listen((event) {
    if (event is LocationEmitted) {
      print('Emitted: ${event.update.lat}, ${event.update.lng}');
    }
    if (event is EngineError) {
      print('Engine error: ${event.message}');
    }
  });

  await engine.start();
  await engine.setDriverStatus(DriverStatus.online);

  positionController.add(
    Position(
      latitude: 6.5244,
      longitude: 3.3792,
      timestamp: DateTime.now(),
      accuracy: 5,
      altitude: 0,
      altitudeAccuracy: 0,
      heading: 0,
      headingAccuracy: 0,
      speed: 0,
      speedAccuracy: 0,
    ),
  );

  await Future<void>.delayed(const Duration(milliseconds: 100));
  await engine.setDriverStatus(DriverStatus.offline);
  await engine.dispose();
  await positionController.close();
}

class _InMemoryTransport implements RelayTransportAdapter {
  final _connection = StreamController<bool>.broadcast();

  @override
  Stream<bool> get connectionState => _connection.stream;

  @override
  void Function(Object error)? onError;

  @override
  Future<void> connect() async {
    _connection.add(true);
  }

  @override
  Future<void> disconnect() async {
    _connection.add(false);
    await _connection.close();
  }

  @override
  Future<void> send(Map<String, dynamic> payload) async {
    print('Transport payload: $payload');
  }
}
