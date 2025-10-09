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
      ..addrs.addAll(_host.addrs.map((addr) => addr.toBytes()))
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
    // Extract the peer info
    final srcInfo = peerToPeerInfoV2(msg.peer);
    if (srcInfo.peerId.toString().isEmpty) {
      await _writeResponse(stream, Status.MALFORMED_MESSAGE);
      return;
    }

    // Check if we have a reservation for this peer
    final reservation = _reservations[srcInfo.peerId.toString()];
    if (reservation == null || reservation.isBefore(DateTime.now())) {
      await _writeResponse(stream, Status.NO_RESERVATION);
      return;
    }

    // Extract the destination peer info
    if (!msg.hasPeer()) {
      await _writeResponse(stream, Status.MALFORMED_MESSAGE);
      return;
    }
    final dstInfo = peerToPeerInfoV2(msg.peer);
    if (dstInfo.peerId.toString().isEmpty) {
      await _writeResponse(stream, Status.MALFORMED_MESSAGE);
      return;
    }

    // Check if we have resources for a new connection
    if (!_resources.canConnect(srcInfo.peerId, dstInfo.peerId)) {
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

      // Create a stop message
      print('[Relay] Creating STOP message...');
      final stopMsg = StopMessage()
        ..type = StopMessage_Type.CONNECT
        ..peer = peerInfoToPeerV2(PeerInfo(peerId: srcInfo.peerId, addrs: <MultiAddr>[].toSet()));
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

      // Add the connection to the active connections
      final connKey = '${srcInfo.peerId}-${dstInfo.peerId}';
      _connections[connKey] = (_connections[connKey] ?? 0) + 1;

      // Relay data between the peers
      _relayData(stream, dstStream, srcInfo.peerId, dstInfo.peerId);
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
  void _relayData(
    P2PStream srcStream,
    P2PStream dstStream,
    PeerId srcPeer,
    PeerId dstPeer,
  ) {
    // Create a connection key
    final connKey = '${srcPeer}-${dstPeer}';

    // Create a function to clean up the connection
    void cleanup() async {
      await srcStream.close();
      await dstStream.close();
      final count = _connections[connKey] ?? 0;
      if (count <= 1) {
        _connections.remove(connKey);
      } else {
        _connections[connKey] = count - 1;
      }
    }

    // Relay data from source to destination
    Future<void> relaySourceToDest() async {
      try {
        while (!srcStream.isClosed && !dstStream.isClosed) {
          final data = await srcStream.read();
          if (data.isEmpty) {
            break;
          }
          await dstStream.write(data);
        }
      } catch (e) {
        print('Error relaying data from source to destination: $e');
      } finally {
        cleanup();
      }
    }

    // Relay data from destination to source
    Future<void> relayDestToSource() async {
      try {
        while (!srcStream.isClosed && !dstStream.isClosed) {
          final data = await dstStream.read();
          if (data.isEmpty) {
            break;
          }
          await srcStream.write(data);
        }
      } catch (e) {
        print('Error relaying data from destination to source: $e');
      } finally {
        cleanup();
      }
    }

    // Start both relay tasks
    relaySourceToDest();
    relayDestToSource();
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