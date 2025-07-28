import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dart_libp2p/p2p/host/host.dart';
import 'package:test/test.dart';
import 'package:mockito/mockito.dart';
import 'package:mockito/annotations.dart';
import 'package:logging/logging.dart';

import 'package:dart_libp2p/core/peer/peer_id.dart';
import 'package:dart_libp2p/core/multiaddr.dart';
import 'package:dart_libp2p/core/network/context.dart';
import 'package:dart_libp2p/core/network/stream.dart';
import 'package:dart_libp2p/core/network/conn.dart';
import 'package:dart_libp2p/core/network/common.dart';
import 'package:dart_libp2p/core/peerstore.dart';
import 'package:dart_libp2p/core/network/rcmgr.dart';
import 'package:dart_libp2p/core/network/transport_conn.dart';
import 'package:dart_libp2p/p2p/network/swarm/swarm.dart';
import 'package:dart_libp2p/p2p/transport/basic_upgrader.dart';
import 'package:dart_libp2p/p2p/transport/transport.dart';
import 'package:dart_libp2p/p2p/transport/listener.dart';
import 'package:dart_libp2p/config/config.dart';
import 'package:dart_libp2p/config/stream_muxer.dart';
import 'package:dart_libp2p/core/crypto/ed25519.dart';
import 'package:dart_libp2p/core/crypto/keys.dart';
import 'package:dart_libp2p/core/certified_addr_book.dart';
import 'package:dart_libp2p/p2p/security/secured_connection.dart';

// Import enhanced mocks for Yamux connection reuse testing
import '../mocks/enhanced_yamux_transport_conn.dart';
import '../mocks/mock_security_protocol.dart';

// Import real Yamux implementation for testing
import 'package:dart_libp2p/p2p/transport/multiplexing/yamux/session.dart';
import 'package:dart_libp2p/p2p/transport/multiplexing/multiplexer.dart';
@GenerateMocks([
  ResourceManager,
  Peerstore,
  Transport,
  Listener,
  TransportConn,
  KeyBook,
  PeerMetadata,
  ConnManagementScope,
  StreamManagementScope,
  PeerScope,
  ConnScope,
])
import 'yamux_stream_swarm_reuse_test.mocks.dart';

