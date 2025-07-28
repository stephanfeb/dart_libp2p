import 'dart:async';
import 'dart:typed_data';

import 'package:dart_libp2p/core/crypto/ed25519.dart' as crypto_ed25519;
import 'package:dart_libp2p/core/crypto/keys.dart';
import 'package:dart_libp2p/core/multiaddr.dart';
import 'package:dart_libp2p/core/network/conn.dart';
import 'package:dart_libp2p/core/network/context.dart' as core_context;
import 'package:dart_libp2p/core/network/mux.dart' as core_mux_types;
import 'package:dart_libp2p/core/network/rcmgr.dart';
import 'package:dart_libp2p/core/network/transport_conn.dart';
import 'package:dart_libp2p/core/peer/peer_id.dart';
import 'package:dart_libp2p/p2p/host/eventbus/basic.dart';
import 'package:dart_libp2p/config/config.dart' as p2p_config;
import 'package:dart_libp2p/p2p/network/connmgr/null_conn_mgr.dart';
import 'package:dart_libp2p/p2p/security/noise/noise_protocol.dart';
import 'package:dart_libp2p/p2p/transport/basic_upgrader.dart';
import 'package:dart_libp2p/p2p/transport/listener.dart';
import 'package:dart_libp2p/p2p/transport/multiplexing/yamux/session.dart';
import 'package:dart_libp2p/p2p/transport/multiplexing/yamux/stream.dart';
import 'package:dart_libp2p/p2p/transport/multiplexing/multiplexer.dart';
import 'package:dart_libp2p/config/stream_muxer.dart';
import 'package:dart_libp2p/p2p/transport/udx_transport.dart';
import 'package:dart_udx/dart_udx.dart';
import 'package:logging/logging.dart';
import 'package:test/test.dart';
import 'package:dart_libp2p/p2p/transport/connection_manager.dart' as p2p_transport;
import 'package:dart_libp2p/p2p/host/resource_manager/resource_manager_impl.dart';
import 'package:dart_libp2p/p2p/host/resource_manager/limiter.dart';
import 'package:dart_libp2p/p2p/network/swarm/swarm.dart';
import 'package:dart_libp2p/p2p/host/basic/basic_host.dart';
import 'package:dart_libp2p/p2p/host/peerstore/pstoremem/peerstore.dart';
import 'package:dart_libp2p/core/peer/addr_info.dart';
import 'package:dart_libp2p/core/network/stream.dart' as core_network_stream;
import 'package:dart_libp2p/p2p/multiaddr/protocol.dart' as multiaddr_protocol;
import 'package:dart_libp2p/core/peerstore.dart';
import 'package:dart_libp2p/core/network/network.dart';
import 'package:dart_libp2p/core/network/notifiee.dart';

// Custom AddrsFactory for testing that doesn't filter loopback
List<MultiAddr> passThroughAddrsFactory(List<MultiAddr> addrs) {
  return addrs;
}

// Helper class for providing YamuxMuxer to the config
class _TestYamuxMuxerProvider extends StreamMuxer {
  final MultiplexerConfig yamuxConfig;

  _TestYamuxMuxerProvider({required this.yamuxConfig})
      : super(
          id: '/yamux/1.0.0',
          muxerFactory: (Conn secureConn, bool isClient) {
            if (secureConn is! TransportConn) {
              throw ArgumentError(
                  'YamuxMuxer factory expects a TransportConn, got ${secureConn.runtimeType}');
            }
            return YamuxSession(secureConn, yamuxConfig, isClient);
          },
        );
}

// Helper Notifiee for tests
class TestNotifiee implements Notifiee {
  final Function(Network, Conn)? connectedCallback;
  final Function(Network, Conn)? disconnectedCallback;
  final Function(Network, MultiAddr)? listenCallback;
  final Function(Network, MultiAddr)? listenCloseCallback;

  TestNotifiee({
    this.connectedCallback,
    this.disconnectedCallback,
    this.listenCallback,
    this.listenCloseCallback,
  });

  @override
  Future<void> connected(Network network, Conn conn) async {
    connectedCallback?.call(network, conn);
  }

  @override
  Future<void> disconnected(Network network, Conn conn) async {
    disconnectedCallback?.call(network, conn);
  }

  @override
  void listen(Network network, MultiAddr addr) {
    listenCallback?.call(network, addr);
  }

  @override
  void listenClose(Network network, MultiAddr addr) {
    listenCloseCallback?.call(network, addr);
  }
}

