// ignore_for_file: avoid_print

import 'dart:async';

import 'package:relay_driver_engine/relay_driver_engine.dart';

/// Demonstrates implementing [RelayTransportAdapter] for custom transports.
///
/// Replace `_SocketIoAdapter` internals with your socket/mqtt/http client.
Future<void> main() async {
  final adapter = _SocketIoAdapter();
  final engine = RelayDriverEngine(transport: adapter);

  engine.events.listen((event) {
    if (event is TransportStateChanged) {
      print('Connected: ${event.connected}');
    }
    if (event is EngineError) {
      print('Engine error: ${event.message}');
    }
  });

  await engine.start();
  await engine.setDriverStatus(DriverStatus.online);

  // Keep alive briefly for demo.
  await Future<void>.delayed(const Duration(seconds: 2));

  await engine.setDriverStatus(DriverStatus.offline);
  await engine.dispose();
}

class _SocketIoAdapter implements RelayTransportAdapter {
  final _conn = StreamController<bool>.broadcast();
  bool _connected = false;

  @override
  void Function(Object error)? onError;

  @override
  Stream<bool> get connectionState => _conn.stream;

  @override
  Future<void> connect() async {
    try {
      // Replace with real connect logic.
      _connected = true;
      _conn.add(true);
    } catch (e) {
      _connected = false;
      _conn.add(false);
      onError?.call(e);
    }
  }

  @override
  Future<void> send(Map<String, dynamic> payload) async {
    if (!_connected) {
      onError?.call(StateError('Not connected'));
      return;
    }
    // Replace with real send logic.
    print('Custom transport payload: $payload');
  }

  @override
  Future<void> disconnect() async {
    _connected = false;
    _conn.add(false);
    await _conn.close();
  }
}
