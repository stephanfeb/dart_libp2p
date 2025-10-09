import 'dart:async';
import 'dart:typed_data';

import 'package:dart_libp2p/core/host/host.dart';
import 'package:dart_libp2p/core/multiaddr.dart';
import 'package:dart_libp2p/core/network/context.dart'; // Direct import for Context
import 'package:dart_libp2p/core/network/stream.dart';
import 'package:dart_libp2p/core/network/transport_conn.dart';
import 'package:dart_libp2p/core/peer/peer_id.dart';
import 'package:dart_libp2p/core/peer/peer_id.dart' as p2p_peer; // Imports concrete PeerId from core/peer/
import 'package:dart_libp2p/core/peerstore.dart';
import 'package:dart_libp2p/p2p/multiaddr/protocol.dart'; // For Protocols.p2p, Protocols.circuit
import 'package:dart_libp2p/p2p/transport/upgrader.dart'; // Corrected path for Upgrader
import 'package:dart_libp2p/p2p/transport/transport.dart'; // For Transport interface
import 'package:dart_libp2p/p2p/transport/transport_config.dart'; // For TransportConfig
import 'package:dart_libp2p/p2p/transport/listener.dart'; // For Listener interface
import 'package:dart_libp2p/p2p/protocol/circuitv2/pb/circuit.pb.dart' as circuit_pb;
import 'package:dart_libp2p/p2p/protocol/circuitv2/proto.dart';
import 'package:dart_libp2p/p2p/protocol/circuitv2/util/io.dart' as circuit_io;
import 'package:dart_libp2p/p2p/protocol/circuitv2/client/conn.dart';
import 'package:dart_libp2p/core/connmgr/conn_manager.dart';
import 'package:dart_libp2p/utils/varint.dart'; // For encodeVarint
import 'package:logging/logging.dart';

final _log = Logger('CircuitV2Client');

const int maxCircuitMessageSize = 4096; // Max message size for circuit protocol messages

// Helper to adapt P2PStream to a Dart Stream for DelimitedReader
Stream<List<int>> _adaptP2PStreamToDartStream(P2PStream p2pStream) {
  final controller = StreamController<List<int>>();
  
  Future<void> readLoop() async {
    try {
      while (true) { 
        if (p2pStream.isClosed || controller.isClosed) { // Check before read
             if (!controller.isClosed) await controller.close();
             break;
        }
        final data = await p2pStream.read(); 
        if (p2pStream.isClosed || controller.isClosed) { // Check after read
             if (!controller.isClosed) await controller.close();
             break;
        }
        if (data.isNotEmpty) {
          controller.add(data);
        } else if (p2pStream.isClosed) { // If read returns empty and stream is closed
            if (!controller.isClosed) await controller.close();
            break;
        }
      }
    } catch (e,s) {
      if (!controller.isClosed) {
        controller.addError(e,s);
        await controller.close();
      }
    }
  }
  
  readLoop();
  // Return as broadcast stream to allow multiple subscriptions by DelimitedReader
  return controller.stream.asBroadcastStream();
}

/// CircuitV2Client implements the Circuit Relay v2 protocol as a Transport.
/// It allows peers to establish connections through relay servers when direct
/// connections are not possible (e.g., due to NATs or firewalls).
class CircuitV2Client implements Transport {
  final Host host;
  final Upgrader upgrader;
  final ConnManager connManager;
  
  @override
  final TransportConfig config;

  // Stream controller for incoming connections that have been accepted by a listener
  final StreamController<TransportConn> _incomingConnController = StreamController.broadcast();
  StreamSubscription<P2PStream<dynamic>>? _stopHandlerSubscription;

  // Active listeners
  // For circuit relay, "listening" means being ready to accept incoming StopMessages.
  // The actual listening socket is on the relay.
  // We need a way to map incoming connections to listener instances if we support multiple listeners,
  // or a simpler model if only one "listen" setup is active.
  // For now, let's assume a single conceptual listener for incoming relayed connections.
  final List<MultiAddr> _listenAddrs = [];
  bool _isListening = false;


