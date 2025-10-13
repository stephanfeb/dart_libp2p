// Copyright (c) 2022 The dart-libp2p Authors. All rights reserved.
// Use of this source code is governed by a BSD-style
// license that can be found in the LICENSE file.

import 'dart:async';
import 'dart:typed_data';

import 'package:dart_libp2p/core/peer/peer_id.dart';
import 'package:dart_libp2p/p2p/protocol/circuitv2/pb/circuit.pb.dart';
import 'package:dart_libp2p/p2p/protocol/circuitv2/proto.dart';
import 'package:dart_libp2p/p2p/protocol/circuitv2/relay/resources.dart';
import 'package:dart_libp2p/p2p/protocol/circuitv2/util/io.dart';
import 'package:dart_libp2p/p2p/protocol/circuitv2/util/pbconv.dart';
import 'package:dart_libp2p/p2p/protocol/circuitv2/voucher.dart';
import 'package:dart_libp2p/p2p/protocol/multistream/client.dart'; // For encodeVarint
import 'package:fixnum/fixnum.dart';
import 'package:meta/meta.dart';

import '../../../../core/host/host.dart';
import '../../../../core/network/stream.dart';
import '../../../../core/network/context.dart';
import '../../../../core/multiaddr.dart';
import '../../../discovery/peer_info.dart';

/// Relay implements the relay service for the p2p-circuit/v2 protocol.
class Relay {
  final Host _host;
  final Resources _resources;
  final Map<String, DateTime> _reservations = {};
  final Map<String, int> _connections = {};
  Timer? _gcTimer;
  bool _closed = false;

  /// Creates a new relay service.
  Relay(this._host, this._resources);

  /// Starts the relay service.
  void start() {
    _host.setStreamHandler(CircuitV2Protocol.protoIDv2Hop, (stream, remotePeer) => _handleStream(stream));
    _startGarbageCollection();
  }

