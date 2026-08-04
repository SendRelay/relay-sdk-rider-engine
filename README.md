# Relay Driver Engine

A robust, transport-agnostic driver location engine for the Relay platform.

Handles smart emission policies, Kalman GPS filtering, on-device route snapping, deviation detection, background tracking, and driver/task state management — without Fleet Engine, without Roads API, without per-trip cost.

---

## Contents

- [Installation](#installation)
- [Platform setup](#platform-setup)
  - [Android](#android)
  - [iOS](#ios)
- [Core concepts](#core-concepts)
- [Public API map](#public-api-map)
- [Quick start](#quick-start)
- [Full lifecycle walkthrough](#full-lifecycle-walkthrough)
- [Emission modes](#emission-modes)
- [Route snapping and deviation](#route-snapping-and-deviation)
- [Background tracking](#background-tracking)
- [Custom transport adapter](#custom-transport-adapter)
- [Location payload shape](#location-payload-shape)
- [Engine events reference](#engine-events-reference)
- [EngineConfig reference](#engineconfig-reference)
- [Driver and task status enums](#driver-and-task-status-enums)
- [Testing with the engine](#testing-with-the-engine)
- [File structure](#file-structure)

---

## Installation

Add to your `pubspec.yaml`:

```yaml
dependencies:
  relay_driver_engine: ^0.2.1
```

Then:

```sh
flutter pub get
```

---

## Platform setup

### Android

Add to `android/app/src/main/AndroidManifest.xml`:

```xml
<!-- Required for all location access -->
<uses-permission android:name="android.permission.ACCESS_FINE_LOCATION" />
<uses-permission android:name="android.permission.ACCESS_COARSE_LOCATION" />

<!-- Required for background tracking (foreground service) -->
<uses-permission android:name="android.permission.FOREGROUND_SERVICE" />
<uses-permission android:name="android.permission.FOREGROUND_SERVICE_LOCATION" />
```

If you enable `EngineConfig.enableBackground`, also add the foreground service declaration inside `<application>`:

```xml
<service
    android:name="com.baseflow.geolocator.GeolocationService"
    android:foregroundServiceType="location"
    android:exported="false" />
```

Request location permission at runtime before calling `engine.start()`. Using `permission_handler` is recommended:

```dart
final status = await Permission.locationAlways.request();
if (!status.isGranted) return; // handle denial
```

### iOS

Add to `ios/Runner/Info.plist`:

```xml
<!-- Required for when-in-use location -->
<key>NSLocationWhenInUseUsageDescription</key>
<string>Relay needs your location to track active deliveries.</string>

<!-- Required for background location (enableBackground: true) -->
<key>NSLocationAlwaysAndWhenInUseUsageDescription</key>
<string>Relay tracks your location in the background during active deliveries.</string>

<!-- Required for background location -->
<key>UIBackgroundModes</key>
<array>
    <string>location</string>
</array>
```

For background tracking, the user must grant **Always** (not just "While Using") location permission. The engine uses `ActivityType.automotiveNavigation` and disables `pauseLocationUpdatesAutomatically` to prevent iOS from killing updates at red lights.

---

## Core concepts

**The engine is the state machine.** It sits between raw GPS and your WebSocket, making decisions about *when* to emit, *what* to send, and *how* to clean up the coordinate before transmission.

**Emission modes** control frequency. There are two:
- `heartbeatOnly` — idle driver; emits once on first fix, then only on a 25-second heartbeat to keep the backend `DriverPresence` TTL alive.
- `adaptive` — active task; full speed/distance/heading logic.

The engine switches modes automatically — you just update driver and task status.

**The transport is pluggable.** The engine produces payloads; you decide how to send them. A `WebSocketTransportAdapter` is included, or implement `RelayTransportAdapter` for socket.io, MQTT, HTTP, or anything else.

**Everything is injectable for testing.** Pass a `Stream<Position>` and a mock transport — no real GPS or network needed.

---

## Public API map

Import once:

```dart
import 'package:relay_driver_engine/relay_driver_engine.dart';
```

Exported interfaces and their purpose:

- `RelayDriverEngine`: Main orchestration engine (lifecycle, status, task context, route updates, event stream).
- `EngineConfig`: Immutable tuning parameters for emission, smoothing, snapping, deviation, and background behavior.
- `LocationUpdate`: Emitted location payload model sent to your transport.
- `EngineEvent` and event subclasses:
  - `LocationEmitted`
  - `RouteDeviationDetected`
  - `RouteUpdated`
  - `DriverStatusChanged`
  - `TaskContextChanged`
  - `TransportStateChanged`
  - `EngineError`
- `DriverStatus`, `TaskStatus`, `StageStatus`: Status enums.
- `DriverStatusX`, `TaskStatusX`: Enum helper extensions (`value`, `shouldEmit`, `isActiveTrip`).
- `EmissionMode`, `EmitReason`, `EmissionDecision`: Emission policy output and reasons.
- `RelayTransportAdapter`: Transport interface contract.
- `WebSocketTransportAdapter`: Built-in `dart:io` WebSocket adapter with reconnect support.
- `LatLng` (`({double lat, double lng})`): Route coordinate record type used by `updateRoute`.

Methods you will use most on `RelayDriverEngine`:

- `start()`, `stop()`, `dispose()`
- `setDriverStatus(DriverStatus)`
- `setTaskContext(taskId, status)`, `clearTaskContext()`
- `updateRoute(List<LatLng>)`, `clearRoute()`
- `events` stream, `driverStatus`, `taskStatus`, `emissionMode`

For complete runnable samples, see the `example/` folder.

---

## Quick start

```dart
import 'package:relay_driver_engine/relay_driver_engine.dart';

final engine = RelayDriverEngine(
  transport: WebSocketTransportAdapter(
    uri: Uri.parse('wss://api.relay.ng/ws/driver'),
    headers: {'Authorization': 'Bearer $token'},
  ),
);

engine.events.listen((event) {
  switch (event) {
    case LocationEmitted(:final update):
      debugPrint('${update.lat}, ${update.lng} — ${update.speed.toStringAsFixed(1)} m/s');
    case RouteDeviationDetected(:final taskId, :final deviationMeters):
      _handleDeviation(taskId, deviationMeters);
    case EngineError(:final message, :final error):
      debugPrint('Engine error: $message — $error');
    default:
      break;
  }
});

await engine.start();
await engine.setDriverStatus(DriverStatus.online);
```

---

## Full lifecycle walkthrough

This is the expected call sequence for a complete driver session.

```dart
// 1. Create the engine once — typically in your driver app's root widget or service
final engine = RelayDriverEngine(
  transport: WebSocketTransportAdapter(
    uri: Uri.parse('wss://api.relay.ng/ws/driver'),
    headers: {'Authorization': 'Bearer $token'},
  ),
  engineConfig: EngineConfig(
    enableBackground: true,
    backgroundNotificationTitle: 'Relay — Active Delivery',
    backgroundNotificationContent: 'Your location is being tracked.',
  ),
);

// 2. Subscribe to events before starting
engine.events.listen(_onEngineEvent);

// 3. Start the engine — connects transport, opens GPS stream
// Does NOT emit anything yet (driver is still offline)
await engine.start();

// 4. Driver taps "Go Online"
// Mode: heartbeatOnly — emits first fix, then 25s heartbeats only
await engine.setDriverStatus(DriverStatus.online);

// ── Task is offered and accepted ───────────────────────────────

// 5. Driver accepts a task
// Mode switches to adaptive (busy + inProgress = full emission logic)
await engine.setDriverStatus(DriverStatus.busy);
await engine.setTaskContext(
  taskId: task.id,
  status: TaskStatus.inProgress,
);

// 6. Load the route polyline from your backend
// The engine uses this for on-device GPS snapping
engine.updateRoute(task.routePolyline); // List<LatLng>

// ── Driver is now moving — engine is emitting adaptively ───────

// 7. Handle a route deviation (driver took a wrong turn)
void _onEngineEvent(EngineEvent event) {
  if (event is RouteDeviationDetected) {
    // Fetch new route from your backend, then hot-swap — no engine restart
    _backendClient.getRoute(event.taskId).then((newPolyline) {
      engine.updateRoute(newPolyline);
    });
  }
}

// ── Task is completed ──────────────────────────────────────────

// 8. Task done — clear context and route
// Mode reverts to heartbeatOnly (driver is busy but no active task)
await engine.clearTaskContext();
engine.clearRoute();

// If driver goes back to available (not immediately taking another task):
await engine.setDriverStatus(DriverStatus.online);

// ── Driver clocks out ──────────────────────────────────────────

// 9. Driver goes offline
// Engine sends driver:offline to backend immediately
// Backend can expire the DriverPresence record without waiting for TTL
await engine.setDriverStatus(DriverStatus.offline);

// 10. Stop + dispose when the widget/service is destroyed
await engine.stop();
await engine.dispose();
```

---

## Emission modes

The engine switches mode automatically based on `DriverStatus` + `TaskStatus`. You never call `setMode()` directly.

| `DriverStatus` | `TaskStatus`                  | Mode            | What emits                          |
|----------------|-------------------------------|-----------------|-------------------------------------|
| `offline`      | any                           | silent          | nothing                             |
| `online`       | any                           | `heartbeatOnly` | first fix + 25s heartbeats only     |
| `busy`         | `assigned` or `inProgress`    | `adaptive`      | full speed/distance/heading logic   |
| `busy`         | anything else                 | `heartbeatOnly` | first fix + 25s heartbeats only     |

### Adaptive mode decision tree

When in `adaptive` mode, each incoming GPS reading is evaluated in this order:

1. **First fix** — always emits, regardless of anything else.
2. **Heartbeat** — if ≥ `heartbeatInterval` has elapsed since last emit, always emits. Keeps the backend `DriverPresence` TTL alive even when the driver is stopped.
3. **Stopped suppression** — if speed < `stoppedSpeedThreshold` (0.5 m/s) and heading is stable, suppress. No spamming the server at red lights.
4. **Heading trigger** — if heading changed ≥ `headingThresholdDegrees` (20°) since last emit, always emits. Captures turns immediately regardless of distance.
5. **Speed-adaptive gate** — emits if both conditions are met:
   - Moved ≥ `normalDistanceFilter` (15m) or `fastDistanceFilter` (10m at speeds > 12 m/s)
   - ≥ `normalInterval` (10s) or `fastInterval` (3s) has elapsed

---

## Route snapping and deviation

### Loading a route

Supply the route polyline when a task becomes active. The engine snaps every incoming GPS coordinate to the nearest point on this polyline before emitting.

```dart
// polyline is a List<LatLng> — a list of ({double lat, double lng}) records
engine.updateRoute(task.routePolyline);
```

The snap is pure on-device geometry — no network call, zero cost, no latency.

### How snapping works

Each GPS coordinate (post-Kalman) is projected onto every segment of the polyline. The nearest projected point is selected. If the distance to that point is ≤ `deviationThresholdMeters` (80m), the snapped coordinate is used in the payload and `isSnapped: true` is set. If the distance exceeds the threshold, the raw coordinate is used — the driver is genuinely off-route, not just noisy GPS.

### Deviation detection

The engine counts consecutive off-route readings. Once `deviationConsecutiveCount` (3 by default) consecutive readings all exceed `deviationThresholdMeters`, a `RouteDeviationDetected` event fires **exactly once** per episode.

```dart
case RouteDeviationDetected(:final taskId, :final currentLat, :final currentLng, :final deviationMeters):
  // Ask your backend for a new route from the driver's current position
  final newPolyline = await backendClient.reroute(
    taskId: taskId,
    fromLat: currentLat,
    fromLng: currentLng,
  );
  // Hot-swap the route — deviation detector re-arms, no engine restart
  engine.updateRoute(newPolyline);
```

Calling `updateRoute()` re-arms the detector for the next deviation episode.

### Clearing a route

Call `clearRoute()` when a task is completed. The engine stops snapping and deviation detection until a new route is loaded.

```dart
engine.clearRoute();
```

---

## Background tracking

### Foreground + background (recommended, not killed)

Set `enableBackground: true` in `EngineConfig`. The engine configures a foreground service (Android) or background location mode (iOS) automatically.

```dart
RelayDriverEngine(
  engineConfig: EngineConfig(
    enableBackground: true,
    backgroundNotificationTitle: 'Relay — Active Delivery',
    backgroundNotificationContent: 'Your location is being tracked.',
  ),
  transport: myTransport,
);
```

The Android notification appears as a persistent notification (non-dismissible while active) with a wake lock to prevent CPU sleep. On iOS, the indicator in the status bar shows the user that background location is active.

This mode survives the app being backgrounded (home button, incoming call, lock screen). The app **will** be killed if the OS needs memory — see below for full kill resilience.

### Full background (kill-resilient) — advanced, opt-in

Full kill-resilient background tracking (where tracking continues even if the OS kills your app) requires native configuration outside this package. Approaches:

**Android:** Use `WorkManager` or a persistent `Service` with `START_STICKY`. The engine's location stream would need to be restarted from the service's `onCreate`. Refer to the `geolocator` plugin's background service documentation.

**iOS:** iOS does not support truly continuous background location without a visible indicator. Options are:
- Significant location change API — fires when the device moves ~500m, low battery drain, lower accuracy.
- Always-on background location — requires `NSLocationAlwaysUsageDescription`, user must grant Always permission, and your app must be justified to Apple for App Store review.

For most delivery use cases, foreground + background (not killed) is sufficient.

---

## Custom transport adapter

Implement `RelayTransportAdapter` to use any transport underneath the engine.

```dart
class SocketIoAdapter implements RelayTransportAdapter {
  SocketIoAdapter(String url)
      : _socket = IO.io(
          url,
          IO.OptionBuilder().setTransports(['websocket']).build(),
        );

  final IO.Socket _socket;
  final _connController = StreamController<bool>.broadcast();

  @override
  void Function(Object error)? onError;

  @override
  Stream<bool> get connectionState => _connController.stream;

  @override
  Future<void> connect() async {
    _socket.onConnect((_) => _connController.add(true));
    _socket.onDisconnect((_) => _connController.add(false));
    _socket.onConnectError((e) {
      onError?.call(e);
      _connController.add(false);
    });
    _socket.connect();
  }

  @override
  Future<void> send(Map<String, dynamic> payload) async =>
      _socket.emit('driver:location', payload);

  @override
  Future<void> disconnect() async {
    _socket.disconnect();
    await _connController.close();
  }
}
```

Then pass it to the engine:

```dart
final engine = RelayDriverEngine(
  transport: SocketIoAdapter('wss://api.relay.ng'),
);
```

The engine calls `connect()` on `start()`, `send()` for every emitted update, and `disconnect()` on `stop()`. Errors surfaced via `onError` appear as `EngineError` events on `engine.events`.

### Built-in WebSocketTransportAdapter

The default adapter uses `IOWebSocketChannel` (dart:io — not compatible with Flutter Web). It handles:
- Auth headers on every connection and reconnect (use for Bearer tokens)
- Auto-reconnect with linear backoff (3s, 6s, 9s… up to 10 attempts)
- Concurrent connection guard (won't open two connections at once)
- Stream subscription cleanup before reconnecting

```dart
WebSocketTransportAdapter(
  uri: Uri.parse('wss://api.relay.ng/ws/driver'),
  headers: {'Authorization': 'Bearer $token'},
  reconnectDelay: const Duration(seconds: 3),   // default
  maxReconnectAttempts: 10,                       // default
);
```

> **Flutter Web:** `IOWebSocketChannel` uses `dart:io` and will not compile for web targets. Implement a custom adapter using the browser's native `WebSocket` API via `dart:html`.

---

## Location payload shape

Every emitted update calls `transport.send()` with this JSON-serialisable map:

```jsonc
{
  "lat": 6.5244,           // filtered + snapped latitude
  "lng": 3.3792,           // filtered + snapped longitude
  "rawLat": 6.5251,        // original GPS latitude (pre-filter, pre-snap)
  "rawLng": 3.3785,        // original GPS longitude
  "heading": 45.0,         // degrees 0–360, clamped (negative → 0)
  "speed": 8.3,            // m/s, clamped (negative → 0)
  "accuracyMeters": 5.0,   // GPS accuracy reported by device
  "ts": 1709123456789,     // Unix timestamp, milliseconds
  "driverStatus": "BUSY",  // ONLINE | BUSY | OFFLINE
  "taskStatus": "IN_PROGRESS", // only present when task context is set
  "taskId": "task_abc123",     // only present when task context is set
  "isSnapped": true,       // true if coordinate was snapped to route
  "deviationMeters": 18.4, // distance from nearest route point
  "isHeartbeat": false     // true when emitted to keep TTL alive, not from movement
}
```

When the driver goes offline, a separate signal is sent:

```jsonc
{
  "event": "driver:offline",
  "ts": 1709123456789
}
```

Your backend can use `event: "driver:offline"` to immediately expire the `DriverPresence` record instead of waiting for TTL.

---

## Engine events reference

Subscribe to `engine.events` — a broadcast `Stream<EngineEvent>`. Use Dart's sealed class pattern matching:

```dart
engine.events.listen((event) {
  switch (event) {
    case LocationEmitted(:final update):
      // update is a LocationUpdate — see payload shape above
      break;

    case RouteDeviationDetected(:final taskId, :final currentLat, :final currentLng, :final deviationMeters):
      // Driver is confirmed off-route — fetch new polyline from backend
      break;

    case RouteUpdated(:final waypointCount):
      // updateRoute() was accepted and applied
      break;

    case DriverStatusChanged(:final previous, :final current):
      // previous and current are DriverStatus enum values
      break;

    case TaskContextChanged(:final taskId, :final taskStatus):
      // taskId/taskStatus are null when clearTaskContext() is called
      break;

    case TransportStateChanged(:final connected):
      // true = connected, false = dropped/reconnecting
      break;

    case EngineError(:final message, :final error):
      // Non-fatal — engine keeps running. Log and alert as needed.
      break;
  }
});
```

| Event | Fired when | Key fields |
|---|---|---|
| `LocationEmitted` | A coordinate passed all filters and was transmitted | `update: LocationUpdate` |
| `RouteDeviationDetected` | N consecutive off-route readings detected | `taskId`, `currentLat`, `currentLng`, `deviationMeters` |
| `RouteUpdated` | `updateRoute()` was called with a valid polyline | `waypointCount` |
| `DriverStatusChanged` | `setDriverStatus()` was called with a new status | `previous`, `current` |
| `TaskContextChanged` | `setTaskContext()` or `clearTaskContext()` was called | `taskId?`, `taskStatus?` |
| `TransportStateChanged` | WebSocket connected or disconnected | `connected: bool` |
| `EngineError` | Transport error or location stream error | `message`, `error?` |

---

## EngineConfig reference

All parameters have sane defaults for Nigerian urban delivery (Lagos / Abuja road density, motorcycle and car speeds). Override only what you need:

```dart
EngineConfig(
  // Emission intervals
  heartbeatInterval: Duration(seconds: 25), // must be > normalInterval
  normalInterval: Duration(seconds: 10),    // must be > fastInterval
  fastInterval: Duration(seconds: 3),

  // Speed thresholds
  stoppedSpeedThreshold: 0.5,  // m/s — below this, driver is considered stopped
  fastSpeedThreshold: 12.0,    // m/s (~43 km/h) — above this, fast tier applies

  // Distance filters (adaptive mode only)
  normalDistanceFilter: 15.0,  // metres — must move this far before emitting at normal speed
  fastDistanceFilter: 10.0,    // metres — threshold at fast speed

  // Turn detection
  headingThresholdDegrees: 20.0, // emit immediately when heading changes by this much

  // Kalman filter tuning
  kalmanProcessNoise: 0.0001,      // higher = more reactive, less smooth
  kalmanMeasurementNoise: 0.0005,  // higher = trusts GPS less, smoother

  // Route snapping
  snapToRouteEnabled: true,
  deviationThresholdMeters: 80.0, // beyond this = off-route (not snapped)
  deviationConsecutiveCount: 3,   // readings before RouteDeviationDetected fires

  // Background tracking
  enableBackground: false,
  backgroundNotificationTitle: 'Relay — Active Delivery',
  backgroundNotificationContent: 'Your location is being tracked.',
)
```

All values are validated with `assert()` on construction. Passing an invalid config (e.g. `fastInterval` > `normalInterval`) throws immediately in debug mode.

`EngineConfig` is immutable and `Equatable`. Use `copyWith()` to produce variants:

```dart
final aggressiveConfig = baseConfig.copyWith(
  normalInterval: const Duration(seconds: 5),
  fastInterval: const Duration(seconds: 1),
);
```

---

## Driver and task status enums

### DriverStatus

```dart
enum DriverStatus { online, busy, offline }
```

| Value | Meaning | Emission mode |
|---|---|---|
| `online` | Driver is available, no active task | `heartbeatOnly` |
| `busy` | Driver has accepted or is on an active task | `adaptive` (if task is active) |
| `offline` | Driver is not working | silent (nothing emitted) |

`offline` triggers an immediate `driver:offline` signal to the backend and resets the Kalman filter.

### TaskStatus

```dart
enum TaskStatus {
  pending,
  offered,
  assigned,      // → adaptive mode (isActiveTrip = true)
  inProgress,    // → adaptive mode (isActiveTrip = true)
  completed,
  cancelled,
  failed,
  paymentFailed,
}
```

Only `assigned` and `inProgress` trigger `adaptive` emission mode. All other statuses keep the engine in `heartbeatOnly`.

### StageStatus

```dart
enum StageStatus { pending, inProgress, completed }
```

Used for individual task stage tracking. Not used by the engine internally — available for your UI layer.

---

## Testing with the engine

The engine is fully injectable. Pass a mock transport and a `Stream<Position>` controller — no real GPS, no real network:

```dart
import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:geolocator/geolocator.dart';
import 'package:relay_driver_engine/relay_driver_engine.dart';

// 1. Mock transport — captures every sent payload
class MockTransport implements RelayTransportAdapter {
  final _connCtrl = StreamController<bool>.broadcast();
  final List<Map<String, dynamic>> sent = [];

  @override
  void Function(Object error)? onError;

  @override
  Stream<bool> get connectionState => _connCtrl.stream;

  @override
  Future<void> connect() async => _connCtrl.add(true);

  @override
  Future<void> send(Map<String, dynamic> payload) async =>
      sent.add(Map.unmodifiable(payload));

  @override
  Future<void> disconnect() async {
    _connCtrl.add(false);
    await _connCtrl.close();
  }
}

// 2. Helper to build a test Position
Position makePosition({
  double lat = 6.5244, double lng = 3.3792,
  double speed = 5.0, double heading = 0.0, double accuracy = 5.0,
}) => Position(
  latitude: lat, longitude: lng, speed: speed,
  heading: heading, accuracy: accuracy,
  altitude: 0, altitudeAccuracy: 0,
  headingAccuracy: 0, speedAccuracy: 0,
  timestamp: DateTime.now(),
);

// 3. Write your test
test('emits first fix immediately in adaptive mode', () async {
  final transport = MockTransport();
  final locationCtrl = StreamController<Position>.broadcast();

  final engine = RelayDriverEngine(
    transport: transport,
    locationStream: locationCtrl.stream, // injected — no real GPS
  );

  await engine.start();
  await engine.setDriverStatus(DriverStatus.busy);
  await engine.setTaskContext(taskId: 'task_001', status: TaskStatus.inProgress);

  locationCtrl.add(makePosition());
  await Future.delayed(const Duration(milliseconds: 50));

  expect(transport.sent.length, equals(1));
  expect(transport.sent.first['taskId'], equals('task_001'));
  expect(transport.sent.first['driverStatus'], equals('BUSY'));

  await engine.dispose();
  await locationCtrl.close();
});
```

### Testing deviation detection

```dart
test('RouteDeviationDetected fires after 3 off-route readings', () async {
  final transport = MockTransport();
  final locationCtrl = StreamController<Position>.broadcast();

  final engine = RelayDriverEngine(
    transport: transport,
    locationStream: locationCtrl.stream,
    engineConfig: EngineConfig(
      deviationThresholdMeters: 80,
      deviationConsecutiveCount: 3,
    ),
  );

  await engine.start();
  await engine.setDriverStatus(DriverStatus.busy);
  await engine.setTaskContext(taskId: 'task_001', status: TaskStatus.inProgress);

  // Load a route along Lagos Island
  engine.updateRoute([
    (lat: 6.4550, lng: 3.3900),
    (lat: 6.4550, lng: 3.4000),
  ]);

  final events = <EngineEvent>[];
  engine.events.listen(events.add);

  // Send 3 positions ~200m off route, with heading changes to trigger emission
  for (int i = 0; i < 3; i++) {
    locationCtrl.add(makePosition(lat: 6.4568, lng: 3.3950, heading: i * 30.0));
    await Future.delayed(const Duration(milliseconds: 50));
  }

  expect(events.whereType<RouteDeviationDetected>().length, equals(1));

  await engine.dispose();
  await locationCtrl.close();
});
```

---

## File structure

```
relay_driver_engine/
│
├── pubspec.yaml                        # Package manifest
├── analysis_options.yaml               # Lint rules (strict, pub.dev ready)
├── CHANGELOG.md                        # Version history
├── README.md                           # This file
│
├── lib/
│   ├── relay_driver_engine.dart        # ← Single import. Re-exports everything.
│   │
│   └── src/
│       ├── engine/
│       │   └── relay_driver_engine.dart    # Main engine class (RelayDriverEngine)
│       │                                   # Start here when reading the code.
│       │
│       ├── filters/
│       │   ├── emission_policy.dart    # EmissionPolicy, EmissionMode, EmitReason
│       │   │                          # Decides whether each GPS reading should emit
│       │   └── kalman_filter.dart     # GpsKalmanFilter — smooths raw GPS coordinates
│       │
│       ├── models/
│       │   ├── engine_config.dart     # EngineConfig — all tunable parameters
│       │   ├── engine_event.dart      # Sealed EngineEvent class + all subclasses
│       │   ├── location_update.dart   # LocationUpdate — the emitted payload model
│       │   └── status.dart            # DriverStatus, TaskStatus, StageStatus enums
│       │
│       ├── routing/
│       │   ├── deviation_detector.dart # Consecutive off-route counting
│       │   └── route_snapper.dart      # On-device polyline snapping (RouteSnapper)
│       │
│       └── transport/
│           └── transport_adapter.dart  # RelayTransportAdapter (abstract)
│                                       # WebSocketTransportAdapter (default impl)
│
├── test/
│   ├── relay_driver_engine_test.dart   # Integration tests (mock transport + GPS stream)
│   ├── emission_policy_test.dart       # Unit tests — all emission mode/reason branches
│   ├── kalman_filter_test.dart         # Unit tests — convergence, accuracy weighting
│   ├── route_snapper_test.dart         # Unit tests — snap geometry, haversine, endpoints
│   └── deviation_detector_test.dart    # Unit tests — state machine, episode firing
│
└── example/
    ├── main.dart                       # Minimal setup and event handling
    ├── task_lifecycle.dart             # Full rider online/busy/offline task flow
    └── custom_transport_adapter.dart   # Custom adapter implementation example
```

### Where to start

If you're **using the package**: only ever import `relay_driver_engine.dart`. Everything is re-exported from there.

If you're **reading the source**: start at `lib/src/engine/relay_driver_engine.dart`. The `_onPosition()` method is the core processing pipeline — GPS reading enters, Kalman filter, route snap, deviation detection, emission decision, payload dispatch.

If you're **running tests**: `flutter test` from the package root. No device or network needed — all tests use injected streams.