  CircuitV2Client({
    required this.host,
    required this.upgrader,
    required this.connManager,
    TransportConfig? config,
  }) : config = config ?? TransportConfig.defaultConfig;

  Future<void> start() async {
    // Register a handler for the STOP protocol. This is how we receive incoming connections.
    host.setStreamHandler(CircuitV2Protocol.protoIDv2Stop, _handleStreamV2);
    _log.warning('🎯 [CircuitV2Client.start] Handler registered for ${CircuitV2Protocol.protoIDv2Stop}');
    print('🎯 [CircuitV2Client.start] Handler registered for ${CircuitV2Protocol.protoIDv2Stop}');
    _log.fine('CircuitV2Client started, listening for ${CircuitV2Protocol.protoIDv2Stop}');
  }

  Future<void> stop() async {
    host.removeStreamHandler(CircuitV2Protocol.protoIDv2Stop);
    await _incomingConnController.close();
    await _stopHandlerSubscription?.cancel();
    _log.fine('CircuitV2Client stopped');
  }

  // Handles incoming streams for the STOP protocol (from relay to destination)
  // Signature updated to match StreamHandler typedef: Future<void> Function(P2PStream stream, PeerId remotePeer)
  Future<void> _handleStreamV2(P2PStream stream, PeerId remoteRelayPeerId) async {
    _log.warning('🎯 [CircuitV2Client._handleStreamV2] ENTERED! Received incoming STOP stream from relay ${remoteRelayPeerId.toString()} for stream ${stream.id()}');
    print('🎯 [CircuitV2Client._handleStreamV2] ENTERED! Stream ${stream.id()} from relay ${remoteRelayPeerId.toString()}');
    
    try {
      // Read the STOP message directly from the P2PStream without any adapters
      // This keeps the stream clean for the RelayedConn to use afterward
      print('🎯 [CircuitV2Client._handleStreamV2] Reading length-prefixed STOP message...');
      
      // Accumulate data until we have the complete message
      final buffer = <int>[];
      
      // Read first chunk to get length prefix
      var chunk = await stream.read();
      print('🎯 [CircuitV2Client._handleStreamV2] Read ${chunk.length} bytes (chunk 1)');
      
      if (chunk.isEmpty) {
        throw Exception('Empty message received from relay');
      }
      
      buffer.addAll(chunk);
      
      // Decode varint length prefix
      int messageLength = 0;
      int shift = 0;
      int bytesRead = 0;
      for (int i = 0; i < buffer.length; i++) {
        bytesRead++;
        final byte = buffer[i];
        messageLength |= (byte & 0x7F) << shift;
        if ((byte & 0x80) == 0) break; // Last byte of varint
        shift += 7;
      }
      
      print('🎯 [CircuitV2Client._handleStreamV2] Message length: $messageLength bytes (length prefix: $bytesRead bytes)');
      
      // Read more chunks until we have the complete message
      while (buffer.length < bytesRead + messageLength) {
        print('🎯 [CircuitV2Client._handleStreamV2] Need ${bytesRead + messageLength} bytes, have ${buffer.length}, reading more...');
        chunk = await stream.read();
        print('🎯 [CircuitV2Client._handleStreamV2] Read ${chunk.length} more bytes');
        if (chunk.isEmpty) {
          throw Exception('Stream closed before complete message received');
        }
        buffer.addAll(chunk);
      }
      
      print('🎯 [CircuitV2Client._handleStreamV2] Complete message received: ${buffer.length} bytes total');
      
      // Extract message bytes (skip the length prefix)
      final messageBytes = buffer.sublist(bytesRead, bytesRead + messageLength);
      
      // Parse the STOP message
      final msg = circuit_pb.StopMessage.fromBuffer(messageBytes);
      print('🎯 [CircuitV2Client._handleStreamV2] STOP message received! Type: ${msg.type}');
      // msg will not be null if readMsg completes, it throws on error/eof.
      // However, checking for safety or specific default values if applicable.
      // if (msg == null) { // This check might be redundant depending on readMsg behavior
      //   _log.warning('Failed to read StopMessage from incoming stream');
      //   await stream.reset();
      //   return;
      // }

      _log.fine('StopMessage received: type=${msg.type}, peer=${msg.hasPeer() ? msg.peer.id : 'N/A'}');

      if (msg.type != circuit_pb.StopMessage_Type.CONNECT) {
        _log.warning('Received StopMessage with unexpected type: ${msg.type}');
        await stream.reset();
        return;
      }

      _log.fine('StopMessage received: type=${msg.type}, peer=${msg.hasPeer() ? msg.peer.id : 'N/A'}');

      if (msg.type != circuit_pb.StopMessage_Type.CONNECT) {
        _log.warning('Received StopMessage with unexpected type: ${msg.type}');
        // Potentially send back a status message if the protocol defines it
        await stream.reset();
        return;
      }

      if (!msg.hasPeer()) {
        _log.warning('StopMessage_Type.CONNECT is missing peer info');
        await stream.reset();
        return;
      }

      final sourcePeerId = p2p_peer.PeerId.fromBytes(Uint8List.fromList(msg.peer.id)); // Ensure Uint8List
      // TODO: Add source peer to peerstore with its addresses from msg.peer.addrs
      // This might require converting List<Uint8List> to List<Multiaddr>
      // host.peerstore().addAddrs(sourcePeerId, sourcePeerAddrs, ttl);

      // The stream 'stream' is now the connection from the source peer, relayed via 'stream.conn.remotePeer'
      // We need to create a RelayedConn that represents this.
      // The local peer is our host's peer ID.
      // The remote peer is sourcePeerId.
      // The local multiaddr could be a /p2p-circuit address via the relay.
      // The remote multiaddr could also be a /p2p-circuit address from the source's perspective.

      // Construct the local and remote multiaddrs for the RelayedConn
      // Local: /p2p/{relayId}/p2p-circuit/p2p/{myId} (or simpler if not needed for RelayedConn)
      // Remote: /p2p/{relayId}/p2p-circuit/p2p/{sourcePeerId}
      final relayMa = stream.conn.remoteMultiaddr; // Address of the relay
      // Ensure Multiaddr.fromString is available or use appropriate constructor
      final localCircuitMa = MultiAddr('${relayMa.toString()}/p2p-circuit/p2p/${host.id.toString()}');
      final remoteCircuitMa = MultiAddr('${relayMa.toString()}/p2p-circuit/p2p/${sourcePeerId.toString()}');


      final relayedConn = RelayedConn(
        stream: stream as P2PStream<Uint8List>, // Cast needed, ensure stream is Uint8List
        transport: this,
        localPeer: host.id,
        remotePeer: sourcePeerId,
        localMultiaddr: localCircuitMa, // This represents how we are reached
        remoteMultiaddr: remoteCircuitMa, // This represents how the remote is dialed
        // isInitiator: false, // This is an incoming connection
      );

      _log.fine('Accepted incoming relayed connection from ${sourcePeerId.toString()} via ${stream.conn.remotePeer.toString()}');
      _incomingConnController.add(relayedConn);

      // Send back a STOP response with STATUS OK to the relay
      // The relay is waiting for this response to confirm we're ready to accept the connection
      print('🎯 [CircuitV2Client._handleStreamV2] Sending STOP response with status OK...');
      final stopResponse = circuit_pb.StopMessage()
        ..type = circuit_pb.StopMessage_Type.STATUS
        ..status = circuit_pb.Status.OK;
      
      // Write the response with length prefix (DelimitedReader on relay side expects it)
      final responseBytes = stopResponse.writeToBuffer();
      final responseLengthBytes = encodeVarint(responseBytes.length);
      await stream.write(responseLengthBytes);
      await stream.write(responseBytes);
      print('🎯 [CircuitV2Client._handleStreamV2] STOP response sent successfully');
      
      _log.fine('Sent STOP response with status OK to relay ${stream.conn.remotePeer.toString()}');
      
      // IMPORTANT: The stream is now owned by the RelayedConn for application data.
      // We must NOT return from this handler, as that would allow the stream to be
      // garbage collected or have its protocol handlers removed.
      // Instead, the stream will be managed by the RelayedConn which was added to
      // _incomingConnController above. The handler can now return, and the stream
      // will be kept alive by the RelayedConn.
      print('🎯 [CircuitV2Client._handleStreamV2] Handler complete, stream now managed by RelayedConn');

    } catch (e, s) {
      _log.severe('Error handling incoming STOP stream: $e\n$s');
      await stream.reset();
    }
  }


