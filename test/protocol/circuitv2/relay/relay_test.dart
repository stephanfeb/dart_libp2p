import 'dart:async';
import 'dart:typed_data';

import 'package:dart_libp2p/core/crypto/ed25519.dart';
import 'package:test/test.dart';
import 'package:mockito/mockito.dart';
import 'package:mockito/annotations.dart';

import 'package:dart_libp2p/core/host/host.dart';
import 'package:dart_libp2p/core/peer/peer_id.dart';
import 'package:dart_libp2p/core/network/stream.dart';
import 'package:dart_libp2p/core/network/conn.dart';
import 'package:dart_libp2p/core/multiaddr.dart';
import 'package:dart_libp2p/p2p/protocol/circuitv2/relay/relay.dart';
import 'package:dart_libp2p/p2p/protocol/circuitv2/relay/resources.dart';
import 'package:dart_libp2p/p2p/protocol/circuitv2/proto.dart';

@GenerateMocks([Host, Conn])
@GenerateNiceMocks([MockSpec<P2PStream>()])
import 'relay_test.mocks.dart';

void main() {
  group('Relay Server', () {
    late MockHost mockHost;
    late Resources resources;
    late Relay relay;
    late PeerId testHostPeerId;

    setUp(() async {
      mockHost = MockHost();
      resources = Resources(
        maxReservations: 10,
        maxConnections: 10,
        reservationTtl: 3600,
        connectionDuration: 120,
        connectionData: 1024 * 1024,
      );
      
      // Create a real PeerId for the host
      final keyPair = await generateEd25519KeyPair();
      testHostPeerId = PeerId.fromPublicKey(keyPair.publicKey);
      
      // Mock basic host properties
      when(mockHost.id).thenReturn(testHostPeerId);
      when(mockHost.addrs).thenReturn([]);
      
      relay = Relay(mockHost, resources);
    });

    group('Reservation Management', () {
      test('should accept valid reservation requests', () {
        // Arrange
        final peerId = 'test-peer-123';
        final expiration = DateTime.now().add(Duration(hours: 1));
        
        // Act
        relay.addReservationForTesting(peerId, expiration);
        
        // Assert
        expect(relay.hasReservation(peerId), isTrue);
        expect(relay.reservationsForTesting, contains(peerId));
      });

      test('should reject expired reservations', () {
        // Arrange
        final peerId = 'test-peer-123';
        final expiration = DateTime.now().subtract(Duration(hours: 1));
        
        // Act
        relay.addReservationForTesting(peerId, expiration);
        
        // Assert
        expect(relay.hasReservation(peerId), isFalse);
      });

      test('should handle multiple reservations', () {
        // Arrange
        final peer1 = 'peer-1';
        final peer2 = 'peer-2';
        final expiration = DateTime.now().add(Duration(hours: 1));
        
        // Act
        relay.addReservationForTesting(peer1, expiration);
        relay.addReservationForTesting(peer2, expiration);
        
        // Assert
        expect(relay.hasReservation(peer1), isTrue);
        expect(relay.hasReservation(peer2), isTrue);
        expect(relay.reservationsForTesting.length, equals(2));
      });
    });

    group('Connection Tracking', () {
      test('should track active connections', () {
        // This test verifies connection counting indirectly
        // The connection count is managed internally by _relayData
        
        final srcPeer = 'src-peer';
        final dstPeer = 'dst-peer';
        
        // Initially no connections
        expect(relay.getConnectionCount(srcPeer, dstPeer), equals(0));
      });

      test('should provide immutable view of connections', () {
        // Arrange & Act
        final connections = relay.connectionsForTesting;
        
        // Assert
        expect(connections, isA<Map<String, int>>());
        expect(() => connections['test'] = 1, throwsUnsupportedError);
      });
    });

    group('Bidirectional Data Forwarding', () {
      test('should relay data from source to destination', () async {
        // Arrange
        final srcKeyPair = await generateEd25519KeyPair();
        final dstKeyPair = await generateEd25519KeyPair();
        final srcPeer = PeerId.fromPublicKey(srcKeyPair.publicKey);
        final dstPeer = PeerId.fromPublicKey(dstKeyPair.publicKey);
        
        final srcStream = MockP2PStream();
        final dstStream = MockP2PStream();
        
        // Track reads: first return data, then return empty to signal EOF
        var srcReadCount = 0;
        final testData = Uint8List.fromList([1, 2, 3, 4, 5]);
        when(srcStream.read()).thenAnswer((_) async {
          if (srcReadCount == 0) {
            srcReadCount++;
            return testData;
          }
          return Uint8List(0); // EOF
        });
        
        // Track destination writes
        final dstWrites = <Uint8List>[];
        when(dstStream.write(any)).thenAnswer((invocation) async {
          final data = invocation.positionalArguments[0] as Uint8List;
          dstWrites.add(data);
        });
        
        // Destination reads return empty immediately (no reverse data)
        when(dstStream.read()).thenAnswer((_) async => Uint8List(0));
        
        // Mock close behavior
        when(srcStream.close()).thenAnswer((_) async {});
        when(dstStream.close()).thenAnswer((_) async {});
        
        // Act: Start relay
        relay.relayDataForTesting(srcStream, dstStream, srcPeer, dstPeer);
        
        // Wait for data to be relayed and cleanup
        await Future.delayed(Duration(milliseconds: 200));
        
        // Assert: Data was forwarded to destination
        expect(dstWrites, isNotEmpty);
        expect(dstWrites.first, equals(testData));
        
        // Verify streams were closed
        verify(srcStream.close()).called(greaterThanOrEqualTo(1));
        verify(dstStream.close()).called(greaterThanOrEqualTo(1));
      });

      test('should relay data from destination to source', () async {
        // Arrange
        final srcKeyPair = await generateEd25519KeyPair();
        final dstKeyPair = await generateEd25519KeyPair();
        final srcPeer = PeerId.fromPublicKey(srcKeyPair.publicKey);
        final dstPeer = PeerId.fromPublicKey(dstKeyPair.publicKey);
        
        final srcStream = MockP2PStream();
        final dstStream = MockP2PStream();
        
        // Source reads return empty immediately (no forward data)
        when(srcStream.read()).thenAnswer((_) async => Uint8List(0));
        
        // Track source writes
        final srcWrites = <Uint8List>[];
        when(srcStream.write(any)).thenAnswer((invocation) async {
          final data = invocation.positionalArguments[0] as Uint8List;
          srcWrites.add(data);
        });
        
        // Track destination reads: first return data, then return empty
        var dstReadCount = 0;
        final testData = Uint8List.fromList([5, 4, 3, 2, 1]);
        when(dstStream.read()).thenAnswer((_) async {
          if (dstReadCount == 0) {
            dstReadCount++;
            return testData;
          }
          return Uint8List(0); // EOF
        });
        
        // Mock close behavior
        when(srcStream.close()).thenAnswer((_) async {});
        when(dstStream.close()).thenAnswer((_) async {});
        
        // Act: Start relay
        relay.relayDataForTesting(srcStream, dstStream, srcPeer, dstPeer);
        
        // Wait for data to be relayed and cleanup
        await Future.delayed(Duration(milliseconds: 200));
        
        // Assert: Data was forwarded to source
        expect(srcWrites, isNotEmpty);
        expect(srcWrites.first, equals(testData));
        
        // Verify streams were closed
        verify(srcStream.close()).called(greaterThanOrEqualTo(1));
        verify(dstStream.close()).called(greaterThanOrEqualTo(1));
      });

      test('should handle stream errors gracefully', () async {
        // Arrange
        final srcKeyPair = await generateEd25519KeyPair();
        final dstKeyPair = await generateEd25519KeyPair();
        final srcPeer = PeerId.fromPublicKey(srcKeyPair.publicKey);
        final dstPeer = PeerId.fromPublicKey(dstKeyPair.publicKey);
        
        final srcStream = MockP2PStream();
        final dstStream = MockP2PStream();
        
        // Mock source stream to throw error
        when(srcStream.read()).thenThrow(Exception('Stream error'));
        when(dstStream.read()).thenAnswer((_) async => Uint8List(0));
        
        // Mock close behavior
        when(srcStream.close()).thenAnswer((_) async {});
        when(dstStream.close()).thenAnswer((_) async {});
        
        // Act: Start relay (should not throw)
        expect(() => relay.relayDataForTesting(srcStream, dstStream, srcPeer, dstPeer),
               returnsNormally);
        
        // Wait for error handling
        await Future.delayed(Duration(milliseconds: 200));
        
        // Assert: Cleanup should have occurred
        verify(srcStream.close()).called(greaterThanOrEqualTo(1));
        verify(dstStream.close()).called(greaterThanOrEqualTo(1));
      });
    });

    group('Lifecycle', () {
      test('should start and register HOP protocol handler', () {
        // Act
        relay.start();
        
        // Assert
        verify(mockHost.setStreamHandler(CircuitV2Protocol.protoIDv2Hop, any))
            .called(1);
      });

      test('should stop and remove protocol handler', () async {
        // Arrange
        relay.start();
        
        // Act
        await relay.close();
        
        // Assert
        verify(mockHost.removeStreamHandler(CircuitV2Protocol.protoIDv2Hop))
            .called(1);
      });

      test('should handle multiple close calls gracefully', () async {
        // Arrange
        relay.start();
        
        // Act & Assert: Multiple closes should not throw
        await relay.close();
        await relay.close();
        
        verify(mockHost.removeStreamHandler(any)).called(1);
      });
    });
  });
}

