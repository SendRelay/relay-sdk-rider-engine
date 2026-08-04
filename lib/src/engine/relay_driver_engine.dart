import 'dart:async';

import 'package:flutter/foundation.dart'
    show TargetPlatform, defaultTargetPlatform, kIsWeb;
import 'package:geolocator/geolocator.dart';

import '../filters/emission_policy.dart';
import '../filters/kalman_filter.dart';
import '../models/engine_config.dart';
import '../models/engine_event.dart';
import '../models/location_update.dart';
import '../models/status.dart';
import '../routing/deviation_detector.dart';
import '../routing/route_snapper.dart';
import '../transport/transport_adapter.dart';

export '../filters/emission_policy.dart'
    show EmissionMode, EmitReason, EmissionDecision;
export '../models/engine_config.dart';
export '../models/engine_event.dart';
export '../models/location_update.dart';
export '../models/status.dart';
export '../routing/route_snapper.dart' show LatLng;
export '../transport/transport_adapter.dart';

/// The core Relay driver location engine.
///
/// ## Quickstart
/// ```dart
/// final engine = RelayDriverEngine(
///   transport: WebSocketTransportAdapter(
///     uri: Uri.parse('wss://api.relay.ng/ws/driver'),
///     headers: {'Authorization': 'Bearer $token'},
///   ),
/// );
///
/// engine.events.listen((event) {
///   switch (event) {
///     case LocationEmitted(:final update):
///       debugPrint('${update.lat}, ${update.lng}');
///     case RouteDeviationDetected(:final taskId):
///       _fetchNewRoute(taskId); // request new polyline from backend
///     case EngineError(:final message):
///       debugPrint('Engine error: $message');
///     default:
///       break;
///   }
/// });
///
/// await engine.start();
///
/// // Driver comes online (heartbeatOnly mode — just keeps TTL alive)
/// await engine.setDriverStatus(DriverStatus.online);
///
/// // Driver accepts a task (switches to adaptive mode)
/// await engine.setDriverStatus(DriverStatus.busy);
/// await engine.setTaskContext(taskId: 'task_abc', status: TaskStatus.inProgress);
/// engine.updateRoute(myPolyline);
///
/// // Task done
/// await engine.clearTaskContext();
/// engine.clearRoute();
///
/// // Driver clocks out
/// await engine.setDriverStatus(DriverStatus.offline);
/// await engine.stop();
/// await engine.dispose();
/// ```
///
/// ## Emission modes
/// | Driver status | Task status         | Mode            |
/// |---------------|---------------------|-----------------|
/// | offline       | any                 | no emit         |
/// | online        | any                 | heartbeatOnly   |
/// | busy          | assigned/inProgress | adaptive        |
/// | busy          | other               | heartbeatOnly   |
///
/// ## Required Android permissions
/// ```xml
/// <uses-permission android:name="android.permission.ACCESS_FINE_LOCATION" />
/// <uses-permission android:name="android.permission.ACCESS_COARSE_LOCATION" />
/// <!-- Background (foreground service): -->
/// <uses-permission android:name="android.permission.FOREGROUND_SERVICE" />
/// <uses-permission android:name="android.permission.FOREGROUND_SERVICE_LOCATION" />
/// ```
///
/// ## Required iOS permissions (Info.plist)
/// ```xml
/// <key>NSLocationWhenInUseUsageDescription</key>
/// <string>...</string>
/// <!-- Background: -->
/// <key>NSLocationAlwaysAndWhenInUseUsageDescription</key>
/// <string>...</string>
/// <key>UIBackgroundModes</key>
/// <array><string>location</string></array>
/// ```
class RelayDriverEngine {
  /// Creates an engine. Resolves [engineConfig] once and threads it into every
  /// collaborator so [config] and the sub-components can never diverge.
  factory RelayDriverEngine({
    required RelayTransportAdapter transport,
    EngineConfig? engineConfig,
    GpsKalmanFilter? kalmanFilter,
    EmissionPolicy? emissionPolicy,
    RouteSnapper? routeSnapper,
    DeviationDetector? deviationDetector,
    Stream<Position>? locationStream,
  }) {
    final config = engineConfig ?? EngineConfig();
    return RelayDriverEngine._(
      transport: transport,
      config: config,
      kalman:
          kalmanFilter ??
          GpsKalmanFilter(
            processNoise: config.kalmanProcessNoise,
            measurementNoise: config.kalmanMeasurementNoise,
          ),
      policy: emissionPolicy ?? EmissionPolicy(config),
      snapper:
          routeSnapper ??
          RouteSnapper(deviationThresholdMeters: config.deviationThresholdMeters),
      deviationDetector: deviationDetector ?? DeviationDetector(config),
      injectedLocationStream: locationStream,
    );
  }