  @override
  Future<TransportConn> dial(MultiAddr addr, {Duration? timeout}) async {
    _log.info('[CircuitV2Client.dial] 🔌 Starting circuit dial to $addr');
    print('🔌 [CircuitV2Client.dial] CALLED with address: $addr');
    // 1. Parse the /p2p-circuit address.
    final addrComponents = addr.components; // Use the components getter

    String? relayIdStr;
    String? destIdStr;

    int p2pIdx = -1;
    for (int i = 0; i < addrComponents.length; i++) {
      if (addrComponents[i].$1.code == Protocols.p2p.code) {
        p2pIdx = i;
        relayIdStr = addrComponents[i].$2;
        break;
      }
    }

    if (relayIdStr == null) {
      throw ArgumentError('Dial address must contain a /p2p/relayId component: $addr');
    }
    final relayId = p2p_peer.PeerId.fromString(relayIdStr); // Use concrete PeerId.fromString

    bool connectToRelayAsDest = false;
    PeerId destId;

    int circuitIdx = -1;
    for (int i = p2pIdx + 1; i < addrComponents.length; i++) {
      if (addrComponents[i].$1.code == Protocols.circuit.code) {
        circuitIdx = i;
        break;
      }
    }

    if (circuitIdx == -1) {
      throw ArgumentError('Dial address is not a circuit address (missing /p2p-circuit): $addr');
    }

    if (circuitIdx == addrComponents.length - 1) {
      // Ends with /p2p-circuit, so destination is the relay itself
      destId = relayId;
      connectToRelayAsDest = true;
      _log.fine('Dialing relay $relayId as destination via circuit');
    } else if (circuitIdx < addrComponents.length - 1 && addrComponents[circuitIdx + 1].$1.code == Protocols.p2p.code) {
      // Has /p2p/destId after /p2p-circuit
      destIdStr = addrComponents[circuitIdx + 1].$2;
      destId = p2p_peer.PeerId.fromString(destIdStr); // Use concrete PeerId.fromString
      _log.fine('Dialing $destId via relay $relayId');
    } else {
      throw ArgumentError('Invalid circuit address format after /p2p-circuit: $addr');
    }



    // 2. Connect to the relay peer if not already connected.
    // The host should handle this when opening a new stream.
    // We might need to add the relay's address to the peerstore if we know it,
    // but typically the caller of dial should have done this or the host can discover it.

    // 3. Open a new stream to the relay using CircuitV2Protocol.protoIDv2Hop.
    // 3. Open a new stream to the relay using CircuitV2Protocol.protoIDv2Hop.
    // Host.newStream requires a Context. Creating a default one for now.
    // TODO: Consider if a more specific context is needed.
    final ctx = Context(); // Create a new Context
    _log.fine('Opening HOP stream to relay ${relayId.toString()}');
    // Correct order for newStream: peerId, protocols, context
    final hopStream = await host.newStream(relayId, [CircuitV2Protocol.protoIDv2Hop], ctx);
    _log.fine('HOP stream to relay ${relayId.toString()} opened');


    try {
      // 4. Send a HopMessage with type = CONNECT and peer set to the destination peer.
      final hopMsg = circuit_pb.HopMessage()
        ..type = circuit_pb.HopMessage_Type.CONNECT
        ..peer = (circuit_pb.Peer()
          ..id = destId.toBytes()
          // Optionally add our listen addrs for the destination to know
          // ..addAllAddrs(host.listenAddrs().map((ma) => ma.toBytes()).toList())
          );
      if (connectToRelayAsDest) {
        // If connecting to the relay itself as destination, the peer field in HopMessage
        // might be empty or refer to the relay itself. Go client sends its own AddrInfo.
        // For simplicity, let's assume destId (which is relayId here) is correct.
      }

      _log.info('[CircuitV2Client.dial] 📤 Sending HopMessage.CONNECT to relay for dest ${destId.toString()}');
      
      // Create a sink adapter to write to the P2PStream
      final writeCompleter = Completer<void>();
      final StreamController<List<int>> hopSinkController = StreamController();
      hopSinkController.stream.listen(
        (data) async {
          try {
            await hopStream.write(Uint8List.fromList(data));
          } catch (e) {
            _log.severe('[CircuitV2Client.dial] ❌ Error writing to HOP stream: $e');
            if (!writeCompleter.isCompleted) {
              writeCompleter.completeError(e);
            }
          }
        },
        onDone: () {
          if (!writeCompleter.isCompleted) {
            writeCompleter.complete();
          }
        },
        onError: (error) {
          if (!writeCompleter.isCompleted) {
            writeCompleter.completeError(error);
          }
        },
      );
      
      circuit_io.writeDelimitedMessage(hopSinkController.sink, hopMsg);
      await hopSinkController.close();
      await writeCompleter.future; // Wait for write to complete
      
      _log.info('[CircuitV2Client.dial] ✅ HopMessage.CONNECT sent successfully');


      // 5. Await a HopMessage response from the relay with type = STATUS.
      _log.info('[CircuitV2Client.dial] ⏳ Waiting for STATUS response from relay...');
      final adaptedHopStreamForReader = _adaptP2PStreamToDartStream(hopStream);
      final hopReader = circuit_io.DelimitedReader(adaptedHopStreamForReader, maxCircuitMessageSize);
      
      final statusMsg = await hopReader.readMsg(circuit_pb.HopMessage());
      _log.info('[CircuitV2Client.dial] 📨 Received HopMessage from relay: type=${statusMsg.type}, status=${statusMsg.status}');

      if (statusMsg.type != circuit_pb.HopMessage_Type.STATUS) {
        _log.severe('[CircuitV2Client.dial] ❌ Expected STATUS message from relay, got ${statusMsg.type}');
        throw Exception('Expected STATUS message from relay, got ${statusMsg.type}');
      }

      if (statusMsg.status != circuit_pb.Status.OK) {
        _log.severe('[CircuitV2Client.dial] ❌ Relay returned error status: ${statusMsg.status}');
        throw Exception('Relay returned error status: ${statusMsg.status}');
      }

      _log.info('[CircuitV2Client.dial] ✅ STATUS OK received, creating relayed connection');

      // 6. If status is OK, the stream `hopStream` is now connected to the destination peer.
      // Wrap this stream in a RelayedConn object and return it.
      final relayedConn = RelayedConn(
        stream: hopStream as P2PStream<Uint8List>, // Cast needed
        transport: this,
        localPeer: host.id,
        remotePeer: destId,
        localMultiaddr: addr, // The address we dialed
        remoteMultiaddr: addr.decapsulate(Protocols.circuit.name)!, // Decapsulate /p2p-circuit part
        // isInitiator: true, // This is derived from stream.stat().direction in RelayedConn
      );
      _log.info('[CircuitV2Client.dial] 🎉 Successfully dialed ${destId.toString()} via relay ${relayId.toString()}');
      print('🎉 [CircuitV2Client.dial] SUCCESS! Returning RelayedConn for ${destId.toString()}');
      print('   Local peer: ${relayedConn.localPeer}');
      print('   Remote peer: ${relayedConn.remotePeer}');
      print('   Local addr: ${relayedConn.localMultiaddr}');
      print('   Remote addr: ${relayedConn.remoteMultiaddr}');
      return relayedConn;

    } catch (e, s) {
      _log.severe('Error during HOP stream negotiation: $e\n$s');
      print('❌ [CircuitV2Client.dial] FAILED! Error: $e');
      await hopStream.reset(); // Ensure stream is closed on error
      rethrow;
    }
  }

