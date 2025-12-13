import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:dart_libp2p/core/crypto/keys.dart';
import 'package:dart_libp2p/core/multiaddr.dart';
import 'package:dart_libp2p/core/network/common.dart';
// Conn, ConnState, ConnStats, Stats are used from conn.dart
// ConnScope will come from rcmgr.dart
import 'package:dart_libp2p/core/network/conn.dart' show Conn, ConnState, ConnStats, Stats; 
import 'package:dart_libp2p/core/network/transport_conn.dart';
import 'package:dart_libp2p/core/network/context.dart';
import 'package:dart_libp2p/core/network/stream.dart'; // For P2PStream
import 'package:dart_libp2p/core/network/rcmgr.dart' show ConnScope, ScopeStat, ResourceScopeSpan, ResourceScope;
import 'package:dart_libp2p/core/peer/peer_id.dart';

/// Mock connection specialized for secured connection tests
/// Focuses on length prefixing and message boundaries
class SecuredMockConnection implements TransportConn {
  // Stream controllers for bidirectional communication
  final _incomingData = StreamController<List<int>>.broadcast();
  final _outgoingData = StreamController<List<int>>.broadcast();

  // Buffer for incoming data
  final _buffer = <int>[];

  // Stream subscription for cleanup
  StreamSubscription<List<int>>? _subscription;

  // Connection properties
  final String _id;
  bool _closed = false;
  final writes = <Uint8List>[];
  final int? _chunkSize; // If set, simulate chunked delivery like UDX

  SecuredMockConnection(this._id, {int? chunkSize}) : _chunkSize = chunkSize;

  /// Creates a pair of connected secured mock connections
  /// 
  /// If [chunkSize] is provided, data will be delivered in chunks of that size
  /// to simulate UDP fragmentation behavior (e.g., UDX with ~1400 byte MTU)
  static (SecuredMockConnection, SecuredMockConnection) createPair({
    String id1 = 'secured1',
    String id2 = 'secured2',
    int? chunkSize,
  }) {
    final conn1 = SecuredMockConnection(id1, chunkSize: chunkSize);
    final conn2 = SecuredMockConnection(id2, chunkSize: chunkSize);

    // Wire up bidirectional communication
    // Data flows: conn2._outgoingData -> conn1._incomingData
    // The read() method will consume from _incomingData and populate _buffer
    conn1._subscription = conn2._outgoingData.stream.listen((data) {
      if (!conn1.isClosed) {
        conn1._incomingData.add(data);
      }
    });

    conn2._subscription = conn1._outgoingData.stream.listen((data) {
      if (!conn2.isClosed) {
        conn2._incomingData.add(data);
      }
    });

    return (conn1, conn2);
  }

  @override
  Future<void> close() async {
    if (_closed) return;

    await _subscription?.cancel();
    await _incomingData.close();
    await _outgoingData.close();
    _buffer.clear();
    _closed = true;
  }

  @override
  String get id => _id;

  @override
  bool get isClosed => _closed;

  @override
  MultiAddr get localMultiaddr => MultiAddr('/ip4/127.0.0.1/tcp/1234');

  @override
  MultiAddr get remoteMultiaddr => MultiAddr('/ip4/127.0.0.1/tcp/5678');

  @override
  PeerId get localPeer => throw UnimplementedError('localPeer not implemented in SecuredMockConnection');

  @override
  PeerId get remotePeer => throw UnimplementedError('remotePeer not implemented in SecuredMockConnection');

  @override
  Future<PublicKey?> get remotePublicKey async => null;

  @override
  ConnState get state => ConnState(
    streamMultiplexer: 'mock-muxer/1.0.0',
    security: 'mock-security/1.0.0',
    transport: 'mock',
    usedEarlyMuxerNegotiation: false,
  );

  @override
  ConnStats get stat => _MockConnStats(
    stats: Stats(
      direction: Direction.outbound,
      opened: DateTime.now(),
    ),
    numStreams: 0,
  );

  @override
  ConnScope get scope => _MockConnScope();

  @override
  Future<P2PStream> newStream(Context context) async {
    throw UnimplementedError('Stream multiplexing not implemented in SecuredMockConnection');
  }