  RelayDriverEngine._({
    required this.transport,
    required this.config,
    required GpsKalmanFilter kalman,
    required EmissionPolicy policy,
    required RouteSnapper snapper,
    required DeviationDetector deviationDetector,
    required Stream<Position>? injectedLocationStream,
  }) : _kalman = kalman,
       _policy = policy,
       _snapper = snapper,
       _deviationDetector = deviationDetector,
       _injectedLocationStream = injectedLocationStream;

  final EngineConfig config;
  final RelayTransportAdapter transport;

  final GpsKalmanFilter _kalman;
  final EmissionPolicy _policy;
  final RouteSnapper _snapper;
  final DeviationDetector _deviationDetector;
  final Stream<Position>? _injectedLocationStream;

  final _eventController = StreamController<EngineEvent>.broadcast(sync: true);
  StreamSubscription<Position>? _locationSub;
  StreamSubscription<bool>? _transportStateSub;

  DriverStatus _driverStatus = DriverStatus.offline;
  TaskStatus? _taskStatus;
  String? _taskId;
  bool _running = false;

  /// All engine events. Listen here for location updates, deviation alerts,
  /// state changes, and errors.
  Stream<EngineEvent> get events => _eventController.stream;

  DriverStatus get driverStatus => _driverStatus;

  TaskStatus? get taskStatus => _taskStatus;

  String? get taskId => _taskId;

  bool get isRunning => _running;

  EmissionMode get emissionMode => _policy.mode;

  // ---------------------------------------------------------------------------
  // Lifecycle

  /// Initialises the engine: connects transport, starts location stream.
  ///
  /// Does not begin emitting until [setDriverStatus] is called with
  /// [DriverStatus.online] or [DriverStatus.busy].
  Future<void> start() async {
    if (_running) return;

    transport.onError = (e) => _emit(EngineError('Transport error', error: e));

    _transportStateSub = transport.connectionState.listen((connected) {
      _emit(TransportStateChanged(connected));
    });

    try {
      await transport.connect();
      _running = true;
      // GPS only runs while the driver is online/busy — see _syncLocationStream.
      // The engine starts offline, so no GPS hardware is engaged until the
      // driver actually clocks in.
      _syncLocationStream();
    } catch (_) {
      _running = false;
      await _transportStateSub?.cancel();
      _transportStateSub = null;
      rethrow;
    }
  }

  /// Gracefully stops the engine.
  Future<void> stop() async {
    if (!_running) return;
    _running = false;
    await _locationSub?.cancel();
    _locationSub = null;
    await _transportStateSub?.cancel();
    await transport.disconnect();
    _kalman.reset();
    _policy.reset();
    _snapper.clearRoute();
    _deviationDetector.reset();
  }

  // ---------------------------------------------------------------------------
  // Driver + Task state