  @override
  Future<Listener> listen(MultiAddr addr) async {
    // For circuit relay, the client doesn't open a traditional listening socket.
    // It relies on relays to forward connections.
    // This 'listen' method primarily means:
    // 1. Ensure the client is set up to handle incoming relayed connections (via _handleStreamV2). This is done in start().
    // 2. Store the listen address. This address tells relays "I can be reached here".
    //    It's typically like /p2p/myId or /ip4/0.0.0.0/p2p/myId/p2p-circuit (if we want to advertise specific relays)
    //    The Go code seems to manage a set of active listeners.
    //    A simple model: if listen() is called, we are "listening" on any relay that knows us.

    if (!canListen(addr)) {
      throw ArgumentError('Cannot listen on address: $addr. Must be a /p2p-circuit address or a local address.');
    }
    
    _log.fine('Client instructed to "listen" on $addr');
    // If addr is a specific circuit address like /ip4/A.B.C.D/tcp/1234/p2p/RelayID/p2p-circuit,
    // it implies we expect connections via that RelayID.
    // If addr is /ip4/0.0.0.0/tcp/0/p2p-circuit, it's more generic.

    // For now, simply add to listenAddrs and ensure handler is registered.
    // The actual "listening" is passive, waiting for _handleStreamV2.
    if (!_listenAddrs.contains(addr)) {
        _listenAddrs.add(addr);
    }
    _isListening = true; // Mark that we are in a listening state.

    return CircuitListener(this, addr, _incomingConnController.stream);
  }