void main() {
  // Setup comprehensive logging to capture all layer interactions
  Logger.root.level = Level.ALL;
  Logger.root.onRecord.listen((record) {
    final timestamp = record.time.toIso8601String().substring(11, 23);
    print('[$timestamp] ${record.level.name}: ${record.loggerName}: ${record.message}');
    if (record.error != null) {
      print('  ERROR: ${record.error}');
    }
    if (record.stackTrace != null && record.level.value >= Level.SEVERE.value) {
      print('  STACKTRACE: ${record.stackTrace}');
    }
  });

  group('Yamux-UDX Integration Test Suite', () {
    late UDX udxInstance;
    late PeerId clientPeerId;
    late PeerId serverPeerId;
    late KeyPair clientKeyPair;
    late KeyPair serverKeyPair;

    setUpAll(() async {
      print('\n🔧 Setting up integration test suite...');
      udxInstance = UDX();

      clientKeyPair = await crypto_ed25519.generateEd25519KeyPair();
      serverKeyPair = await crypto_ed25519.generateEd25519KeyPair();
      clientPeerId = await PeerId.fromPublicKey(clientKeyPair.publicKey);
      serverPeerId = await PeerId.fromPublicKey(serverKeyPair.publicKey);

      print('✅ Test suite setup complete');
      print('   Client PeerID: ${clientPeerId.toString()}');
      print('   Server PeerID: ${serverPeerId.toString()}');
    });

    tearDownAll(() async {
      print('\n🧹 Cleaning up test suite...');
      // UDX instance cleanup is handled by individual tests
      print('✅ Test suite cleanup complete');
    });

    group('Layer 1: Yamux over Real UDX Transport', () {
      test('should handle large payloads (100KB) over real UDX without Noise/Swarm', () async {
        print('\n🧪 TEST 1: Yamux + UDX (no Noise, no Swarm)');
        print('   Goal: Isolate if the issue is in UDX transport vs mock connections');
        
        late UDXTransport clientTransport;
        late UDXTransport serverTransport;
        late Listener listener;
        late TransportConn clientRawConn;
        late TransportConn serverRawConn;
        late YamuxSession clientSession;
        late YamuxSession serverSession;
        late YamuxStream clientStream;
        late YamuxStream serverStream;

        try {
          // Setup UDX transports
          final connManager = NullConnMgr();
          clientTransport = UDXTransport(connManager: connManager, udxInstance: udxInstance);
          serverTransport = UDXTransport(connManager: connManager, udxInstance: udxInstance);

          // Setup listener
          final initialListenAddr = MultiAddr('/ip4/127.0.0.1/udp/0/udx');
          listener = await serverTransport.listen(initialListenAddr);
          final actualListenAddr = listener.addr;
          print('   Server listening on: $actualListenAddr');

          // Establish raw UDX connections
          final serverAcceptFuture = listener.accept().then((conn) {
            if (conn == null) throw Exception("Listener accepted null connection");
            serverRawConn = conn;
            print('   Server accepted raw UDX connection: ${serverRawConn.id}');
            return serverRawConn;
          });

          final clientDialFuture = clientTransport.dial(actualListenAddr).then((conn) {
            clientRawConn = conn;
            print('   Client dialed raw UDX connection: ${clientRawConn.id}');
            return clientRawConn;
          });

          await Future.wait([clientDialFuture, serverAcceptFuture]);

          // Create Yamux sessions directly over UDX (no security layer)
          final yamuxConfig = MultiplexerConfig(
            keepAliveInterval: Duration(seconds: 30),
            maxStreamWindowSize: 1024 * 1024,
            initialStreamWindowSize: 256 * 1024,
            streamWriteTimeout: Duration(seconds: 10),
            maxStreams: 256,
          );

          print('   Creating Yamux sessions over raw UDX...');
          clientSession = YamuxSession(clientRawConn, yamuxConfig, true);
          serverSession = YamuxSession(serverRawConn, yamuxConfig, false);

          // Wait for sessions to initialize
          await Future.delayed(Duration(milliseconds: 500));
          expect(clientSession.isClosed, isFalse, reason: 'Client session should be open');
          expect(serverSession.isClosed, isFalse, reason: 'Server session should be open');
          print('   ✅ Yamux sessions established');

          // Setup stream handling
          final serverStreamCompleter = Completer<YamuxStream>();
          serverSession.setStreamHandler((stream) async {
            serverStream = stream as YamuxStream;
            print('   Server accepted Yamux stream: ${serverStream.id()}');
            if (!serverStreamCompleter.isCompleted) {
              serverStreamCompleter.complete(serverStream);
            }
          });

          // Open client stream
          clientStream = await clientSession.openStream(core_context.Context()) as YamuxStream;
          print('   Client opened Yamux stream: ${clientStream.id()}');

          // Wait for server to accept stream
          await serverStreamCompleter.future;
          expect(clientStream, isNotNull);
          expect(serverStream, isNotNull);
          print('   ✅ Yamux streams established');

          // Test large payload transfer (100KB - same size that fails in OBP test)
          print('   🚀 Starting large payload test (100KB)...');
          await _testLargePayloadTransfer(
            clientStream, 
            serverStream, 
            'Layer1-UDX-Only',
            expectSuccess: true, // We expect this to work since Yamux mock tests pass
          );

          print('   ✅ Layer 1 test PASSED - UDX transport works with large payloads');

        } catch (e, stackTrace) {
          print('   ❌ Layer 1 test FAILED: $e');
          print('   Stack trace: $stackTrace');
          
          // Provide diagnostic information
          print('\n   🔍 Diagnostic Information:');
          if (clientSession != null) print('   - Client session closed: ${clientSession.isClosed}');
          if (serverSession != null) print('   - Server session closed: ${serverSession.isClosed}');
          if (clientStream != null) print('   - Client stream closed: ${clientStream.isClosed}');
          if (serverStream != null) print('   - Server stream closed: ${serverStream.isClosed}');
          
          rethrow;
        } finally {
          // Cleanup
          print('   🧹 Cleaning up Layer 1 test...');
          try {
            if (clientStream != null && !clientStream.isClosed) {
              await clientStream.close().timeout(Duration(seconds: 2));
            }
            if (serverStream != null && !serverStream.isClosed) {
              await serverStream.close().timeout(Duration(seconds: 2));
            }
            if (clientSession != null && !clientSession.isClosed) {
              await clientSession.close().timeout(Duration(seconds: 2));
            }
            if (serverSession != null && !serverSession.isClosed) {
              await serverSession.close().timeout(Duration(seconds: 2));
            }
            if (listener != null && !listener.isClosed) {
              await listener.close();
            }
            await clientTransport.dispose();
            await serverTransport.dispose();
          } catch (e) {
            print('   ⚠️ Error during Layer 1 cleanup: $e');
          }
          print('   ✅ Layer 1 cleanup complete');
        }
      }, timeout: Timeout(Duration(seconds: 60)));
    });

    group('Layer 2: Yamux over UDX + Noise Security', () {
      test('should handle large payloads (100KB) over UDX + Noise without Swarm', () async {
        print('\n🧪 TEST 2: Yamux + UDX + Noise (no Swarm)');
        print('   Goal: Determine if Noise security layer causes the issue');
        
        late UDXTransport clientTransport;
        late UDXTransport serverTransport;
        late BasicUpgrader clientUpgrader;
        late BasicUpgrader serverUpgrader;
        late p2p_config.Config clientP2PConfig;
        late p2p_config.Config serverP2PConfig;
        late Listener listener;
        late TransportConn clientRawConn;
        late TransportConn serverRawConn;
        late Conn clientUpgradedConn;
        late Conn serverUpgradedConn;
        late YamuxStream clientStream;
        late YamuxStream serverStream;

        try {
          // Setup components
          final resourceManager = NullResourceManager();
          final connManager = NullConnMgr();

          clientTransport = UDXTransport(connManager: connManager, udxInstance: udxInstance);
          serverTransport = UDXTransport(connManager: connManager, udxInstance: udxInstance);

          clientUpgrader = BasicUpgrader(resourceManager: resourceManager);
          serverUpgrader = BasicUpgrader(resourceManager: resourceManager);

          // Setup security protocols
          final securityProtocolsClient = [await NoiseSecurity.create(clientKeyPair)];
          final securityProtocolsServer = [await NoiseSecurity.create(serverKeyPair)];
          
          // Setup Yamux multiplexer
          final yamuxMultiplexerConfig = MultiplexerConfig(
            keepAliveInterval: Duration(seconds: 30),
            maxStreamWindowSize: 1024 * 1024,
            initialStreamWindowSize: 256 * 1024,
            streamWriteTimeout: Duration(seconds: 10),
            maxStreams: 256,
          );
          final muxerDefs = [_TestYamuxMuxerProvider(yamuxConfig: yamuxMultiplexerConfig)];

          clientP2PConfig = p2p_config.Config()
            ..peerKey = clientKeyPair
            ..securityProtocols = securityProtocolsClient
            ..muxers = muxerDefs;

          serverP2PConfig = p2p_config.Config()
            ..peerKey = serverKeyPair
            ..securityProtocols = securityProtocolsServer
            ..muxers = muxerDefs;

          // Setup listener
          final initialListenAddr = MultiAddr('/ip4/127.0.0.1/udp/0/udx');
          listener = await serverTransport.listen(initialListenAddr);
          final actualListenAddr = listener.addr;
          print('   Server listening on: $actualListenAddr');

          // Establish raw UDX connections
          final serverAcceptFuture = listener.accept().then((conn) {
            if (conn == null) throw Exception("Listener accepted null connection");
            serverRawConn = conn;
            print('   Server accepted raw UDX connection: ${serverRawConn.id}');
            return serverRawConn;
          });

          final clientDialFuture = clientTransport.dial(actualListenAddr).then((conn) {
            clientRawConn = conn;
            print('   Client dialed raw UDX connection: ${clientRawConn.id}');
            return clientRawConn;
          });

          await Future.wait([clientDialFuture, serverAcceptFuture]);

          // Upgrade connections with Noise + Yamux
          print('   🔐 Upgrading connections with Noise + Yamux...');
          final clientUpgradedFuture = clientUpgrader.upgradeOutbound(
            connection: clientRawConn,
            remotePeerId: serverPeerId,
            config: clientP2PConfig,
            remoteAddr: actualListenAddr,
          );
          final serverUpgradedFuture = serverUpgrader.upgradeInbound(
            connection: serverRawConn,
            config: serverP2PConfig,
          );

          final List<Conn> upgradedConns = await Future.wait([clientUpgradedFuture, serverUpgradedFuture]);
          clientUpgradedConn = upgradedConns[0];
          serverUpgradedConn = upgradedConns[1];

          // Verify upgrade
          expect(clientUpgradedConn.remotePeer.toString(), serverPeerId.toString());
          expect(serverUpgradedConn.remotePeer.toString(), clientPeerId.toString());
          expect(clientUpgradedConn.state.security, contains('noise'));
          expect(serverUpgradedConn.state.security, contains('noise'));
          expect(clientUpgradedConn.state.streamMultiplexer, contains('yamux'));
          expect(serverUpgradedConn.state.streamMultiplexer, contains('yamux'));
          print('   ✅ Connections upgraded with Noise + Yamux');

          // Setup stream handling
          final serverStreamCompleter = Completer<YamuxStream>();
          final serverAcceptStreamFuture = (serverUpgradedConn as core_mux_types.MuxedConn).acceptStream().then((stream) { 
            serverStream = stream as YamuxStream;
            print('   Server accepted Yamux stream: ${serverStream.id()}');
            return serverStream;
          });

          await Future.delayed(Duration(milliseconds: 100));

          // Open client stream
          clientStream = await (clientUpgradedConn as core_mux_types.MuxedConn).openStream(core_context.Context()) as YamuxStream;
          print('   Client opened Yamux stream: ${clientStream.id()}');
          
          await serverAcceptStreamFuture;
          expect(clientStream, isNotNull);
          expect(serverStream, isNotNull);
          print('   ✅ Yamux streams established over Noise');

          // Test large payload transfer
          print('   🚀 Starting large payload test (100KB) over Noise...');
          await _testLargePayloadTransfer(
            clientStream, 
            serverStream, 
            'Layer2-UDX-Noise',
            expectSuccess: null, // We don't know if this will work - this is what we're testing
          );

          print('   ✅ Layer 2 test PASSED - UDX + Noise works with large payloads');

        } catch (e, stackTrace) {
          print('   ❌ Layer 2 test FAILED: $e');
          print('   Stack trace: $stackTrace');
          
          // Provide diagnostic information
          print('\n   🔍 Diagnostic Information:');
          if (clientUpgradedConn != null) print('   - Client upgraded conn closed: ${clientUpgradedConn.isClosed}');
          if (serverUpgradedConn != null) print('   - Server upgraded conn closed: ${serverUpgradedConn.isClosed}');
          if (clientStream != null) print('   - Client stream closed: ${clientStream.isClosed}');
          if (serverStream != null) print('   - Server stream closed: ${serverStream.isClosed}');
          
          print('   🔍 This suggests the issue is introduced by the Noise security layer');
          rethrow;
        } finally {
          // Cleanup
          print('   🧹 Cleaning up Layer 2 test...');
          try {
            if (clientStream != null && !clientStream.isClosed) {
              await clientStream.close().timeout(Duration(seconds: 2));
            }
            if (serverStream != null && !serverStream.isClosed) {
              await serverStream.close().timeout(Duration(seconds: 2));
            }
            if (clientUpgradedConn != null && !clientUpgradedConn.isClosed) {
              await clientUpgradedConn.close().timeout(Duration(seconds: 2));
            }
            if (serverUpgradedConn != null && !serverUpgradedConn.isClosed) {
              await serverUpgradedConn.close().timeout(Duration(seconds: 2));
            }
            if (listener != null && !listener.isClosed) {
              await listener.close();
            }
            await clientTransport.dispose();
            await serverTransport.dispose();
          } catch (e) {
            print('   ⚠️ Error during Layer 2 cleanup: $e');
          }
          print('   ✅ Layer 2 cleanup complete');
        }
      }, timeout: Timeout(Duration(seconds: 60)));
    });

    group('Layer 3: Yamux over UDX + Noise + BasicHost (Simple Protocol)', () {
      test('should handle large payloads (100KB) over UDX + Noise + BasicHost with simple echo protocol', () async {
        print('\n🧪 TEST 3: Yamux + UDX + Noise + BasicHost (Simple Echo Protocol)');
        print('   Goal: Test the full stack with a simple protocol to verify integration');
        
        BasicHost? clientHost;
        BasicHost? serverHost;
        MultiAddr? serverListenAddr;
        core_network_stream.P2PStream? clientStream;

        try {
          // Setup components exactly like the working OBP test
          final resourceManager = ResourceManagerImpl(limiter: FixedLimiter());
          final connManager = p2p_transport.ConnectionManager();
          final eventBus = BasicBus();

          // Setup security and multiplexing
          final yamuxMultiplexerConfig = MultiplexerConfig(
            keepAliveInterval: Duration(seconds: 30),
            maxStreamWindowSize: 1024 * 1024,
            initialStreamWindowSize: 256 * 1024,
            streamWriteTimeout: Duration(seconds: 10),
            maxStreams: 256,
          );
          final muxerDefs = [_TestYamuxMuxerProvider(yamuxConfig: yamuxMultiplexerConfig)];

          final clientSecurity = [await NoiseSecurity.create(clientKeyPair)];
          final serverSecurity = [await NoiseSecurity.create(serverKeyPair)];

          // Setup configs exactly like working test
          final clientP2PConfig = p2p_config.Config()
            ..peerKey = clientKeyPair
            ..securityProtocols = clientSecurity
            ..muxers = muxerDefs
            ..connManager = connManager
            ..eventBus = eventBus;

          final serverP2PConfig = p2p_config.Config()
            ..peerKey = serverKeyPair
            ..securityProtocols = serverSecurity
            ..muxers = muxerDefs
            ..addrsFactory = passThroughAddrsFactory;
          
          final initialListenAddr = MultiAddr('/ip4/127.0.0.1/udp/0/udx');
          serverP2PConfig.listenAddrs = [initialListenAddr];
          serverP2PConfig.connManager = connManager;
          serverP2PConfig.eventBus = eventBus;

          // Setup transports
          final clientUdxTransport = UDXTransport(connManager: connManager, udxInstance: udxInstance);
          final serverUdxTransport = UDXTransport(connManager: connManager, udxInstance: udxInstance);
          
          // Setup peerstores
          final clientPeerstore = MemoryPeerstore();
          final serverPeerstore = MemoryPeerstore();

          // Create Swarms and BasicHosts exactly like working test
          final clientSwarm = Swarm(
            host: null,
            localPeer: clientPeerId,
            peerstore: clientPeerstore,
            resourceManager: resourceManager,
            upgrader: BasicUpgrader(resourceManager: resourceManager),
            config: clientP2PConfig,
            transports: [clientUdxTransport],
          );
          clientHost = await BasicHost.create(network: clientSwarm, config: clientP2PConfig);
          clientSwarm.setHost(clientHost);
          await clientHost.start();

          final serverSwarm = Swarm(
            host: null,
            localPeer: serverPeerId,
            peerstore: serverPeerstore,
            resourceManager: resourceManager,
            upgrader: BasicUpgrader(resourceManager: resourceManager),
            config: serverP2PConfig,
            transports: [serverUdxTransport],
          );
          serverHost = await BasicHost.create(network: serverSwarm, config: serverP2PConfig);
          serverSwarm.setHost(serverHost);

          // Setup server stream handler for simple echo protocol
          const echoProtocolId = '/test/echo/1.0.0';
          final serverStreamCompleter = Completer<core_network_stream.P2PStream>();
          
          serverHost.setStreamHandler(echoProtocolId, (core_network_stream.P2PStream stream, PeerId peerId) async {
            print('   Server Host received echo stream: ${stream.id()} from ${peerId}');
            if (!serverStreamCompleter.isCompleted) {
              serverStreamCompleter.complete(stream);
            }
            
            // Simple echo handler - read data and echo it back
            try {
              while (!stream.isClosed) {
                final data = await stream.read().timeout(Duration(seconds: 10));
                if (data.isEmpty) break;
                
                print('   Server echoing ${data.length} bytes');
                await stream.write(data);
              }
            } catch (e) {
              print('   Server echo handler error: $e');
            }
          });

          await serverSwarm.listen(serverP2PConfig.listenAddrs);
          await serverHost.start();

          expect(serverHost.addrs.isNotEmpty, isTrue);
          serverListenAddr = serverHost.addrs.firstWhere((addr) => addr.hasProtocol(multiaddr_protocol.Protocols.udx.name));
          print('   Server Host listening on: $serverListenAddr');

          // Add server peer info to client exactly like working test
          clientHost.peerStore.addrBook.addAddrs(
            serverPeerId,
            [serverListenAddr],
            AddressTTL.permanentAddrTTL,
          );
          clientHost.peerStore.keyBook.addPubKey(serverPeerId, serverKeyPair.publicKey);

          // Connect and open stream via BasicHost exactly like working test
          print('   🔗 Connecting via BasicHost...');
          final serverAddrInfo = AddrInfo(serverPeerId, [serverListenAddr]);
          await clientHost.connect(serverAddrInfo);
          print('   Client Host connected to server');

          clientStream = await clientHost.newStream(serverPeerId, [echoProtocolId], core_context.Context());
          print('   Client Host opened stream: ${clientStream.id()}');

          final serverStream = await serverStreamCompleter.future;
          print('   Server Host accepted stream: ${serverStream.id()}');

          // Test large payload transfer with echo protocol
          print('   🚀 Starting large payload test (100KB) over BasicHost...');
          await _testLargePayloadEcho(
            clientStream, 
            serverStream, 
            'Layer3-BasicHost-Echo',
          );

          print('   ✅ Layer 3 test PASSED - UDX + Noise + BasicHost works with large payloads');

        } catch (e, stackTrace) {
          print('   ❌ Layer 3 test FAILED: $e');
          print('   Stack trace: $stackTrace');
          
          // Provide diagnostic information
          print('\n   🔍 Diagnostic Information:');
          if (clientStream != null) print('   - Client stream closed: ${clientStream.isClosed}');
          
          print('   🔍 This suggests the issue is in the BasicHost layer or above');
          rethrow;
        } finally {
          // Cleanup
          print('   🧹 Cleaning up Layer 3 test...');
          try {
            if (clientStream != null && !clientStream.isClosed) {
              await clientStream.close().timeout(Duration(seconds: 2));
            }
            if (clientHost != null) {
              await clientHost.close().timeout(Duration(seconds: 5));
            }
            if (serverHost != null) {
              await serverHost.close().timeout(Duration(seconds: 5));
            }
          } catch (e) {
            print('   ⚠️ Error during Layer 3 cleanup: $e');
          }
          print('   ✅ Layer 3 cleanup complete');
        }
      }, timeout: Timeout(Duration(seconds: 60)));
    });


  });
}