  /// Update the driver's online presence status.
  ///
  /// - `offline` → stops all emissions; sends immediate offline signal to backend
  /// - `online`  → heartbeatOnly mode (keeps TTL alive while driver is available)
  /// - `busy`    → mode depends on current task status (adaptive if active trip)
  Future<void> setDriverStatus(DriverStatus status) async {
    if (status == _driverStatus) return;
    final previous = _driverStatus;
    _driverStatus = status;
    _policy.setMode(_resolveEmissionMode());
    _emit(DriverStatusChanged(previous, status));

    // Engage GPS when clocking in, release it when clocking out — no point
    // burning the high-accuracy location stream while the driver is offline.
    _syncLocationStream();

    if (status == DriverStatus.offline) {
      _kalman.reset();
      _policy.reset();
      try {
        await transport.send({
          'event': 'driver:offline',
          'ts': DateTime.now().millisecondsSinceEpoch,
        });
      } catch (e) {
        _emit(EngineError('Failed to send offline signal', error: e));
      }
    }
  }

  /// Attach task context to all subsequent location updates.
  ///
  /// If [status] is an active-trip status (`assigned` or `inProgress`) and
  /// the driver is `busy`, the engine switches to adaptive emission mode.
  Future<void> setTaskContext({
    required String taskId,
    required TaskStatus status,
  }) async {
    _taskId = taskId;
    _taskStatus = status;
    _policy.setMode(_resolveEmissionMode());
    _emit(TaskContextChanged(taskId: taskId, taskStatus: status));
  }

  /// Clear task context when a task is completed or cancelled.
  ///
  /// Engine reverts to heartbeatOnly — driver is idle again.
  Future<void> clearTaskContext() async {
    _taskId = null;
    _taskStatus = null;
    _policy.setMode(_resolveEmissionMode());
    _emit(const TaskContextChanged());
  }

  /// Derives the correct [EmissionMode] from current driver + task state.
  EmissionMode _resolveEmissionMode() {
    if (_driverStatus == DriverStatus.busy &&
        (_taskStatus?.isActiveTrip ?? false)) {
      return EmissionMode.adaptive;
    }
    return EmissionMode.heartbeatOnly;
  }

  // ---------------------------------------------------------------------------
  // Route management

  /// Load or replace the active route polyline.
  ///
  /// Safe to call mid-trip — the snapper hot-swaps and the deviation
  /// detector resets, preventing a spurious [RouteDeviationDetected] event.
  void updateRoute(List<LatLng> polyline) {
    if (polyline.length < 2) return; // need at least 2 points to snap
    _snapper.updateRoute(polyline);
    _deviationDetector.reset();
    _emit(RouteUpdated(polyline.length));
  }

  /// Remove the active route (e.g. task completed).
  void clearRoute() {
    _snapper.clearRoute();
    _deviationDetector.reset();
  }

  // ---------------------------------------------------------------------------
  // Internal — location processing pipeline

  /// Starts/stops the GPS subscription to match driver presence: the stream is
  /// only active while running and online/busy. Idempotent — safe to call on
  /// every state transition.
  void _syncLocationStream() {
    final shouldRun = _running && _driverStatus.shouldEmit;
    if (shouldRun && _locationSub == null) {
      _startLocationStream();
    } else if (!shouldRun && _locationSub != null) {
      final sub = _locationSub;
      _locationSub = null;
      sub?.cancel().ignore();
    }
  }

  void _startLocationStream() {
    if (_locationSub != null) return;
    final stream =
        _injectedLocationStream ??
        Geolocator.getPositionStream(locationSettings: _locationSettings());

    _locationSub = stream.listen(
      _onPosition,
      onError: (Object e) =>
          _emit(EngineError('Location stream error', error: e)),
    );
  }

