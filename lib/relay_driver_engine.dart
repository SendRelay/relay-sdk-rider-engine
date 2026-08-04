// Relay Driver Engine — transport-agnostic, smart location tracking
// for the Relay platform driver app.
//
// ## Minimal setup
// ```dart
// import 'package:relay_driver_engine/relay_driver_engine.dart';
//
// final engine = RelayDriverEngine(
//   transport: WebSocketTransportAdapter(
//     uri: Uri.parse('wss://api.relay.ng/ws/driver'),
//     headers: {'Authorization': 'Bearer $token'},
//   ),
// );
//
// await engine.start();
// await engine.setDriverStatus(DriverStatus.online);
// ```
export 'src/engine/relay_driver_engine.dart';
