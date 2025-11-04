import 'dart:async';

import '../../../core/network/stream.dart';
import '../../../core/network/mux.dart' as core_mux;
import '../../../core/network/transport_conn.dart';
import '../../../core/network/rcmgr.dart';

/// Represents a stream multiplexer that can create and manage multiple logical streams
/// over a single connection.
abstract class Multiplexer {
  /// The protocol ID for this multiplexer (e.g., '/yamux/1.0.0')
  String get protocolId;

  // newStream removed, users should get a MuxedConn via newConnOnTransport and use its openStream.
  // Future<P2PStream> newStream(Context context); 

  /// Accepts an inbound stream
  Future<P2PStream> acceptStream();

  /// Returns all active streams
  Future<List<P2PStream>> get streams; // Changed to Future

  /// Event stream for new inbound streams
  Stream<P2PStream> get incomingStreams;

  /// Closes the multiplexer and all its streams
  Future<void> close();

  /// Returns true if the multiplexer is closed
  bool get isClosed;

  /// The maximum number of concurrent streams allowed
  int get maxStreams;

  /// The current number of active streams
  int get numStreams;

  /// Returns true if we can create more streams
  bool get canCreateStream;

  /// Sets the stream handler for accepting new streams
  void setStreamHandler(Future<void> Function(P2PStream stream) handler);

  /// Removes the stream handler
  void removeStreamHandler();

  /// Establishes a new multiplexed connection over an existing transport connection.
  ///
  /// [secureConnection]: The underlying (typically secured) transport connection.
  /// [isServer]: True if this side is the server in the multiplexer handshake.
  /// [scope]: The peer-specific resource scope for this connection.
  /// Returns a [core_mux.MuxedConn] representing the multiplexed connection.
  Future<core_mux.MuxedConn> newConnOnTransport(
    TransportConn secureConnection,
    bool isServer,
    PeerScope scope
  );
}

/// Configuration for stream multiplexing
class MultiplexerConfig {
  /// Maximum number of concurrent streams (default: 1000)
  final int maxStreams;

  /// Initial stream window size in bytes (default: 256KB)
  final int initialStreamWindowSize;

  /// Maximum stream window size in bytes (default: 16MB)
  final int maxStreamWindowSize;

  /// Stream read timeout (default: 30 seconds)
  final Duration streamReadTimeout;

  /// Stream write timeout (default: 30 seconds)
  final Duration streamWriteTimeout;

  /// Keep-alive interval (default: 10 seconds)
  final Duration keepAliveInterval;

  /// Connection-level read timeout for idle connections (default: 35 seconds)
  /// This should be at least 3x the keepAliveInterval to allow for keepalive pings
  /// before timing out an idle connection.
  final Duration connectionReadTimeout;

  const MultiplexerConfig({
    this.maxStreams = 1000,
    this.initialStreamWindowSize = 256 * 1024, // 256KB
    this.maxStreamWindowSize = 16 * 1024 * 1024, // 16MB
    this.streamReadTimeout = const Duration(seconds: 30),
    this.streamWriteTimeout = const Duration(seconds: 30),
    this.keepAliveInterval = const Duration(seconds: 10),
    this.connectionReadTimeout = const Duration(seconds: 35), // 3.5x keepalive
  });
}