void main() {
  // Set up logging for tests
  Logger.root.level = Level.INFO;
  Logger.root.onRecord.listen((record) {
    print('${record.level.name}: ${record.time}: ${record.message}');
  });

  group('YamuxStream Connection Re-use via Swarms', () {
    late MockResourceManager mockResourceManager;
    late MockTransport mockTransport;
    late MockListener mockListener;
    late MockConnManagementScope mockConnScope;
    late MockStreamManagementScope mockStreamScope;

    setUp(() {
      mockResourceManager = MockResourceManager();
      mockTransport = MockTransport();
      mockListener = MockListener();
      mockConnScope = MockConnManagementScope();
      mockStreamScope = MockStreamManagementScope();

      // Setup basic mock behaviors
      when(mockResourceManager.openConnection(any, any, any))
          .thenAnswer((_) async => mockConnScope);
      when(mockResourceManager.openStream(any, any))
          .thenAnswer((_) async => mockStreamScope);
      when(mockResourceManager.viewPeer<PeerScope>(any, any))
          .thenAnswer((invocation) async {
            final callback = invocation.positionalArguments[1] as Future<PeerScope> Function(PeerScope);
            final mockPeerScope = MockPeerScope();
            return await callback(mockPeerScope);
          });
      when(mockConnScope.setPeer(any)).thenAnswer((_) async {});
      when(mockConnScope.done()).thenReturn(null);
      when(mockStreamScope.done()).thenReturn(null);
      when(mockTransport.protocols).thenReturn([]);
      when(mockTransport.dispose()).thenAnswer((_) async {});
    });

    test('swarm streams reuse yamux connections correctly', () async {
      print('\n=== Starting YamuxStream Connection Re-use Test ===');
      print('Test timeout: 60 seconds');
      
      // Phase 1: Setup transport mocking first
      final listenAddr = MultiAddr('/ip4/127.0.0.1/tcp/0');
      final actualListenAddr = MultiAddr('/ip4/127.0.0.1/tcp/12345');
      
      // Configure transport for listening
      when(mockTransport.canListen(listenAddr)).thenReturn(true);
      when(mockTransport.listen(listenAddr)).thenAnswer((_) async => mockListener);
      when(mockListener.addr).thenReturn(actualListenAddr);
      when(mockListener.connectionStream).thenAnswer((_) => Stream<TransportConn>.empty());
      when(mockListener.close()).thenAnswer((_) async {});
      
      // Phase 2: Create two Swarms with shared transport
      print('Phase 1: Creating test swarms...');
      final swarmA = await createTestSwarm(name: 'SwarmA', sharedTransport: mockTransport);
      final swarmB = await createTestSwarm(name: 'SwarmB', sharedTransport: mockTransport);
      
      try {
        // Phase 3: Setup listening and peer discovery
        print('Phase 2: Setting up listening and peer discovery...');
        
        await swarmA.listen([listenAddr]);
        print('SwarmA listening on: ${swarmA.listenAddresses}');
        
        // Add swarmA's address to swarmB's peerstore for dialing
        await swarmB.peerstore.addrBook.addAddrs(
          swarmA.localPeer, 
          [actualListenAddr], 
          Duration(hours: 1)
        );
        print('Added SwarmA address to SwarmB peerstore');
        
        // Phase 3: Create multiple streams from swarmB to swarmA
        print('Phase 3: Creating multiple streams...');
        final streams = <P2PStream>[];
        final testData = <String>[];
        
        // Setup transport dialing for swarmB
        setupTransportDialing(mockTransport, swarmA.localPeer, actualListenAddr);
        
        for (int i = 0; i < 3; i++) {
          print('Creating stream $i...');
          final stream = await swarmB.newStream(Context(), swarmA.localPeer);
          streams.add(stream);
          
          // Send unique data on each stream
          final data = 'stream-$i-data-${DateTime.now().millisecondsSinceEpoch}';
          testData.add(data);
          await stream.write(utf8.encode(data));
          print('Stream $i created with ID: ${stream.id()}, sent: $data');
        }
        
        // Phase 4: Verify connection sharing
        print('Phase 4: Verifying connection sharing...');
        final connections = swarmB.connsToPeer(swarmA.localPeer);
        expect(connections.length, equals(1), 
               reason: 'All streams should share one connection');
        
        final sharedConn = connections.first;
        print('✓ All streams share connection ID: ${sharedConn.id}');
        print('✓ Connection remote peer: ${sharedConn.remotePeer}');
        print('✓ Connection is closed: ${sharedConn.isClosed}');
        
        // Phase 5: Close some streams and pause
        print('Phase 5: Closing streams and pausing...');
        await streams[0].close();
        await streams[1].close();
        print('Closed streams 0 and 1');
        
        // Verify connection is still alive after closing streams
        expect(sharedConn.isClosed, isFalse, 
               reason: 'Connection should remain alive after stream closure');
        print('✓ Connection remains alive after closing streams');
        
        // Enhanced pause with timeout protection and debugging
        print('Pausing for 3 seconds to test connection persistence...');
        print('Pre-pause state validation...');
        
        // Validate mock states before pause
        expect(sharedConn.isClosed, isFalse, reason: 'Connection should be alive before pause');
        final activeStreams = streams.where((s) => !s.isClosed).length;
        print('Active streams before pause: $activeStreams');
        
        // Yield to event loop before pause
        print('Yielding to event loop before pause...');
        await Future.microtask(() {});
        await Future.delayed(Duration(milliseconds: 10));
        
        // Enhanced pause implementation with heartbeat
        print('Starting enhanced pause with heartbeat monitoring...');
        final pauseCompleter = Completer<void>();
        late Timer pauseTimer;
        late Timer heartbeatTimer;
        
        // Set up pause timer
        pauseTimer = Timer(Duration(seconds: 3), () {
          print('Pause completed successfully after 3 seconds');
          pauseCompleter.complete();
        });
        
        // Set up heartbeat timer for progress monitoring
        int heartbeatCount = 0;
        heartbeatTimer = Timer.periodic(Duration(milliseconds: 500), (timer) {
          heartbeatCount++;
          print('Pause heartbeat ${heartbeatCount}: ${heartbeatCount * 500}ms elapsed');
          
          // Additional state validation during pause
          if (heartbeatCount % 2 == 0) {
            print('  - Connection still alive: ${!sharedConn.isClosed}');
            print('  - Active streams: ${streams.where((s) => !s.isClosed).length}');
          }
        });
        
        try {
          // Wait for pause with timeout protection
          await pauseCompleter.future.timeout(
            Duration(seconds: 5),
            onTimeout: () {
              throw TimeoutException('Pause operation timed out after 5 seconds', Duration(seconds: 5));
            },
          );
          print('✓ Pause completed successfully');
        } catch (e) {
          print('ERROR: Pause failed with exception: $e');
          rethrow;
        } finally {
          // Clean up timers
          pauseTimer.cancel();
          heartbeatTimer.cancel();
          print('Pause timers cleaned up');
        }
        
        // Post-pause event loop yield
        print('Yielding to event loop after pause...');
        await Future.microtask(() {});
        
        // Phase 6: Verify connection is still alive after pause
        print('Phase 6: Verifying connection persistence...');
        expect(sharedConn.isClosed, isFalse, 
               reason: 'Connection should remain alive after pause');
        final connectionsAfterPause = swarmB.connsToPeer(swarmA.localPeer);
        expect(connectionsAfterPause.length, equals(1), 
               reason: 'Should still have one connection after pause');
        expect(connectionsAfterPause.first.id, equals(sharedConn.id), 
               reason: 'Should be the same connection after pause');
        print('✓ Connection persisted through pause');
        
        // Phase 7: Create new streams (should reuse existing connection)
        print('Phase 7: Creating new streams to test re-use...');
        final newStreams = <P2PStream>[];
        final newTestData = <String>[];
        
        for (int i = 0; i < 2; i++) {
          print('Creating new stream $i...');
          final newStream = await swarmB.newStream(Context(), swarmA.localPeer);
          newStreams.add(newStream);
          
          // Send data to verify the reused connection works
          final data = 'reused-stream-$i-data-${DateTime.now().millisecondsSinceEpoch}';
          newTestData.add(data);
          await newStream.write(utf8.encode(data));
          print('New stream $i created with ID: ${newStream.id()}, sent: $data');
        }
        
        // Phase 8: Verify connection reuse
        print('Phase 8: Verifying connection reuse...');
        final connectionsAfter = swarmB.connsToPeer(swarmA.localPeer);
        expect(connectionsAfter.length, equals(1), 
               reason: 'Should still have only one connection');
        expect(connectionsAfter.first.id, equals(sharedConn.id), 
               reason: 'Should reuse the same connection');
        
        print('✓ Successfully reused connection ${sharedConn.id}');
        print('✓ New streams created on existing connection');
        
        // Phase 9: Verify stream isolation and data integrity
        print('Phase 9: Verifying stream isolation...');
        
        // Check that remaining original stream is still functional
        final remainingStream = streams[2];
        expect(remainingStream.isClosed, isFalse, 
               reason: 'Remaining original stream should still be open');
        
        // Send additional data on remaining stream
        final additionalData = 'additional-data-${DateTime.now().millisecondsSinceEpoch}';
        await remainingStream.write(utf8.encode(additionalData));
        print('✓ Remaining original stream still functional');
        
        // Verify all new streams are functional
        for (int i = 0; i < newStreams.length; i++) {
          final stream = newStreams[i];
          expect(stream.isClosed, isFalse, 
                 reason: 'New stream $i should be open');
          
          // Send verification data
          final verifyData = 'verify-$i-${DateTime.now().millisecondsSinceEpoch}';
          await stream.write(utf8.encode(verifyData));
          print('✓ New stream $i is functional');
        }
        
        // Phase 10: Final connection state verification
        print('Phase 10: Final verification...');
        final finalConnections = swarmB.connsToPeer(swarmA.localPeer);
        expect(finalConnections.length, equals(1), 
               reason: 'Should end with exactly one connection');
        expect(finalConnections.first.id, equals(sharedConn.id), 
               reason: 'Should be the original connection throughout');
        expect(finalConnections.first.isClosed, isFalse, 
               reason: 'Final connection should be healthy');
        
        print('✓ Connection reuse test completed successfully!');
        print('✓ Original connection ID: ${sharedConn.id}');
        print('✓ Total streams created: ${streams.length + newStreams.length}');
        print('✓ Streams closed: 2');
        print('✓ Streams remaining: ${streams.length + newStreams.length - 2}');
        print('✓ Connections used throughout test: 1');
        
      } finally {
        // Cleanup
        print('Cleaning up test resources...');
        await swarmA.close();
        await swarmB.close();
        print('Test cleanup completed');
      }
    }, timeout: Timeout(Duration(seconds: 60)));

    test('connection reuse under rapid stream cycling', () async {
      print('\n=== Starting Rapid Stream Cycling Test ===');
      
      // Setup listening
      final listenAddr = MultiAddr('/ip4/127.0.0.1/tcp/0');
      final actualListenAddr = MultiAddr('/ip4/127.0.0.1/tcp/23456');
      
      when(mockTransport.canListen(listenAddr)).thenReturn(true);
      when(mockTransport.listen(listenAddr)).thenAnswer((_) async => mockListener);
      when(mockListener.addr).thenReturn(actualListenAddr);
      when(mockListener.connectionStream).thenAnswer((_) => Stream<TransportConn>.empty());
      when(mockListener.close()).thenAnswer((_) async {});
      
      final swarmA = await createTestSwarm(name: 'CycleSwarmA', sharedTransport: mockTransport);
      final swarmB = await createTestSwarm(name: 'CycleSwarmB', sharedTransport: mockTransport);
      
      try {
        
        await swarmA.listen([listenAddr]);
        await swarmB.peerstore.addrBook.addAddrs(
          swarmA.localPeer, 
          [actualListenAddr], 
          Duration(hours: 1)
        );
        
        setupTransportDialing(mockTransport, swarmA.localPeer, actualListenAddr);
        
        // Rapid cycling test
        print('Starting rapid stream cycling...');
        String? connectionId;
        
        for (int cycle = 0; cycle < 5; cycle++) {
          print('Cycle $cycle: Creating streams...');
          final cycleStreams = <P2PStream>[];
          
          // Create multiple streams
          for (int i = 0; i < 3; i++) {
            final stream = await swarmB.newStream(Context(), swarmA.localPeer);
            cycleStreams.add(stream);
            await stream.write(utf8.encode('cycle-$cycle-stream-$i'));
          }
          await Future.delayed(Duration(milliseconds: 500));
          // Verify connection consistency
          final connections = swarmB.connsToPeer(swarmA.localPeer);
          expect(connections.length, equals(1));
          
          if (connectionId == null) {
            connectionId = connections.first.id;
            print('Established connection ID: $connectionId');
          } else {
            expect(connections.first.id, equals(connectionId),
                   reason: 'Should reuse same connection across cycles');
          }
          
          // Close all streams in this cycle
          for (final stream in cycleStreams) {
            await stream.close();
          }
          
          // Brief pause
          // await Future.delayed(Duration(milliseconds: 100));
          print('Cycle $cycle completed');
        }
        
        print('✓ Rapid cycling test completed successfully!');
        print('✓ Same connection used across all cycles: $connectionId');
        
      } finally {
        await swarmA.close();
        await swarmB.close();
      }
    });

    test('connection health during mixed stream states', () async {
      print('\n=== Starting Mixed Stream States Test ===');
      
      // Setup
      final listenAddr = MultiAddr('/ip4/127.0.0.1/tcp/0');
      final actualListenAddr = MultiAddr('/ip4/127.0.0.1/tcp/34567');
      
      when(mockTransport.canListen(listenAddr)).thenReturn(true);
      when(mockTransport.listen(listenAddr)).thenAnswer((_) async => mockListener);
      when(mockListener.addr).thenReturn(actualListenAddr);
      when(mockListener.connectionStream).thenAnswer((_) => Stream<TransportConn>.empty());
      when(mockListener.close()).thenAnswer((_) async {});
      
      final swarmA = await createTestSwarm(name: 'MixedSwarmA', sharedTransport: mockTransport);
      final swarmB = await createTestSwarm(name: 'MixedSwarmB', sharedTransport: mockTransport);
      
      try {
        
        await swarmA.listen([listenAddr]);
        await swarmB.peerstore.addrBook.addAddrs(
          swarmA.localPeer, 
          [actualListenAddr], 
          Duration(hours: 1)
        );
        
        setupTransportDialing(mockTransport, swarmA.localPeer, actualListenAddr);
        
        // Create streams with mixed lifecycle management
        print('Creating streams with mixed states...');
        final streams = <P2PStream>[];
        
        for (int i = 0; i < 5; i++) {
          final stream = await swarmB.newStream(Context(), swarmA.localPeer);
          streams.add(stream);
          await stream.write(utf8.encode('mixed-state-stream-$i'));
        }
        
        final connections = swarmB.connsToPeer(swarmA.localPeer);
        expect(connections.length, equals(1));
        final connectionId = connections.first.id;
        print('All streams using connection: $connectionId');
        
        // Close some streams, keep others open
        await streams[0].close();  // Closed
        await streams[2].close();  // Closed
        // streams[1], streams[3], streams[4] remain open
        
        print('Closed streams 0 and 2, keeping 1, 3, 4 open');
        
        // Verify connection is still healthy
        expect(connections.first.isClosed, isFalse);
        
        // Create new streams while others are still open
        final newStream1 = await swarmB.newStream(Context(), swarmA.localPeer);
        final newStream2 = await swarmB.newStream(Context(), swarmA.localPeer);
        
        await newStream1.write(utf8.encode('new-stream-1'));
        await newStream2.write(utf8.encode('new-stream-2'));
        
        // Verify still using same connection
        final connectionsAfter = swarmB.connsToPeer(swarmA.localPeer);
        expect(connectionsAfter.length, equals(1));
        expect(connectionsAfter.first.id, equals(connectionId));
        
        print('✓ Mixed stream states test completed successfully!');
        print('✓ Connection remained healthy with mixed stream states');
        print('✓ New streams successfully created alongside existing ones');
        
      } finally {
        await swarmA.close();
        await swarmB.close();
      }
    });
  });
}

