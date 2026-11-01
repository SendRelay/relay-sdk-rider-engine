## 0.4.0

- While the driver is online or busy, the engine now re-sends the last known fix,
  marked `isHeartbeat`, whenever nothing has been sent for a whole
  `heartbeatInterval`. A phone whose GPS stops producing fixes (indoors,
  stationary, OS throttling) therefore keeps reaching the backend for as long as
  its network is up, instead of silently dropping out of dispatch while the app
  shows Online. Nothing is sent before the first fix or after going offline.

## 0.3.0

- Worked on improvements for `deviation_detector.dart` and `route_snapper.dart` 

## 0.2.1

- Expanded README with a complete exported API map and corrected example layout.
- Added additional runnable examples for task lifecycle and custom transport adapters.
- Refined publish metadata and API docs for stronger pub.dev scoring compliance.

## 0.2.0

- Stabilized transport lifecycle and send-path error handling for production use.
- Fixed route snapping deviation checks to use nearest segment distance.
- Improved docs and publishing metadata, and added a runnable package example.

## 0.1.0

- Initial public release of `relay_driver_engine`.
- Added adaptive/heartbeat emission policies with heading and speed triggers.
- Added Kalman filtering, route snapping, and route deviation detection.
- Added transport abstraction with reconnect handling and engine lifecycle events.
