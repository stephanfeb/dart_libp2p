import 'package:dart_libp2p/core/peer/peer_id.dart';

/// Observer interface for Circuit Relay v2 client metrics
/// 
/// This optional callback interface allows external metrics collectors
/// to observe relay events for monitoring and performance analysis.
abstract class RelayMetricsObserver {
  /// Called when a relay reservation is requested
  void onReservationRequested(PeerId relayPeer, DateTime timestamp);

  /// Called when a relay reservation is completed
  void onReservationCompleted(
    PeerId relayPeer,
    DateTime requestTime,
    DateTime completeTime,
    Duration duration,
    bool success,
    String? error,
  );

  /// Called when a relay dial is initiated
  void onRelayDialStarted(PeerId relayPeer, PeerId destPeer, DateTime timestamp);

  /// Called when a relay dial is completed
  void onRelayDialCompleted(
    PeerId relayPeer,
    PeerId destPeer,
    DateTime startTime,
    DateTime completeTime,
    Duration duration,
    bool success,
    String? error,
  );
}

