// Copyright (c) 2022 The dart-libp2p Authors. All rights reserved.
// Use of this source code is governed by a BSD-style
// license that can be found in the LICENSE file.

import 'dart:async';
import 'dart:typed_data';

import 'package:dart_libp2p/core/peer/peer_id.dart';
import 'package:dart_libp2p/p2p/host/host.dart';
import 'package:dart_libp2p/p2p/protocol/circuitv2/pb/circuit.pb.dart';
import 'package:dart_libp2p/p2p/protocol/circuitv2/proto.dart';
import 'package:dart_libp2p/p2p/protocol/circuitv2/relay/resources.dart';
import 'package:dart_libp2p/p2p/protocol/circuitv2/util/io.dart';
import 'package:dart_libp2p/p2p/protocol/circuitv2/util/pbconv.dart';
import 'package:dart_libp2p/p2p/protocol/circuitv2/voucher.dart';
import 'package:logging/logging.dart';
import 'package:fixnum/fixnum.dart';

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
      // Read the message
      final msg = await stream.read();
      if (msg == null) {
        throw Exception('unexpected EOF');
      }

      final pb = HopMessage.fromBuffer(msg);

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
    // Extract the peer info
    final peerInfo = peerToPeerInfoV2(msg.peer);
    if (peerInfo.peerId.toString().isEmpty) {
      await _writeResponse(stream, Status.MALFORMED_MESSAGE);
      return;
    }

    // Check if we have resources for a new reservation
    if (!_resources.canReserve(peerInfo.peerId)) {
      await _writeResponse(stream, Status.RESOURCE_LIMIT_EXCEEDED);
      return;
    }

    // Create a reservation
    final expire = DateTime.now().add(Duration(seconds: _resources.reservationTtl));
    _reservations[peerInfo.peerId.toString()] = expire;

    // Create a reservation voucher
    final voucher = ReservationVoucherData(
      relay: _host.id,
      peer: peerInfo.peerId,
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

    // Write the response
    final response = HopMessage()
      ..type = HopMessage_Type.STATUS
      ..status = Status.OK
      ..reservation = reservation
      ..limit = limit;
    await stream.write(response.writeToBuffer());
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
      // Open a stream to the destination peer
      final dstStream = await _host.newStream(dstInfo.peerId, [CircuitV2Protocol.protoIDv2Stop], Context());

      // Create a stop message
      final stopMsg = StopMessage()
        ..type = StopMessage_Type.CONNECT
        ..peer = peerInfoToPeerV2(PeerInfo(peerId: srcInfo.peerId, addrs: <MultiAddr>[].toSet()));

      // Write the message
      await dstStream.write(stopMsg.writeToBuffer());

      // Read the response
      final stopResponse = await dstStream.read();
      if (stopResponse == null) {
        throw Exception('unexpected EOF');
      }
      final pb = StopMessage.fromBuffer(stopResponse);

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
    await stream.write(response.writeToBuffer());
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
}