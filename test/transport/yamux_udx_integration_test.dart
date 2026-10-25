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
  Future<void> connected(Network network, Conn conn, {Duration? dialLatency}) async {
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
  Logger.root.level = Level.FINE;
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

          // Manually set peer IDs on raw connections (normally done during security handshake)
          // This is needed because Yamux requires peer IDs to be set
          print('   Setting up peer IDs on raw connections...');
          (clientRawConn as dynamic).setRemotePeerDetails(serverPeerId, serverKeyPair.publicKey, 'test-no-security');
          (serverRawConn as dynamic).setRemotePeerDetails(clientPeerId, clientKeyPair.publicKey, 'test-no-security');
          print('   ✅ Peer IDs configured');

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
          print('   - Client session closed: ${clientSession.isClosed}');
          print('   - Server session closed: ${serverSession.isClosed}');
          print('   - Client stream closed: ${clientStream.isClosed}');
          print('   - Server stream closed: ${serverStream.isClosed}');
          
          rethrow;
        } finally {
          // Cleanup
          print('   🧹 Cleaning up Layer 1 test...');
          try {
            if (!clientStream.isClosed) {
              await clientStream.close().timeout(Duration(seconds: 2));
            }
            if (!serverStream.isClosed) {
              await serverStream.close().timeout(Duration(seconds: 2));
            }
            if (!clientSession.isClosed) {
              await clientSession.close().timeout(Duration(seconds: 2));
            }
            if (!serverSession.isClosed) {
              await serverSession.close().timeout(Duration(seconds: 2));
            }
            if (!listener.isClosed) {
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
          print('   - Client upgraded conn closed: ${clientUpgradedConn.isClosed}');
          print('   - Server upgraded conn closed: ${serverUpgradedConn.isClosed}');
          print('   - Client stream closed: ${clientStream.isClosed}');
          print('   - Server stream closed: ${serverStream.isClosed}');
          
          print('   🔍 This suggests the issue is introduced by the Noise security layer');
          rethrow;
        } finally {
          // Cleanup
          print('   🧹 Cleaning up Layer 2 test...');
          try {
            if (!clientStream.isClosed) {
              await clientStream.close().timeout(Duration(seconds: 2));
            }
            if (!serverStream.isClosed) {
              await serverStream.close().timeout(Duration(seconds: 2));
            }
            if (!clientUpgradedConn.isClosed) {
              await clientUpgradedConn.close().timeout(Duration(seconds: 2));
            }
            if (!serverUpgradedConn.isClosed) {
              await serverUpgradedConn.close().timeout(Duration(seconds: 2));
            }
            if (!listener.isClosed) {
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
      test('should handle large payloads (100KB) over UDX + Noise + BasicHost with one-way transfer', () async {
        print('\n🧪 TEST 3: Yamux + UDX + Noise + BasicHost (One-Way Transfer)');
        print('   Goal: Test the full stack with a simple one-way transfer protocol');
        
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

          // Setup server stream handler for simple receive protocol
          const transferProtocolId = '/test/transfer/1.0.0';
          final serverStreamCompleter = Completer<core_network_stream.P2PStream>();
          final serverReceivedData = <int>[];
          
          serverHost.setStreamHandler(transferProtocolId, (core_network_stream.P2PStream stream, PeerId peerId) async {
            print('   Server Host received transfer stream: ${stream.id()} from ${peerId}');
            if (!serverStreamCompleter.isCompleted) {
              serverStreamCompleter.complete(stream);
            }
            
            // Simple receive handler - just read all data
            try {
              var totalReceived = 0;
              while (!stream.isClosed) {
                final data = await stream.read().timeout(Duration(seconds: 30));
                if (data.isEmpty) {
                  print('   Server received EOF after $totalReceived bytes');
                  break;
                }
                
                serverReceivedData.addAll(data);
                totalReceived += data.length;
                if (totalReceived % 10000 < data.length) {
                  print('   Server received ${data.length} bytes (total: $totalReceived)');
                }
              }
              print('   Server receive handler completed (total: $totalReceived bytes)');
            } catch (e) {
              print('   Server receive handler error: $e');
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

          clientStream = await clientHost.newStream(serverPeerId, [transferProtocolId], core_context.Context());
          print('   Client Host opened stream: ${clientStream.id()}');

          final serverStream = await serverStreamCompleter.future;
          print('   Server Host accepted stream: ${serverStream.id()}');

          // Test large payload one-way transfer
          print('   🚀 Starting large payload test (100KB) over BasicHost...');
          
          // Create 100KB test data
          final largeData = Uint8List(100 * 1024);
          for (var i = 0; i < largeData.length; i++) {
            largeData[i] = i % 256;
          }
          print('   📤 Client sending ${largeData.length} bytes...');
          
          // Send data in chunks
          const chunkSize = 8192;
          for (var i = 0; i < largeData.length; i += chunkSize) {
            final end = (i + chunkSize > largeData.length) ? largeData.length : i + chunkSize;
            await clientStream.write(largeData.sublist(i, end));
            
            if ((i + chunkSize) % 25000 < chunkSize) {
              print('   📤 Client sent ${i + chunkSize}/${largeData.length} bytes');
            }
          }
          print('   ✅ Client finished sending all data');
          
          // Close write side to signal EOF
          await clientStream.closeWrite();
          print('   🔒 Client closed write side');
          
          // Wait for server to receive all data
          var waitCount = 0;
          while (serverReceivedData.length < largeData.length && waitCount < 100) {
            await Future.delayed(Duration(milliseconds: 100));
            waitCount++;
            if (waitCount % 10 == 0) {
              print('   ⏳ Waiting for server to receive all data: ${serverReceivedData.length}/${largeData.length} bytes');
            }
          }
          
          // Verify data integrity
          print('   🔍 Verifying data integrity...');
          expect(
            Uint8List.fromList(serverReceivedData),
            equals(largeData),
            reason: 'Server should receive all data correctly',
          );
          print('   ✅ Data integrity verified');

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

    group('FIN Handling: closeWrite() Half-Close Semantics', () {
      test('should allow reading all data after sender calls closeWrite()', () async {
        print('\n🧪 TEST FIN-1: closeWrite() should not break pending reads');
        print('   Goal: Verify that closeWrite() allows receiver to read all buffered data');
        
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
            return serverRawConn;
          });

          final clientDialFuture = clientTransport.dial(actualListenAddr).then((conn) {
            clientRawConn = conn;
            return clientRawConn;
          });

          await Future.wait([clientDialFuture, serverAcceptFuture]);

          // Manually set peer IDs on raw connections (normally done during security handshake)
          print('   Setting up peer IDs on raw connections...');
          (clientRawConn as dynamic).setRemotePeerDetails(serverPeerId, serverKeyPair.publicKey, 'test-no-security');
          (serverRawConn as dynamic).setRemotePeerDetails(clientPeerId, clientKeyPair.publicKey, 'test-no-security');

          // Create Yamux sessions
          final yamuxConfig = MultiplexerConfig(
            keepAliveInterval: Duration(seconds: 30),
            maxStreamWindowSize: 1024 * 1024,
            initialStreamWindowSize: 256 * 1024,
            streamWriteTimeout: Duration(seconds: 10),
            maxStreams: 256,
          );

          clientSession = YamuxSession(clientRawConn, yamuxConfig, true);
          serverSession = YamuxSession(serverRawConn, yamuxConfig, false);
          await Future.delayed(Duration(milliseconds: 200));

          // Setup stream handling
          final serverStreamCompleter = Completer<YamuxStream>();
          serverSession.setStreamHandler((stream) async {
            serverStream = stream as YamuxStream;
            if (!serverStreamCompleter.isCompleted) {
              serverStreamCompleter.complete(serverStream);
            }
          });

          // Open client stream
          clientStream = await clientSession.openStream(core_context.Context()) as YamuxStream;
          await serverStreamCompleter.future;
          print('   ✅ Streams established');

          // Test scenario: Write large data, then closeWrite(), then read
          print('   📤 Writing 64KB of data...');
          final testData = Uint8List(64 * 1024);
          for (var i = 0; i < testData.length; i++) {
            testData[i] = i % 256;
          }
          
          // Write data in chunks (simulating real usage)
          const chunkSize = 8192;
          for (var i = 0; i < testData.length; i += chunkSize) {
            final end = (i + chunkSize > testData.length) ? testData.length : i + chunkSize;
            await clientStream.write(testData.sublist(i, end));
          }
          print('   ✅ Data written');

          // Small delay to ensure data is in transit
          await Future.delayed(Duration(milliseconds: 50));

          // Call closeWrite() - this is the critical test
          print('   🔒 Calling closeWrite() on sender stream...');
          await clientStream.closeWrite();
          print('   ✅ closeWrite() completed');

          // Now read all data on the receiver side
          print('   📥 Reading data after closeWrite()...');
          final receivedData = <int>[];
          var readAttempts = 0;
          
          while (receivedData.length < testData.length && readAttempts < 100) {
            readAttempts++;
            final chunk = await serverStream.read().timeout(Duration(seconds: 5));
            
            if (chunk.isEmpty) {
              print('   📭 Received EOF after ${receivedData.length} bytes');
              break;
            }
            
            receivedData.addAll(chunk);
            if (readAttempts % 5 == 0) {
              print('   📈 Progress: ${receivedData.length}/${testData.length} bytes');
            }
          }

          // Verify all data was received
          print('   🔍 Verifying data integrity...');
          expect(
            receivedData.length, 
            equals(testData.length),
            reason: 'Should receive all ${testData.length} bytes, got ${receivedData.length}',
          );
          expect(
            Uint8List.fromList(receivedData), 
            equals(testData),
            reason: 'Received data should match sent data',
          );
          
          print('   ✅ FIN-1 test PASSED - closeWrite() allows complete data transfer');

        } catch (e, stackTrace) {
          print('   ❌ FIN-1 test FAILED: $e');
          print('   Stack trace: $stackTrace');
          rethrow;
        } finally {
          print('   🧹 Cleaning up FIN-1 test...');
          try {
            if (!clientStream.isClosed) {
              await clientStream.close().timeout(Duration(seconds: 2));
            }
            if (!serverStream.isClosed) {
              await serverStream.close().timeout(Duration(seconds: 2));
            }
            if (!clientSession.isClosed) {
              await clientSession.close().timeout(Duration(seconds: 2));
            }
            if (!serverSession.isClosed) {
              await serverSession.close().timeout(Duration(seconds: 2));
            }
            if (!listener.isClosed) {
              await listener.close();
            }
            await clientTransport.dispose();
            await serverTransport.dispose();
          } catch (e) {
            print('   ⚠️ Error during FIN-1 cleanup: $e');
          }
        }
      }, timeout: Timeout(Duration(seconds: 30)));

      test('should return EOF (not error) when reading after FIN received', () async {
        print('\n🧪 TEST FIN-2: Read after FIN should return EOF, not error');
        print('   Goal: Verify that read() returns empty Uint8List after FIN, not StateError');
        
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

          // Establish connections
          final serverAcceptFuture = listener.accept().then((conn) {
            if (conn == null) throw Exception("Listener accepted null connection");
            serverRawConn = conn;
            return serverRawConn;
          });

          final clientDialFuture = clientTransport.dial(actualListenAddr).then((conn) {
            clientRawConn = conn;
            return clientRawConn;
          });

          await Future.wait([clientDialFuture, serverAcceptFuture]);

          // Manually set peer IDs on raw connections (normally done during security handshake)
          print('   Setting up peer IDs on raw connections...');
          (clientRawConn as dynamic).setRemotePeerDetails(serverPeerId, serverKeyPair.publicKey, 'test-no-security');
          (serverRawConn as dynamic).setRemotePeerDetails(clientPeerId, clientKeyPair.publicKey, 'test-no-security');

          // Create Yamux sessions
          final yamuxConfig = MultiplexerConfig(
            keepAliveInterval: Duration(seconds: 30),
            maxStreamWindowSize: 256 * 1024,
            initialStreamWindowSize: 64 * 1024,
            streamWriteTimeout: Duration(seconds: 10),
            maxStreams: 256,
          );

          clientSession = YamuxSession(clientRawConn, yamuxConfig, true);
          serverSession = YamuxSession(serverRawConn, yamuxConfig, false);
          await Future.delayed(Duration(milliseconds: 200));

          // Setup stream handling
          final serverStreamCompleter = Completer<YamuxStream>();
          serverSession.setStreamHandler((stream) async {
            serverStream = stream as YamuxStream;
            if (!serverStreamCompleter.isCompleted) {
              serverStreamCompleter.complete(serverStream);
            }
          });

          // Open client stream
          clientStream = await clientSession.openStream(core_context.Context()) as YamuxStream;
          await serverStreamCompleter.future;
          print('   ✅ Streams established');

          // Write some data and then closeWrite
          print('   📤 Writing small data packet...');
          final testData = Uint8List.fromList([1, 2, 3, 4, 5]);
          await clientStream.write(testData);
          
          // Call closeWrite
          print('   🔒 Calling closeWrite()...');
          await clientStream.closeWrite();
          
          // Small delay to ensure FIN is transmitted
          await Future.delayed(Duration(milliseconds: 100));

          // Read the data
          print('   📥 Reading data...');
          final receivedData = await serverStream.read().timeout(Duration(seconds: 5));
          expect(receivedData, equals(testData), reason: 'First read should return the data');
          print('   ✅ First read returned ${receivedData.length} bytes');

          // Read again - should return EOF (empty), NOT throw an error
          print('   📥 Reading again (expecting EOF)...');
          try {
            final eofData = await serverStream.read().timeout(Duration(seconds: 5));
            expect(eofData.isEmpty, isTrue, reason: 'Second read after FIN should return empty (EOF)');
            print('   ✅ Second read returned EOF (empty Uint8List) as expected');
          } on StateError catch (e) {
            fail('Read after FIN should return EOF, not throw StateError: $e');
          }
          
          print('   ✅ FIN-2 test PASSED - Read returns EOF after FIN');

        } catch (e, stackTrace) {
          print('   ❌ FIN-2 test FAILED: $e');
          print('   Stack trace: $stackTrace');
          rethrow;
        } finally {
          print('   🧹 Cleaning up FIN-2 test...');
          try {
            if (!clientStream.isClosed) {
              await clientStream.close().timeout(Duration(seconds: 2));
            }
            if (!serverStream.isClosed) {
              await serverStream.close().timeout(Duration(seconds: 2));
            }
            if (!clientSession.isClosed) {
              await clientSession.close().timeout(Duration(seconds: 2));
            }
            if (!serverSession.isClosed) {
              await serverSession.close().timeout(Duration(seconds: 2));
            }
            if (!listener.isClosed) {
              await listener.close();
            }
            await clientTransport.dispose();
            await serverTransport.dispose();
          } catch (e) {
            print('   ⚠️ Error during FIN-2 cleanup: $e');
          }
        }
      }, timeout: Timeout(Duration(seconds: 30)));

      test('should handle pending read when FIN arrives', () async {
        print('\n🧪 TEST FIN-3: Pending read when FIN arrives');
        print('   Goal: Verify that a read() blocked waiting for data handles FIN gracefully');
        
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

          // Establish connections
          final serverAcceptFuture = listener.accept().then((conn) {
            if (conn == null) throw Exception("Listener accepted null connection");
            serverRawConn = conn;
            return serverRawConn;
          });

          final clientDialFuture = clientTransport.dial(actualListenAddr).then((conn) {
            clientRawConn = conn;
            return clientRawConn;
          });

          await Future.wait([clientDialFuture, serverAcceptFuture]);

          // Manually set peer IDs on raw connections (normally done during security handshake)
          print('   Setting up peer IDs on raw connections...');
          (clientRawConn as dynamic).setRemotePeerDetails(serverPeerId, serverKeyPair.publicKey, 'test-no-security');
          (serverRawConn as dynamic).setRemotePeerDetails(clientPeerId, clientKeyPair.publicKey, 'test-no-security');

          // Create Yamux sessions
          final yamuxConfig = MultiplexerConfig(
            keepAliveInterval: Duration(seconds: 30),
            maxStreamWindowSize: 256 * 1024,
            initialStreamWindowSize: 64 * 1024,
            streamWriteTimeout: Duration(seconds: 10),
            maxStreams: 256,
          );

          clientSession = YamuxSession(clientRawConn, yamuxConfig, true);
          serverSession = YamuxSession(serverRawConn, yamuxConfig, false);
          await Future.delayed(Duration(milliseconds: 200));

          // Setup stream handling
          final serverStreamCompleter = Completer<YamuxStream>();
          serverSession.setStreamHandler((stream) async {
            serverStream = stream as YamuxStream;
            if (!serverStreamCompleter.isCompleted) {
              serverStreamCompleter.complete(serverStream);
            }
          });

          // Open client stream
          clientStream = await clientSession.openStream(core_context.Context()) as YamuxStream;
          await serverStreamCompleter.future;
          print('   ✅ Streams established');

          // Start a read on the server side BEFORE any data is sent
          // This creates a pending read that will be waiting when FIN arrives
          print('   📥 Starting read() that will block waiting for data...');
          final readFuture = serverStream.read().timeout(
            Duration(seconds: 10),
            onTimeout: () => throw TimeoutException('Read timed out'),
          );

          // Small delay to ensure read is blocking
          await Future.delayed(Duration(milliseconds: 100));

          // Now send data and closeWrite
          print('   📤 Writing data while read is pending...');
          final testData = Uint8List.fromList(List.generate(1000, (i) => i % 256));
          await clientStream.write(testData);
          
          print('   🔒 Calling closeWrite()...');
          await clientStream.closeWrite();

          // The pending read should complete with the data, NOT error
          print('   ⏳ Waiting for pending read to complete...');
          try {
            final receivedData = await readFuture;
            print('   ✅ Pending read completed with ${receivedData.length} bytes');
            expect(receivedData.isNotEmpty, isTrue, reason: 'Should receive data, not empty');
            expect(receivedData, equals(testData), reason: 'Should receive the sent data');
          } on StateError catch (e) {
            fail('Pending read should complete with data, not throw StateError: $e');
          }

          print('   ✅ FIN-3 test PASSED - Pending reads handle FIN gracefully');

        } catch (e, stackTrace) {
          print('   ❌ FIN-3 test FAILED: $e');
          print('   Stack trace: $stackTrace');
          rethrow;
        } finally {
          print('   🧹 Cleaning up FIN-3 test...');
          try {
            if (!clientStream.isClosed) {
              await clientStream.close().timeout(Duration(seconds: 2));
            }
            if (!serverStream.isClosed) {
              await serverStream.close().timeout(Duration(seconds: 2));
            }
            if (!clientSession.isClosed) {
              await clientSession.close().timeout(Duration(seconds: 2));
            }
            if (!serverSession.isClosed) {
              await serverSession.close().timeout(Duration(seconds: 2));
            }
            if (!listener.isClosed) {
              await listener.close();
            }
            await clientTransport.dispose();
            await serverTransport.dispose();
          } catch (e) {
            print('   ⚠️ Error during FIN-3 cleanup: $e');
          }
        }
      }, timeout: Timeout(Duration(seconds: 30)));
    });

    group('Noise Encryption State: Multiple Sequential Messages', () {
      test('should handle 100 sequential framed messages (1KB each) over Noise without MAC errors', () async {
        print('\n🧪 TEST NOISE-1: Multiple Sequential Framed Messages Over Noise');
        print('   Goal: Replicate Ricochet pattern - many small messages vs one large blob');
        print('   Hypothesis: MAC errors occur when Noise encryption state desyncs during rapid sequential writes');
        
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
            return serverRawConn;
          });

          final clientDialFuture = clientTransport.dial(actualListenAddr).then((conn) {
            clientRawConn = conn;
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
          print('   ✅ Connections upgraded with Noise + Yamux');

          // Setup stream handling
          final serverAcceptStreamFuture = (serverUpgradedConn as core_mux_types.MuxedConn).acceptStream().then((stream) { 
            serverStream = stream as YamuxStream;
            return serverStream;
          });

          await Future.delayed(Duration(milliseconds: 100));

          // Open client stream
          clientStream = await (clientUpgradedConn as core_mux_types.MuxedConn).openStream(core_context.Context()) as YamuxStream;
          
          await serverAcceptStreamFuture;
          expect(clientStream, isNotNull);
          expect(serverStream, isNotNull);
          print('   ✅ Yamux streams established over Noise');

          // Test multiple sequential framed messages
          print('   🚀 Starting test: 100 framed messages (1KB each)...');
          const messageCount = 100;
          const messageSize = 1024;
          
          // Server writes 100 framed messages rapidly
          print('   📤 Server writing $messageCount framed messages...');
          final writeCompleter = Completer<void>();
          Future.microtask(() async {
            try {
              for (int i = 0; i < messageCount; i++) {
                // Create test message
                final messageData = Uint8List(messageSize);
                for (var j = 0; j < messageSize; j++) {
                  messageData[j] = (i + j) % 256;
                }
                
                // Frame the message (length-prefix, like Ricochet does)
                final lengthBytes = ByteData(4)..setUint32(0, messageData.length, Endian.big);
                await serverStream.write(lengthBytes.buffer.asUint8List());
                await serverStream.write(messageData);
                
                // NO DELAY - write rapidly like Ricochet does
                
                if ((i + 1) % 20 == 0) {
                  print('   📤 Server wrote ${i + 1}/$messageCount messages');
                }
              }
              print('   ✅ Server wrote all $messageCount framed messages');
              writeCompleter.complete();
            } catch (e, stackTrace) {
              print('   ❌ Server write failed: $e');
              print('   Stack trace: $stackTrace');
              writeCompleter.completeError(e);
            }
          });
          
          // Client reads all 100 framed messages
          print('   📥 Client reading framed messages...');
          final receivedMessages = <Uint8List>[];
          try {
            for (int i = 0; i < messageCount; i++) {
              // Read length prefix (4 bytes)
              final lengthBytes = await _readExact(clientStream, 4);
              final length = ByteData.view(lengthBytes.buffer).getUint32(0, Endian.big);
              
              // Read message body
              final messageData = await _readExact(clientStream, length);
              receivedMessages.add(messageData);
              
              if ((i + 1) % 20 == 0) {
                print('   📥 Client received ${i + 1}/$messageCount messages');
              }
            }
            
            print('   ✅ Client received all $messageCount messages');
          } catch (e, stackTrace) {
            print('   ❌ Client read failed after ${receivedMessages.length} messages: $e');
            print('   Stack trace: $stackTrace');
            
            // Check if it's a MAC error (the hypothesis we're testing)
            final errorString = e.toString().toLowerCase();
            if (errorString.contains('mac') || errorString.contains('authentication')) {
              print('   🔍 HYPOTHESIS CONFIRMED: MAC/Authentication error during sequential messages!');
              print('   🔍 This indicates Noise encryption state desynchronization');
            }
            
            rethrow;
          }
          
          // Wait for writes to complete
          await writeCompleter.future.timeout(Duration(seconds: 30));
          
          // Verify all messages received
          expect(receivedMessages.length, equals(messageCount),
              reason: 'Should receive all $messageCount messages');
          
          // Verify message content integrity
          for (int i = 0; i < messageCount; i++) {
            final expected = Uint8List(messageSize);
            for (var j = 0; j < messageSize; j++) {
              expected[j] = (i + j) % 256;
            }
            expect(receivedMessages[i], equals(expected),
                reason: 'Message $i content should match');
          }
          
          print('   ✅ NOISE-1 test PASSED - No MAC errors with sequential messages');

        } catch (e, stackTrace) {
          print('   ❌ NOISE-1 test FAILED: $e');
          print('   Stack trace: $stackTrace');
          
          // Check if it's the MAC error we're investigating
          final errorString = e.toString().toLowerCase();
          if (errorString.contains('mac') || errorString.contains('authentication')) {
            print('\n   🔍 CRITICAL FINDING: MAC authentication error detected!');
            print('   🔍 This confirms the hypothesis: Noise encryption state desyncs during rapid sequential writes');
            print('   🔍 Root cause is likely in Noise nonce/counter management during buffered writes');
          }
          
          rethrow;
        } finally {
          // Cleanup
          print('   🧹 Cleaning up NOISE-1 test...');
          try {
            if (!clientStream.isClosed) {
              await clientStream.close().timeout(Duration(seconds: 2));
            }
            if (!serverStream.isClosed) {
              await serverStream.close().timeout(Duration(seconds: 2));
            }
            if (!clientUpgradedConn.isClosed) {
              await clientUpgradedConn.close().timeout(Duration(seconds: 2));
            }
            if (!serverUpgradedConn.isClosed) {
              await serverUpgradedConn.close().timeout(Duration(seconds: 2));
            }
            if (!listener.isClosed) {
              await listener.close();
            }
            await clientTransport.dispose();
            await serverTransport.dispose();
          } catch (e) {
            print('   ⚠️ Error during NOISE-1 cleanup: $e');
          }
          print('   ✅ NOISE-1 cleanup complete');
        }
      }, timeout: Timeout(Duration(minutes: 2)));

      test('should maintain Noise encryption state across rapid vs delayed writes', () async {
        print('\n🧪 TEST NOISE-2: Rapid vs Delayed Writes Comparison');
        print('   Goal: Compare behavior of writes with delays vs without delays');
        print('   Hypothesis: Rapid writes without delays cause Noise state desync');
        
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

        try {
          // Setup components (same as previous test)
          final resourceManager = NullResourceManager();
          final connManager = NullConnMgr();

          clientTransport = UDXTransport(connManager: connManager, udxInstance: udxInstance);
          serverTransport = UDXTransport(connManager: connManager, udxInstance: udxInstance);

          clientUpgrader = BasicUpgrader(resourceManager: resourceManager);
          serverUpgrader = BasicUpgrader(resourceManager: resourceManager);

          final securityProtocolsClient = [await NoiseSecurity.create(clientKeyPair)];
          final securityProtocolsServer = [await NoiseSecurity.create(serverKeyPair)];
          
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

          final initialListenAddr = MultiAddr('/ip4/127.0.0.1/udp/0/udx');
          listener = await serverTransport.listen(initialListenAddr);
          final actualListenAddr = listener.addr;
          print('   Server listening on: $actualListenAddr');

          final serverAcceptFuture = listener.accept().then((conn) {
            if (conn == null) throw Exception("Listener accepted null connection");
            serverRawConn = conn;
            return serverRawConn;
          });

          final clientDialFuture = clientTransport.dial(actualListenAddr).then((conn) {
            clientRawConn = conn;
            return clientRawConn;
          });

          await Future.wait([clientDialFuture, serverAcceptFuture]);

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
          print('   ✅ Connections upgraded with Noise + Yamux');

          // Test data
          final testData = Uint8List(1024);
          for (var i = 0; i < testData.length; i++) {
            testData[i] = i % 256;
          }

          // Scenario A: Sequential writes WITH delays (should work)
          print('\n   🧪 Scenario A: 50 writes WITH 10ms delays between writes');
          {
            final serverAcceptStreamFuture = (serverUpgradedConn as core_mux_types.MuxedConn).acceptStream();
            await Future.delayed(Duration(milliseconds: 50));
            final clientStream = await (clientUpgradedConn as core_mux_types.MuxedConn).openStream(core_context.Context()) as YamuxStream;
            final serverStream = await serverAcceptStreamFuture as YamuxStream;
            
            // Write with delays
            Future.microtask(() async {
              for (int i = 0; i < 50; i++) {
                await serverStream.write(testData);
                await Future.delayed(Duration(milliseconds: 10)); // Allow read to drain
                
                if ((i + 1) % 10 == 0) {
                  print('   📤 Scenario A: Wrote ${i + 1}/50 messages');
                }
              }
            });
            
            // Read all
            int receivedCount = 0;
            int totalBytes = 0;
            try {
              while (receivedCount < 50) {
                final chunk = await clientStream.read().timeout(Duration(seconds: 30));
                if (chunk.isEmpty) break;
                totalBytes += chunk.length;
                receivedCount = totalBytes ~/ testData.length;
                
                if (receivedCount % 10 == 0 && receivedCount > 0) {
                  print('   📥 Scenario A: Received ~$receivedCount messages');
                }
              }
              print('   ✅ Scenario A PASSED: Received ~$receivedCount messages (${totalBytes} bytes)');
            } catch (e) {
              print('   ❌ Scenario A FAILED: $e');
              rethrow;
            } finally {
              await clientStream.close();
              await serverStream.close();
            }
          }

          // Small delay between scenarios
          await Future.delayed(Duration(milliseconds: 500));

          // Scenario B: Rapid sequential writes WITHOUT delays (may fail if Noise state issue)
          print('\n   🧪 Scenario B: 50 writes WITHOUT delays (rapid fire)');
          {
            final serverAcceptStreamFuture = (serverUpgradedConn as core_mux_types.MuxedConn).acceptStream();
            await Future.delayed(Duration(milliseconds: 50));
            final clientStream = await (clientUpgradedConn as core_mux_types.MuxedConn).openStream(core_context.Context()) as YamuxStream;
            final serverStream = await serverAcceptStreamFuture as YamuxStream;
            
            // Write rapidly without delays
            Future.microtask(() async {
              try {
                for (int i = 0; i < 50; i++) {
                  await serverStream.write(testData);
                  // NO DELAY - this is the critical test
                  
                  if ((i + 1) % 10 == 0) {
                    print('   📤 Scenario B: Wrote ${i + 1}/50 messages');
                  }
                }
                print('   ✅ Scenario B: All writes completed');
              } catch (e) {
                print('   ❌ Scenario B: Write failed: $e');
              }
            });
            
            // Read all
            int receivedCount = 0;
            int totalBytes = 0;
            try {
              while (receivedCount < 50) {
                final chunk = await clientStream.read().timeout(Duration(seconds: 30));
                if (chunk.isEmpty) break;
                totalBytes += chunk.length;
                receivedCount = totalBytes ~/ testData.length;
                
                if (receivedCount % 10 == 0 && receivedCount > 0) {
                  print('   📥 Scenario B: Received ~$receivedCount messages');
                }
              }
              
              if (receivedCount < 50) {
                print('   ⚠️  Scenario B: Only received $receivedCount/50 messages (${totalBytes} bytes)');
                print('   🔍 This suggests data loss or stream closure during rapid writes');
              } else {
                print('   ✅ Scenario B PASSED: Received all ~$receivedCount messages (${totalBytes} bytes)');
              }
              
            } catch (e) {
              print('   ❌ Scenario B FAILED after $receivedCount messages: $e');
              
              final errorString = e.toString().toLowerCase();
              if (errorString.contains('mac') || errorString.contains('authentication')) {
                print('   🔍 CRITICAL: MAC error in rapid writes but not delayed writes!');
                print('   🔍 This confirms timing-dependent Noise encryption state issue');
              }
              
              rethrow;
            } finally {
              await clientStream.close();
              await serverStream.close();
            }
          }

          print('\n   ✅ NOISE-2 test PASSED - Both scenarios completed');

        } catch (e, stackTrace) {
          print('   ❌ NOISE-2 test FAILED: $e');
          print('   Stack trace: $stackTrace');
          rethrow;
        } finally {
          print('   🧹 Cleaning up NOISE-2 test...');
          try {
            if (!clientUpgradedConn.isClosed) {
              await clientUpgradedConn.close().timeout(Duration(seconds: 2));
            }
            if (!serverUpgradedConn.isClosed) {
              await serverUpgradedConn.close().timeout(Duration(seconds: 2));
            }
            if (!listener.isClosed) {
              await listener.close();
            }
            await clientTransport.dispose();
            await serverTransport.dispose();
          } catch (e) {
            print('   ⚠️ Error during NOISE-2 cleanup: $e');
          }
          print('   ✅ NOISE-2 cleanup complete');
        }
      }, timeout: Timeout(Duration(minutes: 2)));
    });

    group('Large Bidirectional Transfer Stress Test', () {
      test('should handle 500KB bidirectional transfers repeated multiple times', () async {
        print('\n🧪 TEST STRESS-1: 500KB Bidirectional Transfers (Multiple Iterations)');
        print('   Goal: Simulate Ricochet mailbox upload scenario with large payloads');
        print('   Pattern: Client → Server (500KB), Server → Client (500KB), repeat 5 times');
            print('   Note: Using 4KB max frame size to prevent Noise HOL blocking');
        
        BasicHost? clientHost;
        BasicHost? serverHost;
        MultiAddr? serverListenAddr;
        
        // Track connection health throughout
        var connectionDropDetected = false;
        String? connectionDropReason;

        try {
          // Setup components
          final resourceManager = ResourceManagerImpl(limiter: FixedLimiter());
          final clientConnManager = p2p_transport.ConnectionManager();
          final serverConnManager = p2p_transport.ConnectionManager();
          final clientEventBus = BasicBus();
          final serverEventBus = BasicBus();

          // Setup security and multiplexing
          // IMPORTANT: Using smaller max frame size (4KB) to prevent Noise encryption
          // head-of-line blocking. When encrypted, each Yamux frame becomes an atomic 
          // message that must be fully received before decryption. Smaller frames mean:
          // - Faster recovery from packet loss (less data to retransmit)
          // - Better interleaving of control frames (window updates, pings)
          // - Reduced risk of deadlock from flow control starvation
          final yamuxMultiplexerConfig = MultiplexerConfig(
            keepAliveInterval: Duration(seconds: 30),
            maxStreamWindowSize: 256 * 1024,  // 256KB max window
            initialStreamWindowSize: 64 * 1024,   // 64KB initial window
            maxFrameSize: 4 * 1024,  // 4KB max frame - prevents HOL blocking with Noise
            streamWriteTimeout: Duration(seconds: 30),
            maxStreams: 256,
          );
          final muxerDefs = [_TestYamuxMuxerProvider(yamuxConfig: yamuxMultiplexerConfig)];

          final clientSecurity = [await NoiseSecurity.create(clientKeyPair)];
          final serverSecurity = [await NoiseSecurity.create(serverKeyPair)];

          // Setup configs
          final clientP2PConfig = p2p_config.Config()
            ..peerKey = clientKeyPair
            ..securityProtocols = clientSecurity
            ..muxers = muxerDefs
            ..connManager = clientConnManager
            ..eventBus = clientEventBus;

          final serverP2PConfig = p2p_config.Config()
            ..peerKey = serverKeyPair
            ..securityProtocols = serverSecurity
            ..muxers = muxerDefs
            ..addrsFactory = passThroughAddrsFactory;
          
          final initialListenAddr = MultiAddr('/ip4/127.0.0.1/udp/0/udx');
          serverP2PConfig.listenAddrs = [initialListenAddr];
          serverP2PConfig.connManager = serverConnManager;
          serverP2PConfig.eventBus = serverEventBus;

          // Setup transports with separate UDX instances for isolation
          final clientUdxTransport = UDXTransport(connManager: clientConnManager, udxInstance: udxInstance);
          final serverUdxTransport = UDXTransport(connManager: serverConnManager, udxInstance: udxInstance);
          
          // Setup peerstores
          final clientPeerstore = MemoryPeerstore();
          final serverPeerstore = MemoryPeerstore();

          // Create Swarms and BasicHosts
          final clientSwarm = Swarm(
            host: null,
            localPeer: clientPeerId,
            peerstore: clientPeerstore,
            resourceManager: resourceManager,
            upgrader: BasicUpgrader(resourceManager: resourceManager),
            config: clientP2PConfig,
            transports: [clientUdxTransport],
          );
          
          // Add network notifiee to track connection events
          clientSwarm.notify(TestNotifiee(
            connectedCallback: (network, conn) {
              print('   🔗 [CLIENT] Connected: ${conn.remotePeer}');
            },
            disconnectedCallback: (network, conn) {
              print('   ⚠️  [CLIENT] Disconnected: ${conn.remotePeer}');
              connectionDropDetected = true;
              connectionDropReason = 'Client detected disconnection';
            },
          ));
          
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
          
          // Add network notifiee to track connection events
          serverSwarm.notify(TestNotifiee(
            connectedCallback: (network, conn) {
              print('   🔗 [SERVER] Connected: ${conn.remotePeer}');
            },
            disconnectedCallback: (network, conn) {
              print('   ⚠️  [SERVER] Disconnected: ${conn.remotePeer}');
              connectionDropDetected = true;
              connectionDropReason = 'Server detected disconnection';
            },
          ));
          
          serverHost = await BasicHost.create(network: serverSwarm, config: serverP2PConfig);
          serverSwarm.setHost(serverHost);

          // Protocol for bidirectional transfer
          const bidirectionalProtocolId = '/test/bidirectional/1.0.0';
          
          // Track all received data on server side for each iteration
          final serverReceivedDataByIteration = <int, List<int>>{};
          final serverStreamsByIteration = <int, core_network_stream.P2PStream>{};
          final serverStreamCompleters = <int, Completer<core_network_stream.P2PStream>>{};
          
          // Pre-create completers for expected iterations
          for (var i = 0; i < 5; i++) {
            serverStreamCompleters[i] = Completer<core_network_stream.P2PStream>();
            serverReceivedDataByIteration[i] = [];
          }
          
          var currentServerIteration = 0;
          
          serverHost.setStreamHandler(bidirectionalProtocolId, (core_network_stream.P2PStream stream, PeerId peerId) async {
            final iteration = currentServerIteration;
            currentServerIteration++;
            
            print('   📨 [SERVER] Received stream for iteration $iteration: ${stream.id()} from $peerId');
            serverStreamsByIteration[iteration] = stream;
            
            if (serverStreamCompleters.containsKey(iteration) && !serverStreamCompleters[iteration]!.isCompleted) {
              serverStreamCompleters[iteration]!.complete(stream);
            }
          });

          await serverSwarm.listen(serverP2PConfig.listenAddrs);
          await serverHost.start();

          expect(serverHost.addrs.isNotEmpty, isTrue);
          serverListenAddr = serverHost.addrs.firstWhere((addr) => addr.hasProtocol(multiaddr_protocol.Protocols.udx.name));
          print('   Server Host listening on: $serverListenAddr');

          // Add server peer info to client
          clientHost.peerStore.addrBook.addAddrs(
            serverPeerId,
            [serverListenAddr],
            AddressTTL.permanentAddrTTL,
          );
          clientHost.peerStore.keyBook.addPubKey(serverPeerId, serverKeyPair.publicKey);

          // Connect via BasicHost
          print('   🔗 Connecting via BasicHost...');
          final serverAddrInfo = AddrInfo(serverPeerId, [serverListenAddr]);
          await clientHost.connect(serverAddrInfo);
          print('   ✅ Client Host connected to server');

          // Create 500KB test data (simulating large image upload)
          const payloadSize = 500 * 1024;  // 500KB
          final largeData = Uint8List(payloadSize);
          for (var i = 0; i < largeData.length; i++) {
            largeData[i] = i % 256;
          }
          print('   📊 Test payload: ${payloadSize ~/ 1024}KB');

          // Perform 5 iterations of bidirectional transfer
          const iterations = 5;
          for (var iteration = 0; iteration < iterations; iteration++) {
            print('\n   ════════════════════════════════════════════════');
            print('   🔄 ITERATION ${iteration + 1}/$iterations');
            print('   ════════════════════════════════════════════════');
            
            // Check connection health before each iteration
            if (connectionDropDetected) {
              print('   ❌ CONNECTION DROP DETECTED before iteration ${iteration + 1}');
              print('   Reason: $connectionDropReason');
              fail('Connection dropped before iteration ${iteration + 1}: $connectionDropReason');
            }
            
            // Open new stream for this iteration
            print('   📤 Opening stream for iteration ${iteration + 1}...');
            final clientStream = await clientHost.newStream(
              serverPeerId, 
              [bidirectionalProtocolId], 
              core_context.Context(),
            ).timeout(
              Duration(seconds: 10),
              onTimeout: () {
                throw TimeoutException('Failed to open stream for iteration ${iteration + 1}');
              },
            );
            print('   ✅ Client stream opened: ${clientStream.id()}');
            
            // Wait for server to accept stream
            final serverStream = await serverStreamCompleters[iteration]!.future.timeout(
              Duration(seconds: 10),
              onTimeout: () {
                throw TimeoutException('Server failed to accept stream for iteration ${iteration + 1}');
              },
            );
            print('   ✅ Server stream accepted: ${serverStream.id()}');
            
            // Phase 1: Client → Server (500KB)
            print('\n   📤 Phase 1: Client → Server (${payloadSize ~/ 1024}KB)');
            final phase1StartTime = DateTime.now();
            
            // Send data in chunks - using 4KB to prevent Noise encryption head-of-line blocking
            // Larger chunks (16KB) can cause deadlock when encrypted messages block window updates
            const chunkSize = 4096;  // 4KB chunks
            var bytesSent = 0;
            var chunkCount = 0;
            for (var i = 0; i < largeData.length; i += chunkSize) {
              if (connectionDropDetected) {
                print('   ❌ CONNECTION DROP during Phase 1 send at byte $bytesSent');
                fail('Connection dropped during Phase 1 of iteration ${iteration + 1}');
              }
              
              final end = (i + chunkSize > largeData.length) ? largeData.length : i + chunkSize;
              await clientStream.write(largeData.sublist(i, end));
              bytesSent = end;
              chunkCount++;
              
              // Yield every 8 chunks (32KB) to allow event loop to process incoming window updates
              // This prevents deadlock where sender blocks but can't receive window updates
              if (chunkCount % 8 == 0) {
                await Future.delayed(Duration.zero);
              }
              
              if (bytesSent % (100 * 1024) == 0 || bytesSent == largeData.length) {
                print('   📤 Sent: ${bytesSent ~/ 1024}KB / ${payloadSize ~/ 1024}KB');
              }
            }
            
            // Signal end of client data
            await clientStream.closeWrite();
            print('   ✅ Client finished sending, closeWrite() called');
            
            // Read all data on server side
            print('   📥 Server reading incoming data...');
            final serverReceivedData = <int>[];
            try {
              while (true) {
                final chunk = await serverStream.read().timeout(Duration(seconds: 30));
                if (chunk.isEmpty) {
                  print('   📭 Server received EOF');
                  break;
                }
                serverReceivedData.addAll(chunk);
                
                if (serverReceivedData.length % (100 * 1024) == 0 || 
                    serverReceivedData.length >= payloadSize) {
                  print('   📥 Received: ${serverReceivedData.length ~/ 1024}KB / ${payloadSize ~/ 1024}KB');
                }
              }
            } catch (e) {
              print('   ⚠️  Server read error: $e');
              if (serverReceivedData.length < payloadSize) {
                rethrow;
              }
            }
            
            final phase1Duration = DateTime.now().difference(phase1StartTime);
            print('   ⏱️  Phase 1 completed in ${phase1Duration.inMilliseconds}ms');
            
            // Verify Phase 1 data
            expect(
              serverReceivedData.length,
              equals(payloadSize),
              reason: 'Iteration ${iteration + 1} Phase 1: Server should receive all $payloadSize bytes',
            );
            expect(
              Uint8List.fromList(serverReceivedData),
              equals(largeData),
              reason: 'Iteration ${iteration + 1} Phase 1: Data integrity check',
            );
            print('   ✅ Phase 1 verified: ${serverReceivedData.length ~/ 1024}KB received correctly');
            
            // Phase 2: Server → Client (500KB response)
            print('\n   📤 Phase 2: Server → Client (${payloadSize ~/ 1024}KB)');
            final phase2StartTime = DateTime.now();
            
            // Create response data (different pattern to verify)
            final responseData = Uint8List(payloadSize);
            for (var i = 0; i < responseData.length; i++) {
              responseData[i] = (255 - (i % 256)) & 0xFF;  // Inverted pattern
            }
            
            // Server sends response
            var responseSent = 0;
            var responseChunkCount = 0;
            for (var i = 0; i < responseData.length; i += chunkSize) {
              if (connectionDropDetected) {
                print('   ❌ CONNECTION DROP during Phase 2 send at byte $responseSent');
                fail('Connection dropped during Phase 2 of iteration ${iteration + 1}');
              }
              
              final end = (i + chunkSize > responseData.length) ? responseData.length : i + chunkSize;
              await serverStream.write(responseData.sublist(i, end));
              responseSent = end;
              responseChunkCount++;
              
              // Yield every 8 chunks (32KB) to allow event loop to process incoming window updates
              if (responseChunkCount % 8 == 0) {
                await Future.delayed(Duration.zero);
              }
              
              if (responseSent % (100 * 1024) == 0 || responseSent == responseData.length) {
                print('   📤 Server sent: ${responseSent ~/ 1024}KB / ${payloadSize ~/ 1024}KB');
              }
            }
            
            // Signal end of server data
            await serverStream.closeWrite();
            print('   ✅ Server finished sending, closeWrite() called');
            
            // Read response on client side
            print('   📥 Client reading response...');
            final clientReceivedData = <int>[];
            try {
              while (true) {
                final chunk = await clientStream.read().timeout(Duration(seconds: 30));
                if (chunk.isEmpty) {
                  print('   📭 Client received EOF');
                  break;
                }
                clientReceivedData.addAll(chunk);
                
                if (clientReceivedData.length % (100 * 1024) == 0 || 
                    clientReceivedData.length >= payloadSize) {
                  print('   📥 Client received: ${clientReceivedData.length ~/ 1024}KB / ${payloadSize ~/ 1024}KB');
                }
              }
            } catch (e) {
              print('   ⚠️  Client read error: $e');
              if (clientReceivedData.length < payloadSize) {
                rethrow;
              }
            }
            
            final phase2Duration = DateTime.now().difference(phase2StartTime);
            print('   ⏱️  Phase 2 completed in ${phase2Duration.inMilliseconds}ms');
            
            // Verify Phase 2 data
            expect(
              clientReceivedData.length,
              equals(payloadSize),
              reason: 'Iteration ${iteration + 1} Phase 2: Client should receive all $payloadSize bytes',
            );
            expect(
              Uint8List.fromList(clientReceivedData),
              equals(responseData),
              reason: 'Iteration ${iteration + 1} Phase 2: Response data integrity check',
            );
            print('   ✅ Phase 2 verified: ${clientReceivedData.length ~/ 1024}KB received correctly');
            
            // Close streams for this iteration
            await clientStream.close();
            await serverStream.close();
            
            print('   ✅ Iteration ${iteration + 1} COMPLETE');
            print('   📊 Total transferred this iteration: ${(payloadSize * 2) ~/ 1024}KB');
            
            // Brief pause between iterations to let any cleanup happen
            await Future.delayed(Duration(milliseconds: 100));
          }
          
          print('\n   ════════════════════════════════════════════════');
          print('   ✅ ALL $iterations ITERATIONS COMPLETED SUCCESSFULLY');
          print('   📊 Total data transferred: ${(payloadSize * 2 * iterations) ~/ 1024}KB');
          print('   ════════════════════════════════════════════════');

        } catch (e, stackTrace) {
          print('\n   ❌ TEST FAILED: $e');
          print('   Stack trace: $stackTrace');
          
          if (connectionDropDetected) {
            print('\n   🔍 CONNECTION DROP ANALYSIS:');
            print('   Reason: $connectionDropReason');
          }
          
          rethrow;
        } finally {
          print('\n   🧹 Cleaning up stress test...');
          try {
            if (clientHost != null) {
              await clientHost.close().timeout(Duration(seconds: 5));
            }
            if (serverHost != null) {
              await serverHost.close().timeout(Duration(seconds: 5));
            }
          } catch (e) {
            print('   ⚠️ Error during cleanup: $e');
          }
          print('   ✅ Cleanup complete');
        }
      }, timeout: Timeout(Duration(minutes: 5)));

      test('should handle rapid sequential small messages after large transfer', () async {
        print('\n🧪 TEST STRESS-2: Large Transfer Followed by Rapid Small Messages');
        print('   Goal: Simulate Ricochet pattern where large mailbox upload is followed by ACKs/status messages');
        
        BasicHost? clientHost;
        BasicHost? serverHost;
        MultiAddr? serverListenAddr;

        try {
          // Setup components (same pattern as STRESS-1)
          final resourceManager = ResourceManagerImpl(limiter: FixedLimiter());
          final clientConnManager = p2p_transport.ConnectionManager();
          final serverConnManager = p2p_transport.ConnectionManager();
          final clientEventBus = BasicBus();
          final serverEventBus = BasicBus();

          final yamuxMultiplexerConfig = MultiplexerConfig(
            keepAliveInterval: Duration(seconds: 30),
            maxStreamWindowSize: 2 * 1024 * 1024,
            initialStreamWindowSize: 512 * 1024,
            streamWriteTimeout: Duration(seconds: 30),
            maxStreams: 256,
          );
          final muxerDefs = [_TestYamuxMuxerProvider(yamuxConfig: yamuxMultiplexerConfig)];

          final clientSecurity = [await NoiseSecurity.create(clientKeyPair)];
          final serverSecurity = [await NoiseSecurity.create(serverKeyPair)];

          final clientP2PConfig = p2p_config.Config()
            ..peerKey = clientKeyPair
            ..securityProtocols = clientSecurity
            ..muxers = muxerDefs
            ..connManager = clientConnManager
            ..eventBus = clientEventBus;

          final serverP2PConfig = p2p_config.Config()
            ..peerKey = serverKeyPair
            ..securityProtocols = serverSecurity
            ..muxers = muxerDefs
            ..addrsFactory = passThroughAddrsFactory;
          
          final initialListenAddr = MultiAddr('/ip4/127.0.0.1/udp/0/udx');
          serverP2PConfig.listenAddrs = [initialListenAddr];
          serverP2PConfig.connManager = serverConnManager;
          serverP2PConfig.eventBus = serverEventBus;

          final clientUdxTransport = UDXTransport(connManager: clientConnManager, udxInstance: udxInstance);
          final serverUdxTransport = UDXTransport(connManager: serverConnManager, udxInstance: udxInstance);
          
          final clientPeerstore = MemoryPeerstore();
          final serverPeerstore = MemoryPeerstore();

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

          // Protocol handlers
          const uploadProtocolId = '/test/upload/1.0.0';
          const messageProtocolId = '/test/message/1.0.0';
          
          final uploadStreamCompleter = Completer<core_network_stream.P2PStream>();
          final messageStreamCompleters = <Completer<core_network_stream.P2PStream>>[];
          for (var i = 0; i < 50; i++) {
            messageStreamCompleters.add(Completer<core_network_stream.P2PStream>());
          }
          var messageStreamIndex = 0;
          
          serverHost.setStreamHandler(uploadProtocolId, (stream, peerId) async {
            print('   📨 [SERVER] Upload stream received');
            if (!uploadStreamCompleter.isCompleted) {
              uploadStreamCompleter.complete(stream);
            }
          });
          
          serverHost.setStreamHandler(messageProtocolId, (stream, peerId) async {
            final idx = messageStreamIndex++;
            print('   📨 [SERVER] Message stream $idx received');
            if (idx < messageStreamCompleters.length && !messageStreamCompleters[idx].isCompleted) {
              messageStreamCompleters[idx].complete(stream);
            }
          });

          await serverSwarm.listen(serverP2PConfig.listenAddrs);
          await serverHost.start();

          serverListenAddr = serverHost.addrs.firstWhere((addr) => addr.hasProtocol(multiaddr_protocol.Protocols.udx.name));
          print('   Server listening on: $serverListenAddr');

          clientHost.peerStore.addrBook.addAddrs(serverPeerId, [serverListenAddr], AddressTTL.permanentAddrTTL);
          clientHost.peerStore.keyBook.addPubKey(serverPeerId, serverKeyPair.publicKey);

          // Connect
          print('   🔗 Connecting...');
          await clientHost.connect(AddrInfo(serverPeerId, [serverListenAddr]));
          print('   ✅ Connected');

          // Phase 1: Large upload (500KB)
          print('\n   📤 Phase 1: Large upload (500KB)');
          final uploadData = Uint8List(500 * 1024);
          for (var i = 0; i < uploadData.length; i++) {
            uploadData[i] = i % 256;
          }
          
          final uploadClientStream = await clientHost.newStream(serverPeerId, [uploadProtocolId], core_context.Context());
          final uploadServerStream = await uploadStreamCompleter.future.timeout(Duration(seconds: 10));
          
          // Send large payload - using 4KB chunks to prevent Noise deadlock
          const chunkSize = 4096;
          for (var i = 0; i < uploadData.length; i += chunkSize) {
            final end = (i + chunkSize > uploadData.length) ? uploadData.length : i + chunkSize;
            await uploadClientStream.write(uploadData.sublist(i, end));
            if ((i + chunkSize) % (100 * 1024) < chunkSize) {
              print('   📤 Upload: ${(i + chunkSize) ~/ 1024}KB / ${uploadData.length ~/ 1024}KB');
            }
          }
          await uploadClientStream.closeWrite();
          
          // Read on server
          final uploadReceived = <int>[];
          while (true) {
            final chunk = await uploadServerStream.read().timeout(Duration(seconds: 30));
            if (chunk.isEmpty) break;
            uploadReceived.addAll(chunk);
          }
          
          expect(uploadReceived.length, equals(uploadData.length));
          print('   ✅ Large upload complete: ${uploadReceived.length ~/ 1024}KB');
          
          // Send ACK back
          final ackData = Uint8List.fromList([0x41, 0x43, 0x4B]); // "ACK"
          await uploadServerStream.write(ackData);
          await uploadServerStream.closeWrite();
          
          final ackReceived = await uploadClientStream.read().timeout(Duration(seconds: 5));
          expect(ackReceived, equals(ackData));
          print('   ✅ ACK received');
          
          await uploadClientStream.close();
          await uploadServerStream.close();

          // Phase 2: Rapid small messages (50 messages of 1KB each)
          print('\n   📨 Phase 2: 50 rapid small messages (1KB each)');
          const messageCount = 50;
          const messageSize = 1024;
          var successfulMessages = 0;
          
          for (var i = 0; i < messageCount; i++) {
            try {
              // Open new stream for each message (simulating Ricochet pattern)
              final msgClientStream = await clientHost.newStream(
                serverPeerId, 
                [messageProtocolId], 
                core_context.Context(),
              ).timeout(Duration(seconds: 5));
              
              final msgServerStream = await messageStreamCompleters[i].future.timeout(Duration(seconds: 5));
              
              // Send message
              final msgData = Uint8List(messageSize);
              for (var j = 0; j < messageSize; j++) {
                msgData[j] = (i + j) % 256;
              }
              
              await msgClientStream.write(msgData);
              await msgClientStream.closeWrite();
              
              // Read on server
              final received = <int>[];
              while (true) {
                final chunk = await msgServerStream.read().timeout(Duration(seconds: 5));
                if (chunk.isEmpty) break;
                received.addAll(chunk);
              }
              
              expect(received.length, equals(messageSize));
              
              // Send ACK
              await msgServerStream.write(ackData);
              await msgServerStream.closeWrite();
              
              // Read ACK
              final msgAck = await msgClientStream.read().timeout(Duration(seconds: 5));
              expect(msgAck, equals(ackData));
              
              await msgClientStream.close();
              await msgServerStream.close();
              
              successfulMessages++;
              
              if ((i + 1) % 10 == 0) {
                print('   📨 Completed: ${i + 1}/$messageCount messages');
              }
              
            } catch (e) {
              print('   ❌ Message $i failed: $e');
              rethrow;
            }
          }
          
          print('\n   ✅ All $successfulMessages/$messageCount messages completed');
          print('   📊 Total: ${uploadData.length ~/ 1024}KB upload + ${messageCount * messageSize ~/ 1024}KB messages');

        } catch (e, stackTrace) {
          print('\n   ❌ TEST FAILED: $e');
          print('   Stack trace: $stackTrace');
          rethrow;
        } finally {
          print('\n   🧹 Cleaning up...');
          try {
            if (clientHost != null) await clientHost.close().timeout(Duration(seconds: 5));
            if (serverHost != null) await serverHost.close().timeout(Duration(seconds: 5));
          } catch (e) {
            print('   ⚠️ Cleanup error: $e');
          }
        }
      }, timeout: Timeout(Duration(minutes: 3)));

      test('should maintain connection through connection reuse pattern', () async {
        print('\n🧪 TEST STRESS-3: Connection Reuse Over Extended Period');
        print('   Goal: Test connection stability when reusing same connection for multiple operations');
        print('   Pattern: Single connection, multiple streams, varying payload sizes');
        
        BasicHost? clientHost;
        BasicHost? serverHost;
        MultiAddr? serverListenAddr;
        
        var disconnectionCount = 0;
        var reconnectionCount = 0;

        try {
          // Setup (abbreviated for this test)
          final resourceManager = ResourceManagerImpl(limiter: FixedLimiter());
          final clientConnManager = p2p_transport.ConnectionManager();
          final serverConnManager = p2p_transport.ConnectionManager();

          final yamuxMultiplexerConfig = MultiplexerConfig(
            keepAliveInterval: Duration(seconds: 10), // Shorter keepalive for testing
            maxStreamWindowSize: 2 * 1024 * 1024,
            initialStreamWindowSize: 512 * 1024,
            maxFrameSize: 4 * 1024,  // 4KB max frame - prevents HOL blocking with Noise
            streamWriteTimeout: Duration(seconds: 30),
            maxStreams: 256,
          );
          final muxerDefs = [_TestYamuxMuxerProvider(yamuxConfig: yamuxMultiplexerConfig)];

          final clientSecurity = [await NoiseSecurity.create(clientKeyPair)];
          final serverSecurity = [await NoiseSecurity.create(serverKeyPair)];

          final clientP2PConfig = p2p_config.Config()
            ..peerKey = clientKeyPair
            ..securityProtocols = clientSecurity
            ..muxers = muxerDefs
            ..connManager = clientConnManager
            ..eventBus = BasicBus();

          final serverP2PConfig = p2p_config.Config()
            ..peerKey = serverKeyPair
            ..securityProtocols = serverSecurity
            ..muxers = muxerDefs
            ..addrsFactory = passThroughAddrsFactory
            ..connManager = serverConnManager
            ..eventBus = BasicBus();
          
          final initialListenAddr = MultiAddr('/ip4/127.0.0.1/udp/0/udx');
          serverP2PConfig.listenAddrs = [initialListenAddr];

          final clientUdxTransport = UDXTransport(connManager: clientConnManager, udxInstance: udxInstance);
          final serverUdxTransport = UDXTransport(connManager: serverConnManager, udxInstance: udxInstance);

          final clientSwarm = Swarm(
            host: null,
            localPeer: clientPeerId,
            peerstore: MemoryPeerstore(),
            resourceManager: resourceManager,
            upgrader: BasicUpgrader(resourceManager: resourceManager),
            config: clientP2PConfig,
            transports: [clientUdxTransport],
          );
          
          clientSwarm.notify(TestNotifiee(
            disconnectedCallback: (_, __) => disconnectionCount++,
            connectedCallback: (_, __) => reconnectionCount++,
          ));
          
          clientHost = await BasicHost.create(network: clientSwarm, config: clientP2PConfig);
          clientSwarm.setHost(clientHost);
          await clientHost.start();

          final serverSwarm = Swarm(
            host: null,
            localPeer: serverPeerId,
            peerstore: MemoryPeerstore(),
            resourceManager: resourceManager,
            upgrader: BasicUpgrader(resourceManager: resourceManager),
            config: serverP2PConfig,
            transports: [serverUdxTransport],
          );
          serverHost = await BasicHost.create(network: serverSwarm, config: serverP2PConfig);
          serverSwarm.setHost(serverHost);

          const echoProtocolId = '/test/echo/1.0.0';
          
          serverHost.setStreamHandler(echoProtocolId, (stream, peerId) async {
            // Echo handler - read all data and echo it back
            try {
              final data = <int>[];
              while (true) {
                final chunk = await stream.read().timeout(Duration(seconds: 30));
                if (chunk.isEmpty) break;
                data.addAll(chunk);
              }
              
              // Echo back
              await stream.write(Uint8List.fromList(data));
              await stream.closeWrite();
            } catch (e) {
              print('   Echo handler error: $e');
            }
          });

          await serverSwarm.listen(serverP2PConfig.listenAddrs);
          await serverHost.start();

          serverListenAddr = serverHost.addrs.firstWhere((addr) => addr.hasProtocol(multiaddr_protocol.Protocols.udx.name));
          
          clientHost.peerStore.addrBook.addAddrs(serverPeerId, [serverListenAddr], AddressTTL.permanentAddrTTL);
          clientHost.peerStore.keyBook.addPubKey(serverPeerId, serverKeyPair.publicKey);

          // Connect once
          print('   🔗 Establishing initial connection...');
          await clientHost.connect(AddrInfo(serverPeerId, [serverListenAddr]));
          print('   ✅ Connected');
          
          // Perform varying payload operations over time
          final payloadSizes = [
            1024,        // 1KB
            100 * 1024,  // 100KB
            500 * 1024,  // 500KB
            10 * 1024,   // 10KB
            250 * 1024,  // 250KB
            50 * 1024,   // 50KB
            500 * 1024,  // 500KB again
            1024,        // 1KB
            300 * 1024,  // 300KB
            500 * 1024,  // 500KB final
          ];
          
          for (var i = 0; i < payloadSizes.length; i++) {
            final size = payloadSizes[i];
            print('\n   🔄 Operation ${i + 1}/${payloadSizes.length}: ${size ~/ 1024}KB echo');
            
            // Check connection state
            print('   📊 Connection stats: disconnections=$disconnectionCount, reconnections=$reconnectionCount');
            
            final data = Uint8List(size);
            for (var j = 0; j < size; j++) {
              data[j] = (i + j) % 256;
            }
            
            final stream = await clientHost.newStream(serverPeerId, [echoProtocolId], core_context.Context())
                .timeout(Duration(seconds: 10));
            
            // Send - using 4KB chunks to prevent Noise deadlock
            const chunkSize = 4096;
            for (var j = 0; j < data.length; j += chunkSize) {
              final end = (j + chunkSize > data.length) ? data.length : j + chunkSize;
              await stream.write(data.sublist(j, end));
            }
            await stream.closeWrite();
            
            // Read echo
            final received = <int>[];
            while (true) {
              final chunk = await stream.read().timeout(Duration(seconds: 30));
              if (chunk.isEmpty) break;
              received.addAll(chunk);
            }
            
            expect(received.length, equals(size), reason: 'Echo size mismatch for operation ${i + 1}');
            expect(Uint8List.fromList(received), equals(data), reason: 'Echo data mismatch for operation ${i + 1}');
            
            await stream.close();
            print('   ✅ Operation ${i + 1} complete');
            
            // Small delay between operations
            await Future.delayed(Duration(milliseconds: 200));
          }
          
          print('\n   ════════════════════════════════════════════════');
          print('   ✅ ALL OPERATIONS COMPLETE');
          print('   📊 Final stats: disconnections=$disconnectionCount, reconnections=$reconnectionCount');
          print('   ════════════════════════════════════════════════');
          
          // Verify connection was stable (no unexpected disconnections)
          expect(disconnectionCount, equals(0), reason: 'Should not have any disconnections during test');

        } catch (e, stackTrace) {
          print('\n   ❌ TEST FAILED: $e');
          print('   Stack trace: $stackTrace');
          print('   📊 Stats at failure: disconnections=$disconnectionCount, reconnections=$reconnectionCount');
          rethrow;
        } finally {
          print('\n   🧹 Cleaning up...');
          try {
            if (clientHost != null) await clientHost.close().timeout(Duration(seconds: 5));
            if (serverHost != null) await serverHost.close().timeout(Duration(seconds: 5));
          } catch (e) {
            print('   ⚠️ Cleanup error: $e');
          }
        }
      }, timeout: Timeout(Duration(minutes: 5)));
    });

    group('Sequential Stream Reuse Isolation Test', () {
      test('should allow sequential streams over Yamux+UDX without Noise', () async {
        print('\n🧪 TEST ISOLATION-1: Sequential Streams over Yamux+UDX (NO Noise)');
        print('   Goal: Determine if sequential stream issue is in Yamux+UDX or in Noise layer');
        print('   Hypothesis: If this passes, the bug is in Noise; if it fails, bug is in Yamux');

        UDXTransport? clientTransport;
        UDXTransport? serverTransport;
        Listener? listener;
        TransportConn? clientRawConn;
        TransportConn? serverRawConn;
        YamuxSession? clientSession;
        YamuxSession? serverSession;
        
        try {
          final resourceManager = NullResourceManager();
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
            return serverRawConn;
          });

          final clientDialFuture = clientTransport.dial(actualListenAddr).then((conn) {
            clientRawConn = conn;
            return clientRawConn;
          });

          await Future.wait([clientDialFuture, serverAcceptFuture]);
          print('   ✅ Raw UDX connections established');

          // Manually set peer details (since we're skipping security)
          (clientRawConn as dynamic).setRemotePeerDetails(serverPeerId, serverKeyPair.publicKey, 'test-no-security');
          (serverRawConn as dynamic).setRemotePeerDetails(clientPeerId, clientKeyPair.publicKey, 'test-no-security');

          // Create Yamux sessions directly
          final yamuxConfig = MultiplexerConfig(
            keepAliveInterval: Duration(seconds: 30),
            maxStreamWindowSize: 1024 * 1024,
            initialStreamWindowSize: 256 * 1024,
            streamWriteTimeout: Duration(seconds: 10),
            maxStreams: 256,
          );

          clientSession = YamuxSession(clientRawConn!, yamuxConfig, true, null);
          serverSession = YamuxSession(serverRawConn!, yamuxConfig, false, null);
          print('   ✅ Yamux sessions created');

          // Test data
          final testData = Uint8List(1024);
          for (var i = 0; i < testData.length; i++) {
            testData[i] = i % 256;
          }

          // Iteration 1: First stream
          print('\n   🔄 Iteration 1: Opening first stream');
          {
            final serverAcceptFuture = serverSession.acceptStream().timeout(Duration(seconds: 5));
            await Future.delayed(Duration(milliseconds: 50));
            final clientStream = await clientSession.openStream(core_context.Context()).timeout(Duration(seconds: 5)) as YamuxStream;
            final serverStream = await serverAcceptFuture;
            print('   ✅ Iteration 1: Streams opened (client=${clientStream.id()}, server=${serverStream.id()})');

            // Quick data transfer
            await clientStream.write(testData);
            final received = await serverStream.read().timeout(Duration(seconds: 5));
            expect(received, equals(testData));
            print('   ✅ Iteration 1: Data transfer successful');

            // Close streams
            await clientStream.close();
            await serverStream.close();
            print('   ✅ Iteration 1: Streams closed');
          }

          // Small delay
          await Future.delayed(Duration(milliseconds: 500));

          // Check session health
          print('\n   🏥 Session health check:');
          print('      - Client session closed: ${clientSession.isClosed}');
          print('      - Server session closed: ${serverSession.isClosed}');
          expect(clientSession.isClosed, isFalse, reason: 'Client session should still be open');
          expect(serverSession.isClosed, isFalse, reason: 'Server session should still be open');

          // Iteration 2: Second stream (THIS IS WHERE NOISE TESTS FAIL)
          print('\n   🔄 Iteration 2: Opening second stream on SAME Yamux session');
          print('   ⚠️  CRITICAL: This is where the Noise+UDX test fails with acceptStream timeout');
          {
            print('   Starting server acceptStream()...');
            final serverAcceptFuture = serverSession.acceptStream().timeout(
              Duration(seconds: 5),
              onTimeout: () {
                print('   ❌ SERVER ACCEPTSTREAM TIMED OUT!');
                print('   🔍 This means the stream event was lost or session is stuck');
                throw TimeoutException('Server acceptStream timed out on second stream');
              },
            );
            
            await Future.delayed(Duration(milliseconds: 50));
            
            print('   Starting client openStream()...');
            final clientStream = await (clientSession.openStream(core_context.Context()).timeout(
              Duration(seconds: 5),
              onTimeout: () {
                print('   ❌ CLIENT OPENSTREAM TIMED OUT!');
                throw TimeoutException('Client openStream timed out on second stream');
              },
            )) as YamuxStream;
            
            print('   ✅ Client stream opened: ${clientStream.id()}');
            print('   Waiting for server acceptStream...');
            
            final serverStream = await serverAcceptFuture;
            print('   ✅ Iteration 2: Streams opened (client=${clientStream.id()}, server=${serverStream.id()})');

            // Quick data transfer
            await clientStream.write(testData);
            final received = await serverStream.read().timeout(Duration(seconds: 5));
            expect(received, equals(testData));
            print('   ✅ Iteration 2: Data transfer successful');

            // Close streams
            await clientStream.close();
            await serverStream.close();
            print('   ✅ Iteration 2: Streams closed');
          }

          print('\n   ✅ ISOLATION TEST PASSED: Yamux+UDX supports sequential streams');
          print('   🔍 CONCLUSION: The bug must be in the Noise layer or how BasicUpgrader wraps Noise+Yamux');

        } catch (e, stackTrace) {
          print('\n   ❌ ISOLATION TEST FAILED: $e');
          print('   Stack trace: $stackTrace');
          
          if (e.toString().contains('acceptStream timed out')) {
            print('\n   🔍 CRITICAL FINDING: The bug is in Yamux+UDX integration, NOT Noise!');
            print('   🔍 This suggests a race condition or state management issue in YamuxSession');
            print('   🔍 when handling sequential stream establishment over real transports');
          }
          
          rethrow;
        } finally {
          print('   🧹 Cleaning up isolation test...');
          try {
            if (clientSession != null && !clientSession.isClosed) {
              await clientSession.close().timeout(Duration(seconds: 2));
            }
            if (serverSession != null && !serverSession.isClosed) {
              await serverSession.close().timeout(Duration(seconds: 2));
            }
            if (listener != null && !listener.isClosed) {
              await listener.close();
            }
            if (clientTransport != null) {
              await clientTransport.dispose();
            }
            if (serverTransport != null) {
              await serverTransport.dispose();
            }
          } catch (e) {
            print('   ⚠️ Error during isolation test cleanup: $e');
          }
        }
      }, timeout: Timeout(Duration(seconds: 30)));
    });

  });
}