// Helper function to test large payload transfer over Yamux streams
Future<void> _testLargePayloadTransfer(
  YamuxStream clientStream,
  YamuxStream serverStream,
  String testContext,
  {bool? expectSuccess}
) async {
  print('   📊 [$testContext] Creating 100KB test data...');
  
  // Create 100KB test data - same size that causes OBP test to fail
  final largeData = Uint8List(100 * 1024);
  for (var i = 0; i < largeData.length; i++) {
    largeData[i] = i % 256;
  }
  print('   📊 [$testContext] Test data created: ${largeData.length} bytes');

  // Simulate the rapid chunk delivery pattern from UDX (1384-byte chunks)
  const chunkSize = 1384; // Exact size from the OBP failure logs
  final chunks = <Uint8List>[];
  for (var i = 0; i < largeData.length; i += chunkSize) {
    final end = (i + chunkSize > largeData.length) ? largeData.length : i + chunkSize;
    chunks.add(largeData.sublist(i, end));
  }
  print('   📊 [$testContext] Created ${chunks.length} chunks of ${chunkSize} bytes each');

  // Track session health throughout the test
  var sessionHealthChecks = 0;
  void checkSessionHealth(String phase) {
    sessionHealthChecks++;
    print('   🏥 [$testContext][$phase] Health check #$sessionHealthChecks:');
    print('      - Client stream closed: ${clientStream.isClosed}');
    print('      - Server stream closed: ${serverStream.isClosed}');
    
    if (clientStream.isClosed || serverStream.isClosed) {
      throw StateError('Stream closed during $phase - this indicates the Yamux GO_AWAY issue');
    }
  }

  checkSessionHealth('Initial');

  print('   🚀 [$testContext] Starting rapid write operations (no delays between chunks)...');
  final writeCompleter = Completer<void>();
  var chunksWritten = 0;
  
  // Send all chunks rapidly without delays (simulating UDX behavior)
  Future.microtask(() async {
    try {
      for (final chunk in chunks) {
        await clientStream.write(chunk);
        chunksWritten++;
        
        // Check session health every 10 chunks
        if (chunksWritten % 10 == 0) {
          checkSessionHealth('Write chunk $chunksWritten/${chunks.length}');
        }
      }
      print('   ✅ [$testContext] All chunks written successfully');
      writeCompleter.complete();
    } catch (e) {
      print('   ❌ [$testContext] Write operation failed: $e');
      writeCompleter.completeError(e);
    }
  });

  print('   📥 [$testContext] Reading data and monitoring session health...');
  final receivedData = <int>[];
  var readOperations = 0;
  
  while (receivedData.length < largeData.length) {
    try {
      final chunk = await serverStream.read().timeout(Duration(seconds: 10));
      if (chunk.isEmpty) {
        print('   ⚠️ [$testContext] Received empty chunk, stream might be closed');
        break;
      }
      
      receivedData.addAll(chunk);
      readOperations++;
      
      // Check session health every 10 read operations
      if (readOperations % 10 == 0) {
        checkSessionHealth('Read operation $readOperations');
        final progress = (receivedData.length * 100 ~/ largeData.length);
        print('   📈 [$testContext] Progress: ${receivedData.length}/${largeData.length} bytes (${progress}%)');
      }
      
    } catch (e) {
      print('   ❌ [$testContext] Read operation failed: $e');
      checkSessionHealth('Read failure');
      rethrow;
    }
  }

  print('   ⏳ [$testContext] Waiting for write operations to complete...');
  await writeCompleter.future.timeout(Duration(seconds: 30));
  
  checkSessionHealth('After write completion');

  print('   🔍 [$testContext] Verifying data integrity...');
  expect(
    Uint8List.fromList(receivedData),
    equals(largeData),
    reason: 'Received data should match sent data',
  );
  print('   ✅ [$testContext] Data integrity verified');

  // Final session health check
  checkSessionHealth('Final');
  
  print('   ✅ [$testContext] Large payload transfer completed successfully');
}

