import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'package:web_socket_channel/io.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

/// Implement this to plug any transport into [RelayDriverEngine].
///
/// The engine calls [send] with a JSON-serialisable payload. You decide how
/// to serialise and route it — WebSocket, socket.io, HTTP, MQTT, anything.
///
/// ### Custom adapter example (socket.io)
/// ```dart
/// class SocketIoAdapter implements RelayTransportAdapter {
///   final IO.Socket _socket;
///   final _connController = StreamController<bool>.broadcast();
///
///   @override
///   Future<void> connect() async {
///     _socket.onConnect((_) => _connController.add(true));
///     _socket.onDisconnect((_) => _connController.add(false));
///     _socket.connect();
///   }
///
///   @override
///   Future<void> send(Map<String, dynamic> payload) async =>
///       _socket.emit('driver:location', payload);
///
///   @override
///   Future<void> disconnect() async {
///     _socket.disconnect();
///     await _connController.close();
///   }
///
///   @override
///   Stream<bool> get connectionState => _connController.stream;
///
///   @override
///   void Function(Object error)? onError;
/// }
/// ```
abstract class RelayTransportAdapter {
  /// Establish the connection. Called once by the engine on [start].
  Future<void> connect();

  /// Send a location payload.
  ///
  /// Complete normally on success and **throw on failure** — the engine relies
  /// on a thrown/rejected future to surface an [EngineError] and, crucially, to
  /// avoid advancing its emission throttle state (so the next fix retries the
  /// send). Best-effort adapters that genuinely cannot detect delivery failure
  /// may simply complete. Use [onError] for asynchronous/connection-level
  /// errors that occur outside a [send] call.
  Future<void> send(Map<String, dynamic> payload);

  /// Tear down the connection. Called by the engine on [stop].
  Future<void> disconnect();

  /// Broadcasts connection state changes (true = connected, false = dropped).
  Stream<bool> get connectionState;

  /// Set by the engine. Call this from [send] and [connect] on error.
  void Function(Object error)? onError;
}

// ---------------------------------------------------------------------------

/// Default WebSocket transport adapter.
///
/// Uses [IOWebSocketChannel] (dart:io based) which supports custom headers —
/// required for Authorization tokens. **Not compatible with Flutter Web.**
/// For web targets, implement [RelayTransportAdapter] using the browser's
/// native WebSocket API.
///
/// Features:
/// - Sends custom HTTP headers on every connection (use for Bearer tokens)
/// - Guards against concurrent connection attempts
/// - Exponential backoff with jitter, capped at [maxReconnectDelay]
/// - Retries indefinitely by default (a delivery driver should keep trying to
///   reconnect); set [maxReconnectAttempts] > 0 to cap attempts instead
/// - Cleans up previous stream subscription before reconnecting
///
/// ```dart
/// final adapter = WebSocketTransportAdapter(
///   uri: Uri.parse('wss://api.relay.ng/ws/driver'),
///   headers: {'Authorization': 'Bearer $token'},
/// );
/// ```
class WebSocketTransportAdapter implements RelayTransportAdapter {
  WebSocketTransportAdapter({
    required this.uri,
    this.headers = const {},
    this.reconnectDelay = const Duration(seconds: 3),
    this.maxReconnectDelay = const Duration(seconds: 60),
    this.maxReconnectAttempts = 0,
  });

  final Uri uri;

  /// HTTP headers sent on every (re)connection handshake.
  /// Use this for Authorization: Bearer tokens.
  final Map<String, dynamic> headers;

  /// Base delay for the first reconnect attempt; subsequent attempts back off
  /// exponentially (2ⁿ) up to [maxReconnectDelay].
  final Duration reconnectDelay;

  /// Upper bound on the exponential backoff delay.
  final Duration maxReconnectDelay;

  /// Maximum reconnect attempts before giving up. `0` (the default) means retry
  /// indefinitely — the driver stays in the reconnect loop until [disconnect].
  final int maxReconnectAttempts;

  WebSocketChannel? _channel;
  StreamSubscription<dynamic>? _channelSub;
  StreamController<bool> _connectionController =
      StreamController<bool>.broadcast();

