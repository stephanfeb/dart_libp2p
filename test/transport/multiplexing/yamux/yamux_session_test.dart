import 'dart:async';
import 'dart:typed_data';

import 'package:dart_libp2p/core/network/conn.dart' as core_conn show Conn, ConnState; // Corrected to ConnState
import 'package:dart_libp2p/core/network/context.dart' as core_context;
import 'package:dart_libp2p/core/network/transport_conn.dart';
import 'package:dart_libp2p/core/peer/peer_id.dart';
import 'package:dart_libp2p/core/multiaddr.dart';
import 'package:dart_libp2p/p2p/transport/multiplexing/multiplexer.dart';
import 'package:dart_libp2p/p2p/transport/multiplexing/yamux/session.dart';
import 'package:dart_libp2p/p2p/transport/multiplexing/yamux/stream.dart';
// import 'package:dart_libp2p/p2p/transport/multiplexing/yamux/frame.dart'; // Not strictly needed for this test
import 'package:logging/logging.dart';
import 'package:mockito/annotations.dart';
import 'package:mockito/mockito.dart';
import 'package:test/test.dart';

// Generate mocks for TransportConn
@GenerateMocks([TransportConn])
import 'yamux_session_test.mocks.dart'; // Ensure this path is correct

void main() {
  group('YamuxSession and YamuxStream Conn Integration', () {
    late MockTransportConn mockTransportConn;
    late YamuxSession clientSession;
    late MultiplexerConfig yamuxConfig;
    late PeerId clientPeerId;
    late PeerId serverPeerId;
    late MultiAddr clientMa;
    late MultiAddr serverMa;

    setUp(() async {
      // Use fixed byte arrays for PeerIds for deterministic tests
      // Using simple generation for mock purposes, real key generation is more complex
      clientPeerId = PeerId.fromBytes(Uint8List.fromList(List.generate(34, (i) => (i % 250) + 1)..[0]=0x12..[1]=0x20)) as PeerId; // Example Ed25519 PeerId bytes
      serverPeerId = PeerId.fromBytes(Uint8List.fromList(List.generate(34, (i) => (i % 250) + 2)..[0]=0x12..[1]=0x20)) as PeerId; // Example Ed25519 PeerId bytes


      clientMa = MultiAddr('/ip4/127.0.0.1/tcp/12345');
      serverMa = MultiAddr('/ip4/192.168.0.10/tcp/54321');

      mockTransportConn = MockTransportConn();
      when(mockTransportConn.localPeer).thenReturn(clientPeerId);
      when(mockTransportConn.remotePeer).thenReturn(serverPeerId);
      when(mockTransportConn.localMultiaddr).thenReturn(clientMa);
      when(mockTransportConn.remoteMultiaddr).thenReturn(serverMa);
      when(mockTransportConn.isClosed).thenReturn(false);
      when(mockTransportConn.id).thenReturn('mock-transport-conn-01');
      when(mockTransportConn.state).thenReturn(core_conn.ConnState( // Using explicit alias core_conn.ConnState
          transport: 'mock-tcp', 
          security: 'mock-noise', 
          streamMultiplexer: '', // Or a relevant mock protocol ID
          usedEarlyMuxerNegotiation: false, // Provide a default
      ));
      
      // Mock write to succeed immediately. YamuxSession.openStream will try to send a SYN frame.
      when(mockTransportConn.write(any)).thenAnswer((_) async {});

      // Mock read to simulate no immediate response, to prevent openStream from hanging if it expects one.
      final readCompleter = Completer<Uint8List>();
      // Ensure read() can be called multiple times if the session logic needs it.
      when(mockTransportConn.read(any)).thenAnswer((_) => readCompleter.future);


      yamuxConfig = MultiplexerConfig(
        keepAliveInterval: Duration(seconds: 30),
        maxStreamWindowSize: 1024 * 1024, 
        initialStreamWindowSize: 256 * 1024, 
        streamWriteTimeout: Duration(seconds: 10),
        maxStreams: 256,
        // Removed invalid parameters: acceptBacklog, enableKeepAlive, connectionWriteTimeout, logLevel, receiveWindowSize
      );

      clientSession = YamuxSession(
        mockTransportConn,
        yamuxConfig,
        true, // isClient
        // Removed Logger argument, PeerScope is optional and can be null/omitted
      );
      // No need to start the session's internal loop for this specific test.
    });

    tearDown(() async {
      // It's good practice to close the session if it has any internal resources,
      // though for this specific test, it might not be strictly necessary
      // as we are not starting its loop.
      // However, if openStream or stream.close interact with session state that needs cleanup:
      if (!clientSession.isClosed) {
         // Reset mocks for close operations if needed
        reset(mockTransportConn);
        when(mockTransportConn.isClosed).thenReturn(false); // Simulate not yet closed for session's close logic
        when(mockTransportConn.write(any)).thenAnswer((_) async {}); // For GOAWAY frame
        when(mockTransportConn.close()).thenAnswer((_) async {}); // Underlying transport close
        await clientSession.close();
      }
    });

    test('YamuxStream.conn returns its parent YamuxSession and correct connection details', () async {
      // Arrange
      // clientSession is set up. openStream will create a YamuxStream.

      // Act
      final YamuxStream yamuxStream = await clientSession.openStream(core_context.Context()) as YamuxStream;

      // Assert
      // This is the part that will fail until YamuxStream.conn is implemented correctly.
      expect(yamuxStream.conn, isA<core_conn.Conn>(), reason: "stream.conn should be a Conn object."); // Use core_conn.Conn for type check
      expect(yamuxStream.conn, same(clientSession), reason: "stream.conn should be the same instance as the parent YamuxSession.");
      
      // Verify properties accessed via stream.conn
      final connFromStream = yamuxStream.conn;
      expect(connFromStream.localPeer, same(clientPeerId), reason: "stream.conn.localPeer mismatch.");
      expect(connFromStream.remotePeer, same(serverPeerId), reason: "stream.conn.remotePeer mismatch.");
      expect(connFromStream.localMultiaddr, same(clientMa), reason: "stream.conn.localMultiaddr mismatch.");
      expect(connFromStream.remoteMultiaddr, same(serverMa), reason: "stream.conn.remoteMultiaddr mismatch.");
      expect(connFromStream.state.streamMultiplexer, equals(YamuxConstants.protocolId), reason: "stream.conn.state.streamMultiplexer mismatch.");
      // The ID of the Conn returned by stream.conn should be the ID of the YamuxSession,
      // which in turn gets its ID from the underlying transport connection.
      expect(connFromStream.id, equals('mock-transport-conn-01'), reason: "stream.conn.id should reflect underlying transport conn id via session");


      // Clean up stream
      // Closing the stream will attempt to send a FIN frame.
      // Ensure mockTransportConn.write can handle this.
      // The mock for write is already set up in setUp to accept any.
      // If stream.close() has specific interactions with session that need mock reset, do it here.
      // For now, assuming the existing mock setup for write is sufficient.
      when(mockTransportConn.isClosed).thenReturn(false); // Ensure it's not seen as already closed by stream logic
      
      await yamuxStream.close();
    });
  });
}