/// Creates a test swarm with mocked dependencies
Future<Swarm> createTestSwarm({required String name, MockTransport? sharedTransport}) async {
  print('Creating test swarm: $name');
  
  // Generate test peer identity
  final keyPair = await generateEd25519KeyPair();
  final peerId = PeerId.fromPublicKey(keyPair.publicKey);
  print('$name PeerId: ${peerId.toString()}');
  
  // Create mock peerstore
  final mockPeerstore = MockPeerstore();
  final mockKeyBook = MockKeyBook();
  final addrBook = MemoryAddrBook();
  final mockPeerMetadata = MockPeerMetadata();
  
  // Configure peerstore mocks
  when(mockPeerstore.keyBook).thenReturn(mockKeyBook);
  when(mockPeerstore.addrBook).thenReturn(addrBook);
  when(mockPeerstore.peerMetadata).thenReturn(mockPeerMetadata);
  when(mockPeerstore.getPeer(any)).thenAnswer((_) async => null);
  when(mockKeyBook.addPrivKey(any, any)).thenAnswer((_) async {});
  when(mockKeyBook.addPubKey(any, any)).thenAnswer((_) async {});
  when(mockPeerMetadata.put(any, any, any)).thenAnswer((_) async {});
  
  // Create mock resource manager
  final mockResourceManager = MockResourceManager();
  final mockConnScope = MockConnManagementScope();
  final mockStreamScope = MockStreamManagementScope();
  final mockPeerScope = MockPeerScope();
  
  when(mockResourceManager.openConnection(any, any, any))
      .thenAnswer((_) async => mockConnScope);
  when(mockResourceManager.openStream(any, any))
      .thenAnswer((_) async => mockStreamScope);
  when(mockResourceManager.viewPeer<PeerScope>(any, any))
      .thenAnswer((invocation) async {
        final callback = invocation.positionalArguments[1] as Future<PeerScope> Function(PeerScope);
        return await callback(mockPeerScope);
      });
  when(mockConnScope.setPeer(any)).thenAnswer((_) async {});
  when(mockConnScope.done()).thenReturn(null);
  when(mockStreamScope.done()).thenReturn(null);
  
  // Use shared transport or create new one
  final mockTransport = sharedTransport ?? MockTransport();
  when(mockTransport.protocols).thenReturn([]);
  when(mockTransport.dispose()).thenAnswer((_) async {});
  
  // Create config with mock protocols
  final config = Config();
  config.peerKey = keyPair;
  
  // Add mock security protocol
  config.securityProtocols = [MockSecurityProtocol()];
  
  // Add REAL Yamux muxer instead of mock
  config.muxers = [
    StreamMuxer(
      id: '/yamux/1.0.0',
      muxerFactory: (conn, isClient) {
        // Use real YamuxSession instead of mock
        if (conn is! TransportConn) {
          throw ArgumentError(
              'YamuxSession factory requires a TransportConn, but received ${conn.runtimeType}');
        }
        return YamuxSession(
          conn,
          const MultiplexerConfig(),
          isClient,
        );
      },
    ),
  ];
  
  // Create upgrader
  final upgrader = BasicUpgrader(resourceManager: mockResourceManager);
  
  // Create and return swarm
  final swarm = Swarm(
    host: null, // Direct swarm usage
    localPeer: peerId,
    peerstore: mockPeerstore,
    resourceManager: mockResourceManager,
    upgrader: upgrader,
    config: config,
    transports: [mockTransport],
  );
  
  print('$name swarm created successfully');
  return swarm;
}