  @override
  bool canDial(MultiAddr addr) {
    final addrComponents = addr.components;
    if (addrComponents.length < 2) return false;

    int p2pRelayIdx = -1;
    for (int i = 0; i < addrComponents.length; i++) {
      if (addrComponents[i].$1.code == Protocols.p2p.code) {
        p2pRelayIdx = i;
        break;
      }
    }
    if (p2pRelayIdx == -1) return false; // Must have a /p2p/relayId

    int circuitIdx = -1;
    for (int i = p2pRelayIdx + 1; i < addrComponents.length; i++) {
      if (addrComponents[i].$1.code == Protocols.circuit.code) {
        circuitIdx = i;
        break;
      }
    }
    if (circuitIdx == -1) return false; // Must have /p2p-circuit after relayId

    // Case 1: /.../p2p/relayId/.../p2p-circuit (connect to relay itself)
    if (circuitIdx == addrComponents.length - 1) return true;

    // Case 2: /.../p2p/relayId/.../p2p-circuit/p2p/destId
    if (circuitIdx < addrComponents.length - 1 && addrComponents[circuitIdx + 1].$1.code == Protocols.p2p.code) return true;

    return false;
  }

  // @override // Not part of a defined interface for now
  List<MultiAddr> listenAddrs() {
    // These are the addresses the client is "listening" on.
    // In practice, for circuit relay, these are addresses that can be advertised
    // for others to reach this client via relays.
    // It might include /p2p/{host.id}/p2p-circuit or specific relay paths.
    if (!_isListening) return [];

    // If _listenAddrs is empty but we are listening, it implies we are listening generally.
    // We could return a generic /p2p/{host.id}/p2p-circuit address.
    if (_listenAddrs.isEmpty) {
        try {
            return [MultiAddr('/p2p/${host.id.toString()}/${Protocols.circuit.name}')];
        } catch (e) {
            _log.warning('Error creating default listen address: $e');
            return []; // Should not happen if host.id is valid
        }
    }
    return List.unmodifiable(_listenAddrs);
  }