  /// Returns platform-appropriate [LocationSettings].
  ///
  /// Uses `defaultTargetPlatform`/`kIsWeb` rather than `dart:io Platform` so the
  /// engine compiles and runs on Flutter Web (where `dart:io` is unavailable).
  LocationSettings _locationSettings() {
    if (!kIsWeb && defaultTargetPlatform == TargetPlatform.android) {
      return AndroidSettings(
        accuracy: LocationAccuracy.high,
        distanceFilter: 0, // engine manages filtering
        intervalDuration: const Duration(seconds: 1),
        foregroundNotificationConfig: config.enableBackground
            ? ForegroundNotificationConfig(
                notificationText: config.backgroundNotificationContent,
                notificationTitle: config.backgroundNotificationTitle,
                enableWakeLock: true,
                setOngoing: true,
              )
            : null,
      );
    }

    if (!kIsWeb && defaultTargetPlatform == TargetPlatform.iOS) {
      return AppleSettings(
        accuracy: LocationAccuracy.bestForNavigation,
        distanceFilter: 0,
        activityType: ActivityType.automotiveNavigation,
        pauseLocationUpdatesAutomatically: false,
        allowBackgroundLocationUpdates: config.enableBackground,
        showBackgroundLocationIndicator: config.enableBackground,
      );
    }

    // Web / desktop fallback
    return const LocationSettings(
      accuracy: LocationAccuracy.high,
      distanceFilter: 0,
    );
  }

  void _onPosition(Position raw) {
    if (!_driverStatus.shouldEmit) return;

    final now = DateTime.now();

    // 1. Kalman filter — smooth GPS noise (Δt-aware via the fix timestamp)
    final (filteredLat, filteredLng) = _kalman.filter(
      raw.latitude,
      raw.longitude,
      accuracyMeters: raw.accuracy,
      timestamp: now,
    );

    // 2. Route snapping
    final SnapResult snap;
    if (config.snapToRouteEnabled && _snapper.hasRoute) {
      snap = _snapper.snap((lat: filteredLat, lng: filteredLng));
    } else {
      snap = SnapResult(
        snapped: (lat: filteredLat, lng: filteredLng),
        deviationMeters: 0,
        segmentIndex: 0,
        wasSnapped: false,
      );
    }

    // 3. Deviation detection — only meaningful when we have a route
    if (_snapper.hasRoute) {
      final deviationFired = _deviationDetector.record(snap.deviationMeters);
      if (deviationFired) {
        _emit(
          RouteDeviationDetected(
            currentLat: snap.snapped.lat,
            currentLng: snap.snapped.lng,
            deviationMeters: snap.deviationMeters,
            taskId: _taskId,
          ),
        );
      }
    }

    // 4. Emission policy
    final normalizedSpeed = raw.speed < 0 ? 0.0 : raw.speed;
    final normalizedHeading = raw.heading < 0 ? 0.0 : raw.heading;

    final decision = _policy.evaluate(
      lat: snap.snapped.lat,
      lng: snap.snapped.lng,
      speed: normalizedSpeed,
      heading: normalizedHeading,
      now: now,
    );

    if (!decision.shouldEmit) return;

    // 5. Build + transmit
    final update = LocationUpdate(
      lat: snap.snapped.lat,
      lng: snap.snapped.lng,
      rawLat: raw.latitude,
      rawLng: raw.longitude,
      heading: normalizedHeading,
      speed: normalizedSpeed,
      accuracyMeters: raw.accuracy,
      timestamp: now,
      driverStatus: _driverStatus,
      taskStatus: _taskStatus,
      taskId: _taskId,
      isSnapped: snap.wasSnapped,
      deviationMeters: snap.deviationMeters,
      isHeartbeat: decision.reason == EmitReason.heartbeat,
      snappedSegmentIndex: snap.wasSnapped ? snap.segmentIndex : null,
    );

    // Fire-and-forget send — errors surface via EngineError event.
    // .ignore() explicitly marks the Future as intentionally not awaited,
    // satisfying the unawaited_futures linter rule.
    transport
        .send(update.toJson())
        .then((_) {
          _policy.recordEmission(
            lat: snap.snapped.lat,
            lng: snap.snapped.lng,
            heading: normalizedHeading,
            now: now,
          );
          _emit(LocationEmitted(update));
        })
        .catchError((Object e) {
          _emit(EngineError('Send failed', error: e));
          return null;
        })
        .ignore();
  }

  void _emit(EngineEvent event) {
    if (!_eventController.isClosed) _eventController.add(event);
  }

  /// Dispose the engine permanently. Call once when the widget/page is destroyed.
  Future<void> dispose() async {
    await stop();
    await _eventController.close();
  }
}