/// Sets up transport dialing mocks for connection establishment
void setupTransportDialing(MockTransport mockTransport, PeerId targetPeer, MultiAddr targetAddr) {
  // Mock transport can dial the target address
  when(mockTransport.canDial(targetAddr)).thenReturn(true);
  
  // Mock the dial operation
  when(mockTransport.dial(targetAddr)).thenAnswer((_) async {
    // Create mock scopes for the connection
    final mockConnScope1 = MockConnScope();
    final mockConnScope2 = MockConnScope();
    
    // Create a pair of enhanced Yamux connections for proper frame communication
    final localPeer = await PeerId.random(); // Will be set by swarm
    final (clientConn, serverConn) = EnhancedYamuxTransportConn.createConnectedPair(
      peer1: localPeer,
      peer2: targetPeer,
      addr1: MultiAddr('/ip4/127.0.0.1/tcp/0'),
      addr2: targetAddr,
      scope1: mockConnScope1,
      scope2: mockConnScope2,
      id1: 'yamux-client-${DateTime.now().millisecondsSinceEpoch}',
      id2: 'yamux-server-${DateTime.now().millisecondsSinceEpoch}',
      enableFrameLogging: true, // Enable logging to see Yamux frame communication
    );
    
    print('Created enhanced Yamux connection pair: ${clientConn.id} ↔ ${serverConn.id}');
    print('Client: ${clientConn.localPeer.toString().substring(0, 8)}... → ${clientConn.remotePeer.toString().substring(0, 8)}...');
    
    // Return the client side connection (the one that will be used by the dialing swarm)
    return clientConn;
  });
}