  final _random = math.Random();

  bool _intentionalDisconnect = false;
  bool _connecting = false;
  int _reconnectAttempts = 0;

  @override
  void Function(Object error)? onError;

  @override
  Stream<bool> get connectionState => _connectionController.stream;

  @override
  Future<void> connect() async {
    _intentionalDisconnect = false;
    _reconnectAttempts = 0;
    await _doConnect();
  }

  Future<void> _doConnect() async {
    if (_connecting) return;
    _connecting = true;

    await _channelSub?.cancel();
    _channelSub = null;

    try {
      // IOWebSocketChannel properly forwards headers in the HTTP upgrade
      // handshake — plain WebSocketChannel.connect does not.
      _channel = IOWebSocketChannel.connect(uri, headers: headers);
      await _channel!.ready;

      _connecting = false;
      _reconnectAttempts = 0;
      if (!_connectionController.isClosed) _connectionController.add(true);

      _channelSub = _channel!.stream.listen(
        (_) {}, // engine does not consume inbound frames
        onDone: _onDisconnect,
        onError: (Object e) {
          onError?.call(e);
          _onDisconnect();
        },
        cancelOnError: true,
      );
    } catch (e) {
      _connecting = false;
      onError?.call(e);
      if (!_connectionController.isClosed) _connectionController.add(false);
      _scheduleReconnect();
    }
  }

  void _onDisconnect() {
    _connecting = false;
    if (!_connectionController.isClosed) _connectionController.add(false);
    if (!_intentionalDisconnect) _scheduleReconnect();
  }

  void _scheduleReconnect() {
    // maxReconnectAttempts <= 0 means retry indefinitely.
    if (maxReconnectAttempts > 0 && _reconnectAttempts >= maxReconnectAttempts) {
      onError?.call(
        Exception(
          'WebSocket: max reconnect attempts ($maxReconnectAttempts) reached',
        ),
      );
      return;
    }
    _reconnectAttempts++;
    // .ignore() satisfies the unawaited_futures linter — this is intentionally
    // fire-and-forget; the callback guards against stale reconnect attempts.
    Future.delayed(_backoffDelay(_reconnectAttempts), () {
      if (!_intentionalDisconnect) _doConnect();
    }).ignore();
  }

  /// Exponential backoff (base × 2ⁿ⁻¹) capped at [maxReconnectDelay], with up to
  /// ±25% jitter so a fleet of drivers doesn't reconnect in lockstep after a
  /// server blip.
  Duration _backoffDelay(int attempt) {
    final baseMs = reconnectDelay.inMilliseconds;
    final capMs = maxReconnectDelay.inMilliseconds;
    // Clamp the exponent to avoid overflow on long outages.
    final factor = math.pow(2, math.min(attempt - 1, 16)).toDouble();
    final cappedMs = math.min(capMs, baseMs * factor).toDouble();
    final jitter = 1 + (_random.nextDouble() - 0.5) * 0.5; // 0.75–1.25×
    return Duration(milliseconds: (cappedMs * jitter).round());
  }

  @override
  Future<void> send(Map<String, dynamic> payload) async {
    final channel = _channel;
    if (channel == null) {
      // Throw rather than swallow: the engine must see the failure so it emits
      // an EngineError and does NOT advance emission state (preventing false
      // LocationEmitted events and dropped updates while disconnected).
      throw StateError('WebSocket not connected');
    }
    channel.sink.add(jsonEncode(payload));
  }

  @override
  Future<void> disconnect() async {
    _intentionalDisconnect = true;
    _connecting = false;
    _reconnectAttempts = 0;
    await _channelSub?.cancel();
    _channelSub = null;
    await _channel?.sink.close();
    _channel = null;
    // Close the controller so it isn't leaked, then immediately swap in a fresh
    // open one. The engine subscribes to connectionState *before* calling
    // connect() on a restart, so the controller must already be open by then —
    // recreating here (rather than in connect()) keeps that invariant.
    if (!_connectionController.isClosed) {
      _connectionController.add(false);
      final old = _connectionController;
      _connectionController = StreamController<bool>.broadcast();
      await old.close();
    }
  }
}