  // Helper methods for transport selection (not part of Transport interface)
  
  dynamic transportForDial(MultiAddr addr) {
    return canDial(addr) ? this : null;
  }

  dynamic transportForListen(MultiAddr addr) {
    return canListen(addr) ? this : null;
  }

  bool canListen(MultiAddr addr) {
    // A client can "listen" on an address that signifies it's reachable via relays.
    // This could be a generic /p2p-circuit address or one specifying the local peer.
    // e.g., /ip4/0.0.0.0/p2p-circuit or /p2p/MY_PEER_ID/p2p-circuit
    final addrProtocols = addr.protocols; // Use getter
    if (addrProtocols.isEmpty) return false;

    for (final p in addrProtocols) {
        if (p.code == Protocols.circuit.code) return true;
    }
    // Also allow listening on unspecified addresses if they are to be used for advertising
    // relayed reachability. E.g. /ip4/0.0.0.0/tcp/0 could imply listening via any relay.
    // For now, let's be more restrictive and require p2p-circuit.
    return false;
  }

  @override
  List<String> get protocols => ['/p2p-circuit'];

  @override
  Future<void> dispose() async {
    await stop();
  }

  // Additional helper methods (not part of Transport interface)
  
  String get protocolId => CircuitV2Protocol.protoIDv2Hop;