// Helper function to read exact number of bytes from a stream
Future<Uint8List> _readExact(YamuxStream stream, int length) async {
  final buffer = <int>[];
  while (buffer.length < length) {
    final chunk = await stream.read().timeout(Duration(seconds: 10));
    if (chunk.isEmpty) {
      throw StateError('Stream closed before reading $length bytes (got ${buffer.length})');
    }
    buffer.addAll(chunk);
  }
  
  if (buffer.length > length) {
    // Return exact length, keep the rest in the stream (though this shouldn't happen with framed messages)
    return Uint8List.fromList(buffer.sublist(0, length));
  }
  
  return Uint8List.fromList(buffer);
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

  // Send chunks with flow control - don't get too far ahead of the echo reads
  Future.microtask(() async {
    try {
      var bytesWritten = 0;
      for (final chunk in chunks) {
        // Gentle flow control: Allow plenty of outstanding data
        // Server uses async writes, so we don't need tight flow control
        const maxOutstanding = 80 * 1024; // Allow 80KB outstanding (most of the 100KB payload)
        var flowControlWaits = 0;
        var lastReceivedCount = receivedData.length;
        
        while (bytesWritten - receivedData.length > maxOutstanding) {
          await Future.delayed(Duration(milliseconds: 5));
          flowControlWaits++;
          
          // Check if we're making progress
          if (receivedData.length > lastReceivedCount) {
            lastReceivedCount = receivedData.length;
            flowControlWaits = 0; // Reset counter if making progress
          }
          
          // Safety: If no progress for 10 seconds, something is wrong
          if (flowControlWaits > 2000) {
            print('   ⚠️ [$testContext] Flow control timeout - no echo progress. Sent: $bytesWritten, Received: ${receivedData.length}');
            throw TimeoutException('Flow control deadlock - echoes stopped arriving');
          }
          
          if (receivedData.length == 0 && bytesWritten > maxOutstanding && flowControlWaits > 100) {
            // Give initial writes time to echo back (500ms)
            print('   ⚠️ [$testContext] No echoes received yet after 500ms, continuing anyway...');
            break;
          }
        }
        
        await clientStream.write(chunk);
        bytesWritten += chunk.length;
        chunksWritten++;
        
        // Check stream health every 10 chunks
        if (chunksWritten % 10 == 0) {
          checkStreamHealth('Write chunk $chunksWritten/${chunks.length}');
          print('   📤 [$testContext] Write progress: $bytesWritten bytes sent, ${receivedData.length} bytes echoed back');
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
  String testContext) async {
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