  /// Closes the relay service.
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _host.removeStreamHandler(CircuitV2Protocol.protoIDv2Hop);
    _gcTimer?.cancel();
  }

  /// Handles incoming streams for the relay protocol.
  Future<void> _handleStream(P2PStream stream) async {
    try {
      // Read the length-delimited message (client sends with length prefix)
      print('[Relay] Creating stream reader for incoming message');
      final reader = DelimitedReader(_p2pStreamToDartStream(stream), 4096); // maxMessageSize
      print('[Relay] Reading message...');
      final pb = await reader.readMsg(HopMessage());
      print('[Relay] Message read successfully, type: ${pb.type}');

      // Handle the message based on its type
      switch (pb.type) {
        case HopMessage_Type.RESERVE:
          await _handleReserve(stream, pb);
          break;
        case HopMessage_Type.CONNECT:
          await _handleConnect(stream, pb);
          break;
        default:
          // Write an error response
          final response = HopMessage()
            ..type = HopMessage_Type.STATUS
            ..status = Status.UNEXPECTED_MESSAGE;
          await stream.write(response.writeToBuffer());
          await stream.close();
      }
    } catch (e) {
      // Write an error response
      final response = HopMessage()
        ..type = HopMessage_Type.STATUS
        ..status = Status.MALFORMED_MESSAGE;
      await stream.write(response.writeToBuffer());
      await stream.close();
      print('Error handling stream: $e');
    }
  }

  /// Handles a reservation request.
  Future<void> _handleReserve(P2PStream stream, HopMessage msg) async {
    // For RESERVE requests, the peer making the reservation is the remote peer of the stream
    final peerId = stream.conn.remotePeer;
    print('[Relay] Handling RESERVE from peer: ${peerId.toBase58()}');
    
    // Check if we have resources for a new reservation
    if (!_resources.canReserve(peerId)) {
      print('[Relay] Resource limit exceeded for peer: ${peerId.toBase58()}');
      await _writeResponse(stream, Status.RESOURCE_LIMIT_EXCEEDED);
      return;
    }

    // Create a reservation
    final expire = DateTime.now().add(Duration(seconds: _resources.reservationTtl));
    _reservations[peerId.toString()] = expire;
    print('[Relay] Reservation created for peer: ${peerId.toBase58()}, expires: $expire');

    // Create a reservation voucher
    final voucher = ReservationVoucherData(
      relay: _host.id,
      peer: peerId,
      expiration: expire,
    );

    // Create a reservation message
    final reservation = Reservation()
      ..expire = Int64(expire.millisecondsSinceEpoch ~/ 1000)
      ..addrs.addAll(
          _host.addrs
              .where((addr) => !addr.toString().contains('/p2p-circuit'))  // ← Filter!
              .map((addr) => addr.toBytes())
      )
      ..voucher = voucher.marshalRecord();

  // Create a limit message
  final limit = Limit()
    ..duration = _resources.connectionDuration
    ..data = Int64(_resources.connectionData);

  // Write the response (length-delimited)
  final response = HopMessage()
    ..type = HopMessage_Type.STATUS
    ..status = Status.OK
    ..reservation = reservation
    ..limit = limit;
  print('[Relay] Sending reservation response to peer: ${peerId.toBase58()}');
  
  // Write the message with a custom writer that tracks the write operation
  final writeCompleter = Completer<void>();
  final writer = StreamSinkFromP2PStream(stream, writeCompleter);
  writeDelimitedMessage(writer, response);
  
  // Wait for the write to complete before returning
  await writeCompleter.future;
  print('[Relay] Reservation response sent and flushed');
  
  // Add a small delay to ensure the data is transmitted
  await Future.delayed(Duration(milliseconds: 50));
}

  /// Handles a connection request.
  Future<void> _handleConnect(P2PStream stream, HopMessage msg) async {
    // The SOURCE peer is the one who opened this HOP stream (the peer dialing)
    final srcPeerId = stream.conn.remotePeer;
    
    // The DESTINATION peer is in msg.peer (the peer being dialed)
    if (!msg.hasPeer()) {
      await _writeResponse(stream, Status.MALFORMED_MESSAGE);
      return;
    }
    
    final dstInfo = peerToPeerInfoV2(msg.peer);
    if (dstInfo.peerId.toString().isEmpty) {
      await _writeResponse(stream, Status.MALFORMED_MESSAGE);
      return;
    }

    // Check if the DESTINATION peer has a reservation
    // (the peer being dialed TO needs the reservation, not the one dialing FROM)
    final reservation = _reservations[dstInfo.peerId.toString()];
    if (reservation == null || reservation.isBefore(DateTime.now())) {
      print('[Relay] NO_RESERVATION: ${dstInfo.peerId} does not have an active reservation');
      await _writeResponse(stream, Status.NO_RESERVATION);
      return;
    }

    // Check if we have resources for a new connection
    if (!_resources.canConnect(srcPeerId, dstInfo.peerId)) {
      await _writeResponse(stream, Status.RESOURCE_LIMIT_EXCEEDED);
      return;
    }

    try {
      // Open a STOP stream to the destination peer
      // Host.newStream() will:
      // 1. Check for existing connection (via connect())
      // 2. Create stream on that connection (via network.newStream())  
      // 3. Wait for identify
      // 4. Negotiate protocol
      // 5. Register protocol in peerstore
      print('[Relay] Opening STOP stream to destination peer: ${dstInfo.peerId.toBase58()}');
      final dstStream = await _host.newStream(
        dstInfo.peerId, 
        [CircuitV2Protocol.protoIDv2Stop], 
        Context()
      );
      print('[Relay] STOP stream opened and protocol negotiated with destination peer: ${dstInfo.peerId.toBase58()}');
      
      // Set handshake deadline for the STOP protocol handshake messages
      // This gives enough time for the STOP handshake to complete
      await dstStream.setDeadline(DateTime.now().add(Duration(minutes: 1)));
      print('[Relay] Set 1-minute handshake deadline on STOP stream');

      // Create a stop message with SOURCE peer info
      print('[Relay] Creating STOP message...');
      final stopMsg = StopMessage()
        ..type = StopMessage_Type.CONNECT
        ..peer = peerInfoToPeerV2(PeerInfo(peerId: srcPeerId, addrs: <MultiAddr>[].toSet()));
      print('[Relay] STOP message created, type: ${stopMsg.type}');

      // Write the message with length prefix (required for DelimitedReader on the receiving end)
      // We write manually to ensure both the length and message are sent before reading response
      print('[Relay] Encoding STOP message to bytes...');
      final messageBytes = stopMsg.writeToBuffer();
      print('[Relay] Message encoded to ${messageBytes.length} bytes');
      final lengthBytes = encodeVarint(messageBytes.length);
      print('[Relay] Writing length prefix (${lengthBytes.length} bytes) to STOP stream...');
      await dstStream.write(lengthBytes);
      print('[Relay] Length prefix written, now writing message bytes (${messageBytes.length} bytes)...');
      await dstStream.write(messageBytes);
      print('[Relay] Message bytes written, flushing stream...');
      // Flush the stream to ensure data is sent immediately
      if (dstStream is Sink) {
        // Most streams don't have a flush method, so we can't call it
        // The write should already flush automatically
      }
      print('[Relay] STOP message written successfully to destination peer: ${dstInfo.peerId.toBase58()}');

      // Read the response (destination sends with length prefix)
      print('[Relay] Reading STOP response from destination peer: ${dstInfo.peerId.toBase58()}...');
      final reader = DelimitedReader(_p2pStreamToDartStream(dstStream), 4096);
      final pb = await reader.readMsg(StopMessage());
      print('[Relay] STOP response received from destination peer: ${dstInfo.peerId.toBase58()}, status: ${pb.status}');

      // Check the status
      if (pb.status != Status.OK) {
        await _writeResponse(stream, Status.CONNECTION_FAILED);
        await dstStream.close();
        return;
      }

      // Write the response to the source
      await _writeResponse(stream, Status.OK);

      // Clear stream deadlines to allow unlimited relay time (like go-libp2p)
      // This prevents yamux read timeouts from closing the relay connection prematurely
      await stream.setDeadline(null);
      await dstStream.setDeadline(null);
      print('[Relay] Cleared deadlines on relay streams:');
      print('[Relay]   - HOP stream (from ${srcPeerId.toBase58()}): id=${stream.id()}');
      print('[Relay]   - STOP stream (to ${dstInfo.peerId.toBase58()}): id=${dstStream.id()}');

      // Add the connection to the active connections
      final connKey = '${srcPeerId}-${dstInfo.peerId}';
      final currentCount = _connections[connKey] ?? 0;
      _connections[connKey] = currentCount + 1;
      print('[Relay] Active relay connections for ${srcPeerId.toBase58()} -> ${dstInfo.peerId.toBase58()}: ${currentCount + 1}');
      if (currentCount > 0) {
        print('[Relay] ⚠️  WARNING: Multiple concurrent relay connections detected!');
      }

      // Relay data between the peers
      _relayData(stream, dstStream, srcPeerId, dstInfo.peerId);
    } catch (e) {
      await _writeResponse(stream, Status.CONNECTION_FAILED);
      print('Failed to connect to destination peer: $e');
    }
  }

  /// Relays data between two peers.
  @visibleForTesting
  void relayDataForTesting(
    P2PStream srcStream,
    P2PStream dstStream,
    PeerId srcPeer,
    PeerId dstPeer,
  ) {
    _relayData(srcStream, dstStream, srcPeer, dstPeer);
  }

  /// Relays data between two peers (internal).
  /// Implements bidirectional relay with proper EOF propagation and error handling.
  void _relayData(
    P2PStream srcStream,
    P2PStream dstStream,
    PeerId srcPeer,
    PeerId dstPeer,
  ) {
    final connKey = '${srcPeer}-${dstPeer}';
    var cleanupDone = false;

    // Idempotent cleanup function
    // Note: We do NOT close streams here - each direction closes its own write side via closeWrite()
    // and the streams will naturally close when both directions complete. Closing streams here
    // causes the other direction's blocking read() to fail with "stream closed" error.
    void cleanup() {
      if (cleanupDone) return;
      cleanupDone = true;
      
      // Update connection count
      final count = _connections[connKey] ?? 0;
      if (count <= 1) {
        _connections.remove(connKey);
      } else {
        _connections[connKey] = count - 1;
      }
      
      print('[Relay] Cleanup completed for ${srcPeer.toBase58()} -> ${dstPeer.toBase58()}');
    }

    // Relay data from source to destination
    Future<void> relaySourceToDest() async {
      try {
        int bytesRelayed = 0;
        while (true) {
          final data = await srcStream.read();
          if (data.isEmpty) {
            // EOF received - propagate to destination via closeWrite
            await dstStream.closeWrite().catchError((e) {
              print('[Relay] Error closing write on destination: $e');
            });
            break;
          }
          bytesRelayed += data.length;
          await dstStream.write(data);
        }
      } catch (e) {
        print('[Relay] Error relaying data from source to destination: $e');
        // Reset both streams on error (like go-libp2p)
        await srcStream.reset().catchError((resetErr) {
          print('[Relay] Error resetting source stream: $resetErr');
        });
        await dstStream.reset().catchError((resetErr) {
          print('[Relay] Error resetting destination stream: $resetErr');
        });
      } finally {
        cleanup();
      }
    }

    // Relay data from destination to source
    Future<void> relayDestToSource() async {
      try {
        int bytesRelayed = 0;
        while (true) {
          final data = await dstStream.read();
          if (data.isEmpty) {
            // EOF received - propagate to source via closeWrite
            print('[Relay] EOF from destination after relaying $bytesRelayed bytes total');
            await srcStream.closeWrite().catchError((e) {
              print('[Relay] Error closing write on source: $e');
            });
            break;
          }
          bytesRelayed += data.length;
          await srcStream.write(data);
        }
      } catch (e) {
        print('[Relay] Error relaying data from destination to source: $e');
        // Reset both streams on error (like go-libp2p)
        await dstStream.reset().catchError((resetErr) {
          print('[Relay] Error resetting destination stream: $resetErr');
        });
        await srcStream.reset().catchError((resetErr) {
          print('[Relay] Error resetting source stream: $resetErr');
        });
      } finally {
        cleanup();
      }
    }

    // Start both relay tasks concurrently and wait for both to complete
    // before doing final stream cleanup
    Future<void> startRelay() async {
      await Future.wait([
        relaySourceToDest(),
        relayDestToSource(),
      ]);
      
      // Both directions completed - now it's safe to close any remaining open streams
      // This handles edge cases where closeWrite() didn't fully close the stream
      if (!srcStream.isClosed) {
        print('[Relay] Final cleanup: closing source stream');
        await srcStream.close().catchError((e) {
          print('[Relay] Error in final source stream close: $e');
        });
      }
      if (!dstStream.isClosed) {
        print('[Relay] Final cleanup: closing destination stream');
        await dstStream.close().catchError((e) {
          print('[Relay] Error in final destination stream close: $e');
        });
      }
    }
    
    // Start relay (fire and forget - errors are handled within each direction)
    startRelay().catchError((e) {
      print('[Relay] Unexpected error in relay coordination: $e');
    });
  }

  /// Writes a response with the given status.
  Future<void> _writeResponse(P2PStream stream, Status status) async {
    final response = HopMessage()
      ..type = HopMessage_Type.STATUS
      ..status = status;
    
    // Write with length prefix (required for DelimitedReader on the receiving end)
    final messageBytes = response.writeToBuffer();
    final lengthBytes = encodeVarint(messageBytes.length);
    await stream.write(lengthBytes);
    await stream.write(messageBytes);
    print('[Relay] Sent HOP STATUS response: $status (${messageBytes.length} bytes)');
  }

  /// Starts the garbage collection timer.
  void _startGarbageCollection() {
    _gcTimer = Timer.periodic(Duration(minutes: 1), (_) {
      _gc();
    });
  }

  /// Garbage collects expired reservations.
  void _gc() {
    final now = DateTime.now();
    final expired = <String>[];
    for (final entry in _reservations.entries) {
      if (entry.value.isBefore(now)) {
        expired.add(entry.key);
      }
    }
    for (final key in expired) {
      _reservations.remove(key);
    }
  }

  // Test helpers
  @visibleForTesting
  void addReservationForTesting(String peerId, DateTime expiration) {
    _reservations[peerId] = expiration;
  }

  @visibleForTesting
  bool hasReservation(String peerId) {
    return _reservations.containsKey(peerId) &&
        _reservations[peerId]!.isAfter(DateTime.now());
  }

  @visibleForTesting
  int getConnectionCount(String srcPeer, String dstPeer) {
    final connKey = '$srcPeer-$dstPeer';
    return _connections[connKey] ?? 0;
  }

  @visibleForTesting
  Map<String, DateTime> get reservationsForTesting => Map.unmodifiable(_reservations);

  @visibleForTesting
  Map<String, int> get connectionsForTesting => Map.unmodifiable(_connections);
}

