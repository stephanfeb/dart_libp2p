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

// Import mocks for Yamux connection reuse testing
import '../mocks/streamlined_mock_transport_conn.dart';
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
    // Create a streamlined mock connection that handles protocol negotiation
    final localPeer = await PeerId.random(); // Will be set by swarm
    final clientConn = StreamlinedMockTransportConn(
      id: 'mock-client-${DateTime.now().millisecondsSinceEpoch}',
      localAddr: MultiAddr('/ip4/127.0.0.1/tcp/0'),
      remoteAddr: targetAddr,
      localPeer: localPeer,
      remotePeer: targetPeer,
    );
    
    print('Created mock transport connection: ${clientConn.id}');
    print('Client: ${clientConn.localPeer.toString().substring(0, 8)}... → ${clientConn.remotePeer.toString().substring(0, 8)}...');
    
    // Return the client side connection (the one that will be used by the dialing swarm)
    return clientConn;
  });
}