  Peerstore get peerstore => host.peerStore;

  Future<void> close() async {
    await stop();
  }
}

/// CircuitListener implements the Listener interface for circuit relay transport.
/// It listens for incoming relayed connections from the CircuitV2Client.
class CircuitListener implements Listener {
  final CircuitV2Client _client;
  final MultiAddr _listenAddr;
  final Stream<TransportConn> _connStream;
  StreamSubscription<TransportConn>? _subscription;
  final StreamController<TransportConn> _acceptedConnController = StreamController();
  bool _isClosed = false;

  CircuitListener(this._client, this._listenAddr, this._connStream) {
    // Filter the client's global incoming connections for this specific listener.
    // This is a simplified model. A more robust one might involve matching
    // the incoming connection's target address if available.
    // For now, any incoming relayed connection is passed to any active listener.
    _subscription = _connStream.listen(
      (conn) {
        if (!_isClosed) {
          _acceptedConnController.add(conn);
        }
      },
      onError: (err, stack) {
        if (!_isClosed) {
          _acceptedConnController.addError(err, stack);
        }
      },
      onDone: () {
        if (!_isClosed) {
          _acceptedConnController.close();
          _isClosed = true;
        }
      },
    );
  }

  @override
  MultiAddr get addr => _listenAddr;

  @override
  Future<TransportConn?> accept() async {
    if (_isClosed && _acceptedConnController.isClosed) {
      return null;
    }
    try {
      final conn = await _acceptedConnController.stream.first;
      return conn;
    } catch (e) {
      return null;
    }
  }

  @override
  bool get isClosed => _isClosed;

  @override
  Future<void> close() async {
    if (_isClosed) return;
    _isClosed = true;
    await _subscription?.cancel();
    await _acceptedConnController.close();
    _log.fine('CircuitListener for $_listenAddr closed');
  }

  @override
  Stream<TransportConn> get connectionStream => _acceptedConnController.stream;

  @override
  bool supportsAddr(MultiAddr addr) {
    // Check if the address contains /p2p-circuit
    return addr.protocols.any((p) => p.code == Protocols.circuit.code);
  }
}
