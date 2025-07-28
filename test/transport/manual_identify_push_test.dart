import 'dart:async';
import 'dart:typed_data';
import 'dart:convert';

import 'package:dart_libp2p/core/crypto/keys.dart';
import 'package:dart_libp2p/core/multiaddr.dart';
import 'package:dart_libp2p/core/network/conn.dart';
import 'package:dart_libp2p/core/network/context.dart';
import 'package:dart_libp2p/core/network/rcmgr.dart';
import 'package:dart_libp2p/core/network/transport_conn.dart';
import 'package:dart_libp2p/core/network/stream.dart';
import 'package:dart_libp2p/core/network/mux.dart' as core_mux;
import 'package:dart_libp2p/core/peer/peer_id.dart' as concrete_peer_id;
import 'package:dart_libp2p/core/peer/peer_id.dart';
import 'package:dart_libp2p/core/crypto/ed25519.dart' as crypto_ed25519;
import 'package:dart_libp2p/core/host/host.dart';
import 'package:dart_libp2p/core/event/bus.dart';
import 'package:dart_libp2p/core/protocol/protocol.dart';
import 'package:dart_libp2p/core/protocol/switch.dart'; // Added for ProtocolSwitch
import 'package:dart_libp2p/p2p/protocol/identify/id_service.dart';
import 'package:dart_libp2p/p2p/protocol/identify/identify.dart';
import 'package:dart_libp2p/p2p/protocol/multistream/multistream.dart';
import 'package:dart_libp2p/p2p/security/noise/noise_protocol.dart';
import 'package:dart_libp2p/p2p/transport/basic_upgrader.dart';
import 'package:dart_libp2p/p2p/transport/multiplexing/yamux/session.dart';
import 'package:dart_libp2p/p2p/transport/tcp_transport.dart';
import 'package:dart_libp2p/p2p/transport/listener.dart';
import 'package:dart_libp2p/config/config.dart' as p2p_config;
import 'package:dart_libp2p/config/stream_muxer.dart' as config_stream_muxer;
import 'package:dart_libp2p/p2p/transport/multiplexing/multiplexer.dart' as p2p_mux;
import 'package:dart_libp2p/p2p/network/connmgr/null_conn_mgr.dart';
import 'package:dart_libp2p/p2p/peerstore.dart'; // For KeyBook, AddrBook, ProtoBook, PeerMetadata
import 'package:dart_libp2p/core/peerstore.dart' as core_ps; // For core peerstore interfaces
import 'package:dart_libp2p/p2p/host/eventbus/eventbus.dart';
import 'package:mockito/annotations.dart';


import 'package:test/test.dart';
import 'package:logging/logging.dart';
import 'package:mockito/mockito.dart'; // Provides argThat, isA, any, Mock, when etc.


@GenerateMocks([
  Peerstore,
  Host,
  Conn,
  EventBus,
  PeerMetadata,
  AddrBook,
  ProtoBook,
  MultiAddr,
  ResourceManager, // Added ResourceManager
  KeyBook, // Added KeyBook
  PrivateKey, // Added PrivateKey
  MultistreamMuxer, // Added for mocking host.mux
  Emitter, // Added for mocking EventBus.emitter return
])
import 'manual_identify_push_test.mocks.dart';