/// Helper function to adapt P2PStream.read() to a Dart Stream for DelimitedReader
/// Uses a StreamController to allow multiple subscriptions via await-for loops
Stream<Uint8List> _p2pStreamToDartStream(P2PStream p2pStream) {
  print('[Relay] _p2pStreamToDartStream called');
  final controller = StreamController<Uint8List>();

  Future<void> readLoop() async {
    try {
      while (true) {
        if (controller.isClosed) break;
        print('[Relay] Reading chunk from P2PStream...');
        final data = await p2pStream.read();
        print('[Relay] Read ${data.length} bytes, adding to controller...');
        controller.add(data);
      }
    } catch (e, s) {
      // Stream closed or error
      print('[Relay] Stream read error or closed: $e');
      if (!controller.isClosed) {
        controller.addError(e, s);
      }
    } finally {
      if (!controller.isClosed) {
        await controller.close();
      }
    }
  }

  // Start reading immediately
  readLoop();

  // Return as broadcast stream to allow multiple await-for loops in DelimitedReader
  return controller.stream.asBroadcastStream();
}

/// Helper class to adapt P2PStream to a Sink<List<int>> for writeDelimitedMessage
class StreamSinkFromP2PStream implements Sink<List<int>> {
  final P2PStream _stream;
  final Completer<void>? _writeCompleter;
  
  StreamSinkFromP2PStream(this._stream, [this._writeCompleter]);

  @override
  void add(List<int> data) {
    // P2PStream.write() is async, so we need to await it
    // But Sink.add() is synchronous, so we schedule it and track completion
    _stream.write(Uint8List.fromList(data)).then((_) {
      // Write completed successfully
      if (_writeCompleter != null && !_writeCompleter.isCompleted) {
        _writeCompleter.complete();
      }
    }).catchError((error) {
      // Write failed
      if (_writeCompleter != null && !_writeCompleter.isCompleted) {
        _writeCompleter.completeError(error);
      }
    });
  }

  @override
  void close() {
    // Closing the sink doesn't necessarily close the underlying P2PStream
    // as the stream's lifecycle is managed by the caller
    
    // If no writes were made and completer exists, complete it
    if (_writeCompleter != null && !_writeCompleter.isCompleted) {
      _writeCompleter.complete();
    }
  }
}