// Helper function to test large payload transfer with echo protocol over P2P streams
Future<void> _testLargePayloadEcho(
  core_network_stream.P2PStream clientStream,
  core_network_stream.P2PStream serverStream,
  String testContext,
) async {
  print('   📊 [$testContext] Creating 100KB test data...');
  
  // Create 100KB test data - same size that causes OBP test to fail
  final largeData = Uint8List(100 * 1024);
  for (var i = 0; i < largeData.length; i++) {
    largeData[i] = i % 256;
  }
  print('   📊 [$testContext] Test data created: ${largeData.length} bytes');

  // Simulate the rapid chunk delivery pattern from UDX (1384-byte chunks)
  const chunkSize = 1384; // Exact size from the OBP failure logs
  final chunks = <Uint8List>[];
  for (var i = 0; i < largeData.length; i += chunkSize) {
    final end = (i + chunkSize > largeData.length) ? largeData.length : i + chunkSize;
    chunks.add(largeData.sublist(i, end));
  }
  print('   📊 [$testContext] Created ${chunks.length} chunks of ${chunkSize} bytes each');

  // Track stream health throughout the test
  var healthChecks = 0;
  void checkStreamHealth(String phase) {
    healthChecks++;
    print('   🏥 [$testContext][$phase] Health check #$healthChecks:');
    print('      - Client stream closed: ${clientStream.isClosed}');
    print('      - Server stream closed: ${serverStream.isClosed}');
    
    if (clientStream.isClosed || serverStream.isClosed) {
      throw StateError('Stream closed during $phase - this indicates the integration issue');
    }
  }

  checkStreamHealth('Initial');

  print('   🚀 [$testContext] Starting echo test with large payload...');
  
  // Send data and receive echo back (simulating echo protocol)
  final writeCompleter = Completer<void>();
  final receivedData = <int>[];
  var chunksWritten = 0;
  var chunksReceived = 0;
  
  // Start reading echoed data
  Future.microtask(() async {
    try {
      while (receivedData.length < largeData.length) {
        final chunk = await clientStream.read().timeout(Duration(seconds: 10));
        if (chunk.isEmpty) {
          print('   ⚠️ [$testContext] Received empty chunk, stream might be closed');
          break;
        }
        
        receivedData.addAll(chunk);
        chunksReceived++;
        
        // Check stream health every 10 chunks
        if (chunksReceived % 10 == 0) {
          checkStreamHealth('Read echo chunk $chunksReceived');
          final progress = (receivedData.length * 100 ~/ largeData.length);
          print('   📈 [$testContext] Echo progress: ${receivedData.length}/${largeData.length} bytes (${progress}%)');
        }
      }
    } catch (e) {
      print('   ❌ [$testContext] Echo read operation failed: $e');
      checkStreamHealth('Echo read failure');
      rethrow;
    }
  });

  // Send all chunks rapidly without delays (simulating UDX behavior)
  Future.microtask(() async {
    try {
      for (final chunk in chunks) {
        await clientStream.write(chunk);
        chunksWritten++;
        
        // Check stream health every 10 chunks
        if (chunksWritten % 10 == 0) {
          checkStreamHealth('Write chunk $chunksWritten/${chunks.length}');
        }
        
        // Small delay to allow echo processing
        if (chunksWritten % 5 == 0) {
          await Future.delayed(Duration(milliseconds: 1));
        }
      }
      print('   ✅ [$testContext] All chunks written successfully');
      writeCompleter.complete();
    } catch (e) {
      print('   ❌ [$testContext] Write operation failed: $e');
      writeCompleter.completeError(e);
    }
  });

  print('   ⏳ [$testContext] Waiting for write operations to complete...');
  await writeCompleter.future.timeout(Duration(seconds: 30));
  
  // Wait for all echo data to be received
  var waitCount = 0;
  while (receivedData.length < largeData.length && waitCount < 100) {
    await Future.delayed(Duration(milliseconds: 100));
    waitCount++;
    if (waitCount % 10 == 0) {
      print('   ⏳ [$testContext] Waiting for echo completion: ${receivedData.length}/${largeData.length} bytes');
    }
  }
  
  checkStreamHealth('After echo completion');

  print('   🔍 [$testContext] Verifying echo data integrity...');
  expect(
    Uint8List.fromList(receivedData),
    equals(largeData),
    reason: 'Echoed data should match sent data',
  );
  print('   ✅ [$testContext] Echo data integrity verified');

  // Final stream health check
  checkStreamHealth('Final');
  
  print('   ✅ [$testContext] Large payload echo test completed successfully');
}