void main() {
  hierarchicalLoggingEnabled = true;
  Logger.root.level = Level.INFO;
  Logger('TCPConnection').level = Level.ALL;
  Logger('SecuredConnection').level = Level.ALL;
  Logger('YamuxSession').level = Level.ALL;
  Logger('YamuxStream').level = Level.ALL;
  Logger('multistream').level = Level.ALL;
  Logger('BasicUpgrader').level = Level.ALL;
  Logger('IdentifyService').level = Level.ALL;
  Logger('test').level = Level.ALL;

  Logger.root.onRecord.listen((record) {
    print('${record.level.name}: ${record.time}: ${record.loggerName}: ${record.message}');
    if (record.error != null) {
      print('ERROR: ${record.error}');
    }
    if (record.stackTrace != null) {
      // print('STACKTRACE: \${record.stackTrace}'); // Can be verbose
    }
  });

  final testLog = Logger('test');

  group('Manual Identify Push Test', () {
    late TCPTransport clientTcpTransport;
    late TCPTransport serverTcpTransport;
    late ResourceManager resourceManager;
    late Listener serverListener;
    late MultiAddr serverListenAddr;
    
    late KeyPair clientKeyPair;
    late PeerId clientPeerId;
    late KeyPair serverKeyPair;
    late PeerId serverPeerId;

    late BasicUpgrader upgrader;
    late p2p_config.Config clientP2PConfig;
    late p2p_config.Config serverP2PConfig;

    TransportConn? rawClientConn;
    TransportConn? rawServerConn;
    core_mux.MuxedConn? clientMuxedConn; // This will be YamuxSession
    core_mux.MuxedConn? serverMuxedConn; // This will be YamuxSession

    late IdentifyService clientIdentifyService;
    late IdentifyService serverIdentifyService;

    late MockHost clientMockHost;
    late MockHost serverMockHost;

    setUp(() async {
      testLog.info('=== Test Setup Starting: Manual Identify Push ===');
      resourceManager = NullResourceManager();
      final connManager = NullConnMgr();

      clientTcpTransport = TCPTransport(resourceManager: resourceManager, connManager: connManager);
      serverTcpTransport = TCPTransport(resourceManager: resourceManager, connManager: connManager);

      clientKeyPair = await crypto_ed25519.generateEd25519KeyPair();
      clientPeerId = await concrete_peer_id.PeerId.fromPublicKey(clientKeyPair.publicKey);
      serverKeyPair = await crypto_ed25519.generateEd25519KeyPair();
      serverPeerId = await concrete_peer_id.PeerId.fromPublicKey(serverKeyPair.publicKey);

      upgrader = BasicUpgrader(resourceManager: resourceManager);

      clientP2PConfig = p2p_config.Config()
        ..peerKey = clientKeyPair
        ..securityProtocols = [await NoiseSecurity.create(clientKeyPair)]
        ..muxers = [
          config_stream_muxer.StreamMuxer(
            id: '/yamux/1.0.0', // Used string literal directly
            muxerFactory: (Conn secureConn, bool isClient) {
              final yamuxInternalConfig = p2p_mux.MultiplexerConfig();
              return YamuxSession(secureConn as TransportConn, yamuxInternalConfig, isClient);
            }
          )
        ];

      serverP2PConfig = p2p_config.Config()
        ..peerKey = serverKeyPair
        ..securityProtocols = [await NoiseSecurity.create(serverKeyPair)]
        ..muxers = [
          config_stream_muxer.StreamMuxer(
            id: '/yamux/1.0.0', // Used string literal directly
            muxerFactory: (Conn secureConn, bool isClient) {
              final yamuxInternalConfig = p2p_mux.MultiplexerConfig();
              return YamuxSession(secureConn as TransportConn, yamuxInternalConfig, isClient);
            }
          )
        ];
      
      final initialListenAddr = MultiAddr('/ip4/127.0.0.1/tcp/0');
      serverListener = await serverTcpTransport.listen(initialListenAddr);
      serverListenAddr = serverListener.addr;
      testLog.info('Server listening on: $serverListenAddr');

      final serverAcceptFuture = serverListener.accept();
      final clientDialFuture = clientTcpTransport.dial(serverListenAddr, timeout: Duration(seconds: 10));

      testLog.info('Waiting for raw TCP connection...');
      final results = await Future.wait([clientDialFuture, serverAcceptFuture]);
      rawClientConn = results[0];
      rawServerConn = results[1];
      testLog.info('Raw TCP connection established.');

      expect(rawClientConn, isNotNull);
      expect(rawServerConn, isNotNull);

      testLog.info('Upgrading connections...');
      final clientUpgradeFuture = upgrader.upgradeOutbound(
        connection: rawClientConn!,
        remotePeerId: serverPeerId,
        config: clientP2PConfig,
        remoteAddr: serverListenAddr,
      );
      final serverUpgradeFuture = upgrader.upgradeInbound(
        connection: rawServerConn!,
        config: serverP2PConfig,
      );

      final upgradedResults = await Future.wait([clientUpgradeFuture, serverUpgradeFuture]);
      // The upgrader returns a Conn, which should be an UpgradedConnectionImpl.
      // This UpgradedConnectionImpl internally holds the MuxedConn (YamuxSession).
      // We need to cast to UpgradedConnectionImpl to access the underlying muxedConn.
      final clientUpgradedConnImpl = upgradedResults[0] as UpgradedConnectionImpl;
      final serverUpgradedConnImpl = upgradedResults[1] as UpgradedConnectionImpl;

      // The UpgradedConnectionImpl itself is a MuxedConn
      clientMuxedConn = clientUpgradedConnImpl;
      serverMuxedConn = serverUpgradedConnImpl;

      testLog.info('Connections upgraded. Client Muxer: ${clientMuxedConn.runtimeType}, Server Muxer: ${serverMuxedConn.runtimeType}');
      // UpgradedConnectionImpl implements MuxedConn. The underlying muxer is YamuxSession as per config.
      expect(clientMuxedConn, isA<core_mux.MuxedConn>());
      expect(serverMuxedConn, isA<core_mux.MuxedConn>());

      // Setup Mock Hosts and IdentifyServices
      final clientKeyBook = MockKeyBook();
      when(clientKeyBook.pubKey(clientPeerId)).thenAnswer((_) async => clientKeyPair.publicKey);
      when(clientKeyBook.privKey(clientPeerId)).thenAnswer((_) async => clientKeyPair.privateKey);
      when(clientKeyBook.pubKey(serverPeerId)).thenAnswer((_) async => serverKeyPair.publicKey); // For remote peer
      // Mock the specific addPubKey calls that will be made
      when(clientKeyBook.addPubKey(serverPeerId, serverKeyPair.publicKey)).thenAnswer((_) async {});
      when(clientKeyBook.addPubKey(clientPeerId, clientKeyPair.publicKey)).thenAnswer((_) async {}); // In case it's called on clientKeyBook too
      when(clientKeyBook.peersWithKeys()).thenAnswer((_) async => <PeerId>[]);
      final clientPeerStore = MockPeerstore();
      final clientEventBus = MockEventBus();
      // final clientMux = MultistreamMuxer(); // No longer needed, will mock host.mux directly
      clientMockHost = MockHost();
      final mockClientMuxer = MockMultistreamMuxer();
      final mockClientEventBus = MockEventBus();
      when(clientMockHost.mux).thenReturn(mockClientMuxer);
      when(clientMockHost.eventBus).thenReturn(mockClientEventBus); // Added eventBus stub

      // For IdentifyService to get its own addresses and protocols
      when(clientMockHost.addrs).thenReturn([MultiAddr('/ip4/127.0.0.1/tcp/1234')]); // Dummy addr
      when(mockClientMuxer.protocols()).thenAnswer((_) => Future.value([id, idPush])); // Use direct constants, synchronous
      
      // Stub emitters for NATEmitter within IdentifyService
      // Assuming NATEmitter.create -> _initialize calls eventBus.emitter for these types
      // And that the returned Emitter's methods are not crucial for this test's identify flow.
      // If specific Emitter methods (like emit, close) are called and matter,
      // we'd need to mock Emitter and stub those methods too.
      // For now, Mockito's default SmartFake for Emitter might be enough.
      when(mockClientEventBus.emitter(any, opts: anyNamed('opts')))
          .thenAnswer((_) async => MockEmitter()); // Return a basic MockEmitter

      // Stub addHandler for IdentifyService.start()
      when(mockClientMuxer.addHandler(id, any)).thenAnswer((_) async {});
      when(mockClientMuxer.addHandler(idPush, any)).thenAnswer((_) async {});
      
      // Stub selectOneOf for client's initial identify stream
      when(mockClientMuxer.selectOneOf(any, argThat(equals([id]))))
          .thenAnswer((invocation) async {
        final stream = invocation.positionalArguments[0] as P2PStream;
        final protocols = invocation.positionalArguments[1] as List<String>; // Changed to List<String>
        if (protocols.contains(id)) {
          await stream.setProtocol(id);
          return id;
        }
        return null;
      });
      // Stub selectOneOf for client accepting server's push stream (handlePush will call selectOneOf)
      // This might be needed if handlePush internally tries to negotiate on the accepted stream.
      // For now, let's assume handlePush directly processes the stream if it's already negotiated.
      // If handlePush calls selectOneOf, we'll need to add a stub for idPush here for the client.


      final serverKeyBook = MockKeyBook();
      when(serverKeyBook.pubKey(serverPeerId)).thenAnswer((_) async => serverKeyPair.publicKey);
      when(serverKeyBook.privKey(serverPeerId)).thenAnswer((_) async => serverKeyPair.privateKey);
      when(serverKeyBook.pubKey(clientPeerId)).thenAnswer((_) async => clientKeyPair.publicKey); // For remote peer
      // Mock the specific addPubKey calls that will be made
      when(serverKeyBook.addPubKey(clientPeerId, clientKeyPair.publicKey)).thenAnswer((_) async {});
      when(serverKeyBook.addPubKey(serverPeerId, serverKeyPair.publicKey)).thenAnswer((_) async {}); // In case it's called on serverKeyBook too
      when(serverKeyBook.peersWithKeys()).thenAnswer((_) async => <PeerId>[]);
      final serverPeerStore = MockPeerstore();
      serverMockHost = MockHost();
      final mockServerMuxer = MockMultistreamMuxer();
      final mockServerEventBus = MockEventBus();
      when(serverMockHost.mux).thenReturn(mockServerMuxer);
      when(serverMockHost.eventBus).thenReturn(mockServerEventBus); // Added eventBus stub

      when(serverMockHost.addrs).thenReturn([serverListenAddr]);
      when(mockServerMuxer.protocols()).thenAnswer((_) => Future.value([id, idPush])); // Use direct constants, synchronous

      // Stub emitters for NATEmitter within IdentifyService
      when(mockServerEventBus.emitter(any, opts: anyNamed('opts')))
          .thenAnswer((_) async => MockEmitter()); // Return a basic MockEmitter

      // Stub addHandler for IdentifyService.start()
      when(mockServerMuxer.addHandler(id, any)).thenAnswer((_) async {});
      when(mockServerMuxer.addHandler(idPush, any)).thenAnswer((_) async {});

      // Stub selectOneOf for server initiating push stream
      when(mockServerMuxer.selectOneOf(any, argThat(equals([idPush]))))
          .thenAnswer((invocation) async {
        final stream = invocation.positionalArguments[0] as P2PStream;
        final protocols = invocation.positionalArguments[1] as List<String>; // Changed to List<String>
        if (protocols.contains(idPush)) {
          await stream.setProtocol(idPush);
          return idPush;
        }
        return null;
      });
      // Stub selectOneOf for server handling client's initial identify (handleIdentifyRequest)
      // This might be needed if handleIdentifyRequest internally tries to negotiate.
      // For now, let's assume handleIdentifyRequest directly processes the stream.


      clientIdentifyService = IdentifyService(clientMockHost);
      serverIdentifyService = IdentifyService(serverMockHost);
      // We need to call start for IdentifyService to initialize its internal state like snapshot
      // but we don't want it to register stream handlers on the mock host's muxer in the usual way.
      // For this test, we will manually handle stream dispatch.
      // A simplified start or direct initialization of snapshot might be needed if `start()` does too much.
      // Let's try calling start and see.
      await clientIdentifyService.start();
      await serverIdentifyService.start();


      // Store peer data in each other's peerstore for identify to work
      clientPeerStore.keyBook.addPubKey(serverPeerId, serverKeyPair.publicKey); // Removed await
      serverPeerStore.keyBook.addPubKey(clientPeerId, clientKeyPair.publicKey); // Removed await
      
      // Add supported protocols for identify to peerstores
      clientPeerStore.protoBook.addProtocols(serverPeerId, [id, idPush]); // Use direct constants, removed await
      serverPeerStore.protoBook.addProtocols(clientPeerId, [id, idPush]); // Use direct constants, removed await


      testLog.info('=== Test Setup Complete: Manual Identify Push ===');
    });

    tearDown(() async {
      testLog.info('=== Test Teardown Starting: Manual Identify Push ===');
      await clientIdentifyService.close();
      await serverIdentifyService.close();
      await clientMuxedConn?.close().catchError((e) => testLog.warning('Error closing clientMuxedConn: \$e'));
      await serverMuxedConn?.close().catchError((e) => testLog.warning('Error closing serverMuxedConn: \$e'));
      await serverListener.close().catchError((e) => testLog.warning('Error closing serverListener: \$e'));
      testLog.info('=== Test Teardown Complete: Manual Identify Push ===');
    });

    test('Manual Identify Push sequence', () async {
      testLog.info('--- Test: Manual Identify Push Sequence Starting ---');
      expect(clientMuxedConn, isNotNull);
      expect(serverMuxedConn, isNotNull);

      // Simulate initial Identify exchange (client initiates)
      testLog.info('Simulating initial Identify: Client opening stream for /ipfs/id/1.0.0');
      
      // Client opens identify stream
      final serverAcceptIdentifyFuture = serverMuxedConn!.acceptStream();
      final clientIdentifyStream = await clientMuxedConn!.openStream(Context()) as P2PStream; 
      
      // Protocol selection is now handled by the mocked clientHost.mux.selectOneOf
      // when clientIdentifyService.newStreamAndNegotiate is called (if we were using it directly)
      // or when we manually call selectOneOf on the stream.
      // For this manual test, we'll simulate the negotiation on the client side.
      final clientSelectedProtocol = await (clientIdentifyService.host.mux as MockMultistreamMuxer).selectOneOf(clientIdentifyStream, [id]);
      expect(clientSelectedProtocol, equals(id), reason: "Client should select 'id' protocol");
      await clientIdentifyStream.setProtocol(clientSelectedProtocol!); // Set it on the stream

      final serverIdentifyStream = await serverAcceptIdentifyFuture as P2PStream;
      // Server side negotiation will happen when its handleIdentifyRequest is called,
      // assuming it also uses its host.mux.selectOneOf or similar mechanism.
      // For this test, we assume the server stream is ready for the 'id' protocol.
      // If handleIdentifyRequest itself does negotiation, its mock muxer needs to be set up.
      // Let's assume the incoming stream to handleIdentifyRequest is already protocol-selected.
      await serverIdentifyStream.setProtocol(id); // Simulate server side has selected 'id'
      
      testLog.info('Client sending initial identify message...');
      // Manually trigger client to send its identify message
      // This is a bit simplified as IdentifyService.identifyWait would normally do this.
      // We're focusing on the _sendIdentifyResp and _handleIdentifyResponse parts.
      unawaited(clientIdentifyService.sendIdentifyResponse(clientIdentifyStream, false)); // isPush = false

      testLog.info('Server handling initial identify request...');
      // Manually trigger server to handle the request and send its response
      unawaited(serverIdentifyService.handleIdentifyRequest(serverIdentifyStream, clientPeerId));
      
      testLog.info('Client handling initial identify response from server...');
      // Client needs to read server's response on clientIdentifyStream
      // This would normally be handled by IdentifyService.identifyWait -> _handleIdentifyResponse
      // For simplicity, we assume this part works or skip detailed check for now.
      // Let's ensure client reads something to clear the pipe.
      try {
        final clientResponseData = await clientIdentifyStream.read(8192); // Added maxLength
        testLog.info('Client read \${clientResponseData.length} bytes of server initial identify response.');
      } catch (e) {
        testLog.warning('Error reading server initial identify on client: \$e');
      }
      
      // Ensure server also reads client's initial message
      try {
        final serverResponseData = await serverIdentifyStream.read(8192); // Added maxLength
        testLog.info('Server read \${serverResponseData.length} bytes of client initial identify message.');
      } catch (e) {
        testLog.warning('Error reading client initial identify on server: \$e');
      }

      await clientIdentifyStream.close();
      await serverIdentifyStream.close();
      testLog.info('Initial identify exchange streams closed.');
      await Future.delayed(Duration(milliseconds: 200)); // Settle

      // --- Simulate Identify Push (Server initiates) ---
      testLog.info('Simulating Identify Push: Server opening stream for /ipfs/id/push/1.0.0');
      
      final clientAcceptPushFuture = clientMuxedConn!.acceptStream();
      
      // Server's IdentifyService initiates a push.
      // We need to provide a Conn object that _newStreamAndNegotiate can use.
      // serverMuxedConn is an UpgradedConnectionImpl, which implements Conn.
      
      P2PStream? serverPushStream;
      try {
        // This internal method is what sendPush eventually calls.
        // Pass serverMuxedConn directly, as it's an UpgradedConnectionImpl which is a Conn.
        serverPushStream = await serverIdentifyService.newStreamAndNegotiate(serverMuxedConn! as Conn, idPush); // Use direct constant
        expect(serverPushStream, isNotNull, reason: "Server should be able to open a push stream.");
        testLog.info('Server opened push stream: \${serverPushStream!.id()}');

        // Server sends its identify message on the push stream
        unawaited(serverIdentifyService.sendIdentifyResponse(serverPushStream!, true)); // isPush = true
        testLog.info('Server sent identify push message.');

      } catch (e, s) {
        testLog.severe('Error during server initiating identify push: \$e', e, s);
        fail('Server failed to initiate identify push: \$e');
      }

      // Client accepts the push stream
      final clientPushStream = await clientAcceptPushFuture.timeout(Duration(seconds: 5));
      expect(clientPushStream, isNotNull, reason: "Client should accept the push stream.");
      testLog.info('Client accepted push stream: \${(clientPushStream as YamuxStream).id()}');
      
      // Client handles the push (reads server's message, sends its own back)
      // This will call _handleIdentifyResponse internally, which then calls _consumeMessage
      // and then sends back its own identify data.
      testLog.info('Client handling identify push from server...');
      unawaited(clientIdentifyService.handlePush(clientPushStream as P2PStream, serverPeerId)); // Cast to P2PStream

      // Server reads client's response on the push stream
      // This is where the decryption error happens in the original test.
      testLog.info('Server attempting to read client response on push stream...');
      try {
        // The _handleIdentifyResponse in the server's push logic would do this.
        // Since we called _sendIdentifyResp directly, we need to simulate the read part of _handleIdentifyResponse.
        // The actual _handleIdentifyResponse is for INCOMING identify/push, not for reading response to an OUTGOING push.
        // The response to an outgoing push is handled by the caller of _newStreamAndNegotiate if it expects a response.
        // In our case, the server's IdentifyService doesn't explicitly wait for a response on a push stream it initiated.
        // The client's handlePush sends a response. Let's try to read it on the serverPushStream.
        if (serverPushStream != null) {
          final clientResponseBytes = await serverPushStream.read(8192); // Added maxLength. This is where it might fail
          testLog.info('Server successfully read \${clientResponseBytes.length} bytes of client response on push stream.');
          // Further validation of clientResponseBytes could be added here.
        } else {
          fail('Server push stream was null, cannot read client response.');
        }
      } catch (e, s) {
        testLog.severe('MAC ERROR OR OTHER FAILURE: Server failed to read/decrypt client response on push stream: \$e', e, s);
        fail('Server failed to read/decrypt client response on push stream: \$e');
      } finally {
        await clientPushStream.close().catchError((e) => testLog.warning('Error closing clientPushStream: \$e'));
        await serverPushStream?.close().catchError((e) => testLog.warning('Error closing serverPushStream: \$e'));
      }

      testLog.info('--- Test: Manual Identify Push Sequence Complete ---');
    }, timeout: Timeout(Duration(seconds: 20))); // Increased timeout for more complex interaction
  });
}

