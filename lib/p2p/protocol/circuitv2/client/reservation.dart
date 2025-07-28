// Copyright (c) 2022 The dart-libp2p Authors. All rights reserved.
// Use of this source code is governed by a BSD-style
// license that can be found in the LICENSE file.

import 'dart:async';
import 'dart:typed_data';

import 'dart:async';
import 'dart:typed_data';

import 'package:dart_libp2p/core/host/host.dart' show Host; // Explicit import for Host
import 'package:dart_libp2p/core/peer/peer_id.dart';
import 'package:dart_libp2p/core/multiaddr.dart';
import 'package:dart_libp2p/core/network/context.dart';
import 'package:dart_libp2p/core/network/stream.dart' show P2PStream; // Explicit import for P2PStream
import 'package:dart_libp2p/p2p/protocol/circuitv2/client/client.dart';
import 'package:dart_libp2p/p2p/protocol/circuitv2/pb/circuit.pb.dart' as pb; // Alias for protobuf messages
import 'package:dart_libp2p/p2p/protocol/circuitv2/proto.dart';
import 'package:dart_libp2p/p2p/protocol/circuitv2/util/io.dart';
// peerInfoToPeerV2 was not found in pbconv.dart, assuming it's not needed for HopMessage or can be constructed directly.
// import 'package:dart_libp2p/p2p/protocol/circuitv2/util/pbconv.dart';
// import '../../../discovery/peer_info.dart'; // Not used directly in the new logic

// Helper function to adapt P2PStream.read() to a Dart Stream
Stream<Uint8List> _p2pStreamToDartStream(P2PStream p2pStream) {
  final controller = StreamController<Uint8List>();

  Future<void> readLoop() async {
    try {
      while (true) { // Loop indefinitely, relying on read() to throw on close/EOF
        if (controller.isClosed) break;
        // It's generally safer to let read() throw if the stream is closed.
        // Checking p2pStream.isClosed here might lead to race conditions
        // if the stream closes between the check and the read() call.
        final data = await p2pStream.read();
        // Assuming read() throws an exception (e.g., StateError or custom) when closed or EOF.
        // If read() could return an empty list to signify EOF before closing, that would need handling.
        // Based on typical stream patterns, an empty read on a still-open stream is unusual unless maxLength was 0.
        controller.add(data);
      }
    } catch (e, s) {
      // If the controller is still open, an error occurred during reading (likely EOF or stream error).
      if (!controller.isClosed) {
        controller.addError(e, s);
      }
    } finally {
      // Ensure the controller is closed when the loop exits.
      if (!controller.isClosed) {
        await controller.close();
      }
    }
  }

  controller.onListen = () {
    readLoop();
  };

  return controller.stream;
}

const Duration reserveTimeout = Duration(minutes: 1);

// Custom error class for reservation failures
class ReservationError implements Exception {
  final pb.Status status; // Ensure pb.Status is correctly imported/aliased
  final String reason;
  final Exception? cause;

  ReservationError({required this.status, required this.reason, this.cause});

  @override
  String toString() {
    return 'ReservationError: status: ${status.name}, reason: $reason${cause != null ? ', cause: $cause' : ''}';
  }
}

/// Extension methods for the CircuitV2Client class to handle reservations.
extension ReservationExtension on CircuitV2Client { // Changed from Client to CircuitV2Client
  /// Reserves a slot on a relay.
  Future<Reservation> reserve(PeerId relayPeerId) async {
    // Open a stream to the relay using Hop protocol
    // 'this.host' or simply 'host' refers to the host field of CircuitV2Client
    final stream = await host.newStream(relayPeerId, [CircuitV2Protocol.protoIDv2Hop], Context());

    // Set deadline for the entire operation, including stream opening, write, and read.
    // Dart's newStream doesn't have a per-operation deadline like Go's s.SetDeadline.
    // We'll rely on the timeout for the Future.
    return _reserveStream(stream, relayPeerId).timeout(reserveTimeout, onTimeout: () {
      stream.close(); // Ensure stream is closed on timeout
      throw ReservationError(status: pb.Status.CONNECTION_FAILED, reason: 'reservation timed out');
    });
  }