  @override
  Future<List<P2PStream>> get streams async => [];

  @override
  Socket get socket => throw UnimplementedError('Socket is not implemented in SecuredMockConnection');

  @override
  void setReadTimeout(Duration timeout) {}

  @override
  void setWriteTimeout(Duration timeout) {}

  @override
  Future<Uint8List> read([int? length]) async {
    if (_closed) {
      throw StateError('Connection is closed');
    }

    try {
      // Must specify length for secured connections
      if (length == null) {
        throw ArgumentError('Length must be specified for secured connections');
      }

      // If we already have enough data in the buffer, return it immediately
      if (_buffer.length >= length) {
        final result = Uint8List.fromList(_buffer.take(length).toList());
        _buffer.removeRange(0, length);
        return result;
      }

      // Wait until we have enough data
      final completer = Completer<void>();
      late StreamSubscription<List<int>> sub;
      
      sub = _incomingData.stream.listen((data) {
        _buffer.addAll(data);
        if (_buffer.length >= length && !completer.isCompleted) {
          completer.complete();
          sub.cancel();
        }
      }, onError: (e) {
        if (!completer.isCompleted) {
          completer.completeError(e);
        }
      });
      
      // Wait for enough data with timeout
      await completer.future.timeout(
        Duration(seconds: 5),
        onTimeout: () {
          sub.cancel();
          throw TimeoutException('Read timed out waiting for $length bytes, got ${_buffer.length}');
        },
      );

      // Return exactly the requested number of bytes
      final result = Uint8List.fromList(_buffer.take(length).toList());
      _buffer.removeRange(0, length);
      return result;
    } catch (e) {
      rethrow;
    }
  }

  @override
  Future<void> write(Uint8List data) async {
    if (_closed) {
      throw StateError('Connection is closed');
    }
    writes.add(data);
    
    // If chunkSize is set, simulate fragmented delivery (like UDX over UDP)
    if (_chunkSize != null && data.length > _chunkSize!) {
      // Send data in chunks with small delays to simulate network timing
      for (var offset = 0; offset < data.length; offset += _chunkSize!) {
        final end = (offset + _chunkSize! < data.length) ? offset + _chunkSize! : data.length;
        final chunk = data.sublist(offset, end);
        _outgoingData.add(chunk);
        
        // Small delay to simulate packet arrival timing jitter
        if (end < data.length) {
          await Future.delayed(Duration(microseconds: 100));
        }
      }
    } else {
      // Send as single chunk
      _outgoingData.add(data);
    }
  }

  /// For testing: get current buffer size
  int get debugBufferSize => _buffer.length;

  /// For testing: get buffer contents
  List<int> debugGetBufferContents() => List<int>.from(_buffer);

  @override
  void notifyActivity() {
    // Mock implementation, can be empty or log
  }
}

/// Mock implementation of ConnStats
class _MockConnStats implements ConnStats {
  @override
  final Stats stats;

  @override
  final int numStreams;

  const _MockConnStats({
    required this.stats,
    required this.numStreams,
  });
}

/// Mock implementation of ConnScope
class _MockConnScope implements ConnScope {
  @override
  Future<ResourceScopeSpan> beginSpan() async {
    return _MockResourceScopeSpan();
  }

  @override
  void releaseMemory(int size) {}

  @override
  Future<void> reserveMemory(int size, int priority) async {}

  @override
  ScopeStat get stat => const ScopeStat(); // Renamed scopeStat to stat. ScopeStat from rcmgr.dart
}

/// Mock implementation of ResourceScopeSpan
class _MockResourceScopeSpan implements ResourceScopeSpan { // ResourceScopeSpan from rcmgr.dart
  @override
  Future<ResourceScopeSpan> beginSpan() async { // ResourceScopeSpan from rcmgr.dart
    return this;
  }

  @override
  void done() {}

  @override
  void releaseMemory(int size) {}

  @override
  Future<void> reserveMemory(int size, int priority) async {}

  @override
  ScopeStat get stat => const ScopeStat(); // Renamed scopeStat to stat. ScopeStat from rcmgr.dart
}