// Helper function to test large payload transfer over P2P streams
Future<void> _testLargePayloadTransferP2P(
  core_network_stream.P2PStream clientStream,
  core_network_stream.P2PStream serverStream,
  String testContext,
  {bool? expectSuccess}
) async {
  print('   📊 [$testContext] Creating 100KB test data...');
  
  // Create 100KB test data - same size that causes OBP test to fail
  final largeData = Uint8List(100 * 1024);
  for (var i = 0; i < largeData.length; i++) {
    largeData[i] = i % 256;
  }
  print('   📊 [$testContext] Test data created: ${largeData.length} bytes');

  // Simulate the rapid chunk delivery pattern from UDX (1384-byte chunks)
  const chunkSize = 1384; // Exact size from the OBP failure logs
  final chunks = <Uint8List>[];
  for (var i = 0; i < largeData.length; i += chunkSize) {
    final end = (i + chunkSize > largeData.length) ? largeData.length : i + chunkSize;
    chunks.add(largeData.sublist(i, end));
  }
  print('   📊 [$testContext] Created ${chunks.length} chunks of ${chunkSize} bytes each');

  // Track stream health throughout the test
  var healthChecks = 0;
  void checkStreamHealth(String phase) {
    healthChecks++;
    print('   🏥 [$testContext][$phase] Health check #$healthChecks:');
    print('      - Client stream closed: ${clientStream.isClosed}');
    print('      - Server stream closed: ${serverStream.isClosed}');
    
    if (clientStream.isClosed || serverStream.isClosed) {
      throw StateError('Stream closed during $phase - this indicates the integration issue');
    }
  }

  checkStreamHealth('Initial');

  print('   🚀 [$testContext] Starting rapid write operations (no delays between chunks)...');
  final writeCompleter = Completer<void>();
  var chunksWritten = 0;
  
  // Send all chunks rapidly without delays (simulating UDX behavior)
  Future.microtask(() async {
    try {
      for (final chunk in chunks) {
        await clientStream.write(chunk);
        chunksWritten++;
        
        // Check stream health every 10 chunks
        if (chunksWritten % 10 == 0) {
          checkStreamHealth('Write chunk $chunksWritten/${chunks.length}');
        }
      }
      print('   ✅ [$testContext] All chunks written successfully');
      writeCompleter.complete();
    } catch (e) {
      print('   ❌ [$testContext] Write operation failed: $e');
      writeCompleter.completeError(e);
    }
  });

  print('   📥 [$testContext] Reading data and monitoring stream health...');
  final receivedData = <int>[];
  var readOperations = 0;
  
  while (receivedData.length < largeData.length) {
    try {
      final chunk = await serverStream.read().timeout(Duration(seconds: 10));
      if (chunk.isEmpty) {
        print('   ⚠️ [$testContext] Received empty chunk, stream might be closed');
        break;
      }
      
      receivedData.addAll(chunk);
      readOperations++;
      
      // Check stream health every 10 read operations
      if (readOperations % 10 == 0) {
        checkStreamHealth('Read operation $readOperations');
        final progress = (receivedData.length * 100 ~/ largeData.length);
        print('   📈 [$testContext] Progress: ${receivedData.length}/${largeData.length} bytes (${progress}%)');
      }
      
    } catch (e) {
      print('   ❌ [$testContext] Read operation failed: $e');
      checkStreamHealth('Read failure');
      rethrow;
    }
  }

  print('   ⏳ [$testContext] Waiting for write operations to complete...');
  await writeCompleter.future.timeout(Duration(seconds: 30));
  
  checkStreamHealth('After write completion');

  print('   🔍 [$testContext] Verifying data integrity...');
  expect(
    Uint8List.fromList(receivedData),
    equals(largeData),
    reason: 'Received data should match sent data',
  );
  print('   ✅ [$testContext] Data integrity verified');

  // Final stream health check
  checkStreamHealth('Final');
  
  print('   ✅ [$testContext] Large payload transfer completed successfully');
}