  Future<Reservation> _reserveStream(P2PStream stream, PeerId relayPeerId) async {
    // 'host' is accessible here as 'this.host' from the CircuitV2Client instance
    try {
      final writer = StreamSinkFromP2PStream(stream); // Adapt P2PStream to Sink for writeDelimitedMessage
      final reader = DelimitedReader(_p2pStreamToDartStream(stream), 4096); // maxMessageSize, similar to Go

      // Create a reserve message
      final requestMsg = pb.HopMessage()..type = pb.HopMessage_Type.RESERVE;

      // Write the message
      writeDelimitedMessage(writer, requestMsg);

      // Read the response
      final responseMsg = await reader.readMsg(pb.HopMessage());

      if (responseMsg.type != pb.HopMessage_Type.STATUS) {
        throw ReservationError(
            status: pb.Status.MALFORMED_MESSAGE,
            reason: 'unexpected relay response: not a status message (${responseMsg.type})');
      }

      if (responseMsg.status != pb.Status.OK) {
        throw ReservationError(status: responseMsg.status, reason: 'reservation failed with status ${responseMsg.status.name}');
      }

      if (!responseMsg.hasReservation()) {
        throw ReservationError(status: pb.Status.MALFORMED_MESSAGE, reason: 'missing reservation info in response');
      }

      final rsvpData = responseMsg.reservation;
      final int expireInSeconds = rsvpData.expire.toInt();
      final expiration = DateTime.fromMillisecondsSinceEpoch(expireInSeconds * 1000);

      if (expiration.isBefore(DateTime.now())) {
        throw ReservationError(
            status: pb.Status.MALFORMED_MESSAGE,
            reason: 'received reservation with expiration date in the past: $expiration');
      }

      final addrs = <MultiAddr>[];
      for (final addrBytes in rsvpData.addrs) {
        try {
          final addr = MultiAddr.fromBytes(Uint8List.fromList(addrBytes));
          addrs.add(addr);
        } catch (e) {
          // log.warn('ignoring unparsable relay address: $e'); // TODO: Add logging
        }
      }

      Uint8List? voucherBytes;
      if (rsvpData.hasVoucher()) {
        voucherBytes = Uint8List.fromList(rsvpData.voucher);
        // TODO: Implement voucher parsing and validation (record.ConsumeEnvelope equivalent)
        // For now, we store the raw voucher bytes.
      }
      
      Duration? limitDuration;
      BigInt? limitData;
      if (responseMsg.hasLimit()) {
        final limitPb = responseMsg.limit;
        if (limitPb.hasDuration()) {
          limitDuration = Duration(seconds: limitPb.duration);
        }
        if (limitPb.hasData()) {
          limitData = BigInt.from(limitPb.data.toInt());
        }
      }

      return Reservation(
        expiration,
        addrs,
        voucherBytes,
        limitDuration: limitDuration,
        limitData: limitData,
      );
    } catch (e) {
      // stream.reset(); // P2PStream might not have reset, close is more common.
      if (e is ReservationError) {
        rethrow;
      }
      throw ReservationError(status: pb.Status.CONNECTION_FAILED, reason: 'error during reservation stream handling', cause: e is Exception ? e : Exception(e.toString()));
    } finally {
      // Close the stream
      await stream.close();
    }
  }
}

/// Helper class to adapt P2PStream to a Sink<List<int>> for writeDelimitedMessage
class StreamSinkFromP2PStream implements Sink<List<int>> {
  final P2PStream _stream;
  StreamSinkFromP2PStream(this._stream);

  @override
  void add(List<int> data) {
    _stream.write(Uint8List.fromList(data)); 
    // Note: P2PStream.write is often async. If writeDelimitedMessage expects synchronous writes
    // or needs flow control, this adapter might need to be more complex (e.g., using a StreamController).
    // For now, assuming P2PStream.write handles buffering or is suitably async.
  }

  @override
  void close() {
    // Closing the sink doesn't necessarily close the underlying P2PStream here,
    // as the stream's lifecycle is managed by the reserve method.
    // If DelimitedWriter needs to signal end-of-writes, this might need to do more.
  }
}


/// Represents a reservation on a relay.
class Reservation {
  /// The expiration time of the reservation.
  final DateTime expire;

  /// The addresses of the relay.
  final List<MultiAddr> addrs;

  /// The raw reservation voucher bytes.
  final Uint8List? voucher;

  /// LimitDuration is the time limit for which the relay will keep a relayed connection open.
  /// If null or zero duration, there is no limit.
  final Duration? limitDuration;

  /// LimitData is the number of bytes that the relay will relay in each direction before
  /// resetting a relayed connection. If null, there is no limit.
  final BigInt? limitData;


  /// Creates a new reservation.
  Reservation(this.expire, this.addrs, this.voucher, {this.limitDuration, this.limitData});
}
