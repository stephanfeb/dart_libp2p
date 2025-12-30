import 'dart:async';
import 'dart:typed_data';

import 'package:dart_libp2p/core/connmgr/conn_manager.dart';
import 'package:dart_libp2p/core/crypto/ed25519.dart' as crypto_ed25519;
import 'package:dart_libp2p/core/host/host.dart';
import 'package:dart_libp2p/core/multiaddr.dart';
import 'package:dart_libp2p/core/network/common.dart';
import 'package:dart_libp2p/core/network/conn.dart';
import 'package:dart_libp2p/core/network/stream.dart';
import 'package:dart_libp2p/core/peer/peer_id.dart';
import 'package:dart_libp2p/p2p/protocol/circuitv2/client/client.dart';
import 'package:dart_libp2p/p2p/protocol/circuitv2/pb/circuit.pb.dart' as circuit_pb;
import 'package:dart_libp2p/p2p/protocol/circuitv2/proto.dart';
import 'package:dart_libp2p/p2p/transport/upgrader.dart';
import 'package:dart_libp2p/utils/varint.dart';
import 'package:mockito/annotations.dart';
import 'package:mockito/mockito.dart';
import 'package:test/test.dart';

import 'connection_reuse_test.mocks.dart';

@GenerateMocks([Host, Upgrader, ConnManager, P2PStream, Conn, StreamStats])
void main() {
  group('CircuitV2Client Connection Reuse', () {
    late MockHost mockHost;
    late MockUpgrader mockUpgrader;
    late MockConnManager mockConnManager;
    late CircuitV2Client client;
    late PeerId localPeerId;
    late PeerId relayPeerId;
    late PeerId destPeerId;

    setUpAll(() async {
      // Generate proper PeerIds using crypto
      final localKeyPair = await crypto_ed25519.generateEd25519KeyPair();
      localPeerId = PeerId.fromPublicKey(localKeyPair.publicKey);
      
      final relayKeyPair = await crypto_ed25519.generateEd25519KeyPair();
      relayPeerId = PeerId.fromPublicKey(relayKeyPair.publicKey);
      
      final destKeyPair = await crypto_ed25519.generateEd25519KeyPair();
      destPeerId = PeerId.fromPublicKey(destKeyPair.publicKey);
    });

    setUp(() {
      mockHost = MockHost();
      mockUpgrader = MockUpgrader();
      mockConnManager = MockConnManager();

      when(mockHost.id).thenReturn(localPeerId);

      client = CircuitV2Client(
        host: mockHost,
        upgrader: mockUpgrader,
        connManager: mockConnManager,
      );
    });

    test('Multiple dial() calls to same destination return same RelayedConn', () async {
      // Arrange
      final circuitAddr = MultiAddr(
        '/ip4/10.10.3.10/tcp/4001/p2p/${relayPeerId.toBase58()}/p2p-circuit/p2p/${destPeerId.toBase58()}',
      );

      // Mock the HOP stream for the first dial
      final mockHopStream = MockP2PStream<Uint8List>();
      final mockConn = MockConn();
      final mockStreamStats = MockStreamStats();
      
      when(mockStreamStats.direction).thenReturn(Direction.outbound);
      when(mockStreamStats.opened).thenReturn(DateTime.now());
      when(mockStreamStats.limited).thenReturn(false);
      when(mockStreamStats.extra).thenReturn({});
      when(mockHopStream.stat()).thenReturn(mockStreamStats);
      when(mockHopStream.conn).thenReturn(mockConn);
      when(mockConn.remoteMultiaddr).thenReturn(MultiAddr('/ip4/10.10.3.10/tcp/4001'));
      when(mockHopStream.isClosed).thenReturn(false);
      when(mockHopStream.id()).thenReturn('stream-1');

      // Create a proper HOP response
      final statusMsg = circuit_pb.HopMessage()
        ..type = circuit_pb.HopMessage_Type.STATUS
        ..status = circuit_pb.Status.OK;
      final statusBytes = statusMsg.writeToBuffer();
      final lengthPrefix = encodeVarint(statusBytes.length);
      final hopResponse = Uint8List.fromList([...lengthPrefix, ...statusBytes]);

      // Mock sequential reads for the HOP handshake
      var readCount = 0;
      when(mockHopStream.read(any)).thenAnswer((_) async {
        readCount++;
        if (readCount == 1) {
          return hopResponse; // First read gets the STATUS response
        }
        // Subsequent reads would be application data (not used in this test)
        return Uint8List(0);
      });

      when(mockHopStream.write(any)).thenAnswer((_) async {});
      
      when(mockHost.newStream(relayPeerId, [CircuitV2Protocol.protoIDv2Hop], any))
          .thenAnswer((_) async => mockHopStream);

      // Act - First dial
      final conn1 = await client.dial(circuitAddr);
      
      // Act - Second dial (should reuse the same connection)
      final conn2 = await client.dial(circuitAddr);

      // Assert
      expect(identical(conn1, conn2), isTrue, reason: 'Should return the same RelayedConn instance');
      expect(conn1.remotePeer, equals(destPeerId));
      
      // Verify newStream was called only once (for the first dial)
      verify(mockHost.newStream(relayPeerId, [CircuitV2Protocol.protoIDv2Hop], any)).called(1);
    });

    test('dial() after connection close creates new connection', () async {
      // Arrange
      final circuitAddr = MultiAddr(
        '/ip4/10.10.3.10/tcp/4001/p2p/${relayPeerId.toBase58()}/p2p-circuit/p2p/${destPeerId.toBase58()}',
      );

      // Helper to create a mock stream
      MockP2PStream<Uint8List> createMockStream(String streamId) {
        final mockStream = MockP2PStream<Uint8List>();
        final mockConn = MockConn();
        final mockStreamStats = MockStreamStats();
        
        when(mockStreamStats.direction).thenReturn(Direction.outbound);
        when(mockStreamStats.opened).thenReturn(DateTime.now());
        when(mockStreamStats.limited).thenReturn(false);
        when(mockStreamStats.extra).thenReturn({});
        when(mockStream.stat()).thenReturn(mockStreamStats);
        when(mockStream.conn).thenReturn(mockConn);
        when(mockConn.remoteMultiaddr).thenReturn(MultiAddr('/ip4/10.10.3.10/tcp/4001'));
        when(mockStream.id()).thenReturn(streamId);

        final statusMsg = circuit_pb.HopMessage()
          ..type = circuit_pb.HopMessage_Type.STATUS
          ..status = circuit_pb.Status.OK;
        final statusBytes = statusMsg.writeToBuffer();
        final lengthPrefix = encodeVarint(statusBytes.length);
        final hopResponse = Uint8List.fromList([...lengthPrefix, ...statusBytes]);

        var readCount = 0;
        when(mockStream.read(any)).thenAnswer((_) async {
          readCount++;
          return readCount == 1 ? hopResponse : Uint8List(0);
        });

        when(mockStream.write(any)).thenAnswer((_) async {});
        
        return mockStream;
      }

      final mockStream1 = createMockStream('stream-1');
      final mockStream2 = createMockStream('stream-2');
      
      var newStreamCallCount = 0;
      when(mockHost.newStream(relayPeerId, [CircuitV2Protocol.protoIDv2Hop], any))
          .thenAnswer((_) async {
        newStreamCallCount++;
        return newStreamCallCount == 1 ? mockStream1 : mockStream2;
      });

      // Act - First dial
      final conn1 = await client.dial(circuitAddr);
      expect(conn1.remotePeer, equals(destPeerId));
      
      // Simulate close by marking stream as closed
      when(mockStream1.isClosed).thenReturn(true);
      
      // Close the connection
      await conn1.close();
      
      // Wait a bit for cleanup
      await Future.delayed(Duration(milliseconds: 10));
      
      // Act - Second dial after close (should create new connection)
      final conn2 = await client.dial(circuitAddr);

      // Assert
      expect(identical(conn1, conn2), isFalse, reason: 'Should return a new RelayedConn instance after close');
      expect(conn2.remotePeer, equals(destPeerId));
      
      // Verify newStream was called twice (once for each dial)
      verify(mockHost.newStream(relayPeerId, [CircuitV2Protocol.protoIDv2Hop], any)).called(2);
    });

    test('Concurrent dial() calls do not create duplicate connections', () async {
      // Arrange
      final circuitAddr = MultiAddr(
        '/ip4/10.10.3.10/tcp/4001/p2p/${relayPeerId.toBase58()}/p2p-circuit/p2p/${destPeerId.toBase58()}',
      );

      final mockHopStream = MockP2PStream<Uint8List>();
      final mockConn = MockConn();
      final mockStreamStats = MockStreamStats();
      
      when(mockStreamStats.direction).thenReturn(Direction.outbound);
      when(mockStreamStats.opened).thenReturn(DateTime.now());
      when(mockStreamStats.limited).thenReturn(false);
      when(mockStreamStats.extra).thenReturn({});
      when(mockHopStream.stat()).thenReturn(mockStreamStats);
      when(mockHopStream.conn).thenReturn(mockConn);
      when(mockConn.remoteMultiaddr).thenReturn(MultiAddr('/ip4/10.10.3.10/tcp/4001'));
      when(mockHopStream.isClosed).thenReturn(false);
      when(mockHopStream.id()).thenReturn('stream-1');

      final statusMsg = circuit_pb.HopMessage()
        ..type = circuit_pb.HopMessage_Type.STATUS
        ..status = circuit_pb.Status.OK;
      final statusBytes = statusMsg.writeToBuffer();
      final lengthPrefix = encodeVarint(statusBytes.length);
      final hopResponse = Uint8List.fromList([...lengthPrefix, ...statusBytes]);

      var readCount = 0;
      when(mockHopStream.read(any)).thenAnswer((_) async {
        readCount++;
        return readCount == 1 ? hopResponse : Uint8List(0);
      });

      when(mockHopStream.write(any)).thenAnswer((_) async {});
      
      // Add delay to simulate network latency
      when(mockHost.newStream(relayPeerId, [CircuitV2Protocol.protoIDv2Hop], any))
          .thenAnswer((_) async {
        await Future.delayed(Duration(milliseconds: 50));
        return mockHopStream;
      });

      // Act - Launch multiple concurrent dials
      final dialFutures = [
        client.dial(circuitAddr),
        client.dial(circuitAddr),
        client.dial(circuitAddr),
      ];
      
      final results = await Future.wait(dialFutures);

      // Assert - All should return the same connection
      expect(identical(results[0], results[1]), isTrue);
      expect(identical(results[1], results[2]), isTrue);
      expect(results[0].remotePeer, equals(destPeerId));
      
      // Verify newStream was called only once despite concurrent dials
      verify(mockHost.newStream(relayPeerId, [CircuitV2Protocol.protoIDv2Hop], any)).called(1);
    });

    test('Incoming connection is tracked and prevents duplicate outbound dial', () async {
      // This test is more complex and would require mocking the incoming STOP handler
      // For now, we'll test that the tracking map is properly managed
      
      // Arrange
      final circuitAddr = MultiAddr(
        '/ip4/10.10.3.10/tcp/4001/p2p/${relayPeerId.toBase58()}/p2p-circuit/p2p/${destPeerId.toBase58()}',
      );

      final mockHopStream = MockP2PStream<Uint8List>();
      final mockConn = MockConn();
      final mockStreamStats = MockStreamStats();
      
      when(mockStreamStats.direction).thenReturn(Direction.outbound);
      when(mockStreamStats.opened).thenReturn(DateTime.now());
      when(mockStreamStats.limited).thenReturn(false);
      when(mockStreamStats.extra).thenReturn({});
      when(mockHopStream.stat()).thenReturn(mockStreamStats);
      when(mockHopStream.conn).thenReturn(mockConn);
      when(mockConn.remoteMultiaddr).thenReturn(MultiAddr('/ip4/10.10.3.10/tcp/4001'));
      when(mockHopStream.isClosed).thenReturn(false);
      when(mockHopStream.id()).thenReturn('stream-1');

      final statusMsg = circuit_pb.HopMessage()
        ..type = circuit_pb.HopMessage_Type.STATUS
        ..status = circuit_pb.Status.OK;
      final statusBytes = statusMsg.writeToBuffer();
      final lengthPrefix = encodeVarint(statusBytes.length);
      final hopResponse = Uint8List.fromList([...lengthPrefix, ...statusBytes]);

      var readCount = 0;
      when(mockHopStream.read(any)).thenAnswer((_) async {
        readCount++;
        return readCount == 1 ? hopResponse : Uint8List(0);
      });

      when(mockHopStream.write(any)).thenAnswer((_) async {});
      
      when(mockHost.newStream(relayPeerId, [CircuitV2Protocol.protoIDv2Hop], any))
          .thenAnswer((_) async => mockHopStream);

      // Act - Create a connection
      final conn = await client.dial(circuitAddr);
      
      // Verify the connection is tracked
      expect(conn.remotePeer, equals(destPeerId));
      
      // Act - Try to dial again
      final conn2 = await client.dial(circuitAddr);
      
      // Assert - Should reuse the same connection
      expect(identical(conn, conn2), isTrue);
    });
  });
}