// Helper to allow IdentifyService to use a specific MuxedConn for its operations
extension IdentifyServiceTestHelpers on IdentifyService {
  Future<P2PStream?> newStreamAndNegotiate(Conn conn, String protocol) async {
    // This is a simplified version of the internal _newStreamAndNegotiate,
    // using the provided Conn object directly.
    // The `conn` passed here should be our MockConnForPush.
    final P2PStream stream = await conn.newStream(Context()); // streamId 0 is arbitrary for this direct call
    
    // Use the host's muxer (which we mocked) to select the protocol on this new stream
    // The host.mux is now a MockMultistreamMuxer
    final selectedProtocol = await (host.mux as MockMultistreamMuxer).selectOneOf(stream, [protocol]);
    if (selectedProtocol == null) {
      await stream.reset();
      return null;
    }
    await stream.setProtocol(selectedProtocol);
    return stream;
  }

  // Helper to call the protected _sendIdentifyResp method
  Future<void> sendIdentifyResponse(P2PStream stream, bool isPush) async {
    // This directly calls the method that was named _sendIdentifyResp
    // It might need access to _currentSnapshot or other internal state.
    // For this test, we assume _currentSnapshot is populated by start().
    await this.sendIdentifyResp(stream, isPush); // Use public method
  }
  
  // Helper to call the protected _handleIdentifyRequest method
  Future<void> handleIdentifyRequest(P2PStream stream, PeerId peerId) async {
    await this.handleIdentifyRequest(stream, peerId); // Use public method
  }

  // Helper to call the protected _handlePush method
  Future<void> handlePush(P2PStream stream, PeerId peerId) async {
    await this.handlePush(stream, peerId); // Use public method
  }
}
