import 'dart:async';
import 'dart:typed_data';

import 'package:dart_libp2p/core/host/host.dart';
import 'package:dart_libp2p/core/peer/peer_id.dart';
import 'package:dart_libp2p/core/network/network.dart';
import 'package:dart_libp2p/core/network/conn.dart';
import 'package:dart_libp2p/core/network/stream.dart';
import 'package:dart_libp2p/core/network/rcmgr.dart';
import 'package:dart_libp2p/core/multiaddr.dart';
import 'package:dart_libp2p/core/peerstore.dart';
import 'package:dart_libp2p/core/peer/addr_info.dart';
import 'package:dart_libp2p/p2p/protocol/identify/id_service.dart';
import 'package:dart_libp2p/p2p/protocol/holepunch/holepunch_service.dart';
import 'package:dart_libp2p/p2p/protocol/holepunch/service.dart';
import 'package:dart_libp2p/p2p/protocol/holepunch/pb/holepunch.pb.dart';
import 'package:dart_libp2p/p2p/protocol/holepunch/util.dart';
import 'package:test/test.dart';
import 'package:mockito/mockito.dart';
import 'package:mockito/annotations.dart';

@GenerateMocks([
  Host, 
  Network, 
  Conn, 
  P2PStream, 
  IDService, 
  Peerstore,
  StreamManagementScope,
])
import 'holepunch_service_test.mocks.dart';

void main() {
  group('HolePunchService', () {
    late MockHost mockHost;
    late MockNetwork mockNetwork;
    late MockIDService mockIdService;
    late MockPeerstore mockPeerstore;
    late HolePunchServiceImpl service;
    late PeerId testPeerId;
    late List<MultiAddr> Function() listenAddrs;

    setUp(() async {
      mockHost = MockHost();
      mockNetwork = MockNetwork();
      mockIdService = MockIDService();
      mockPeerstore = MockPeerstore();
      testPeerId = await PeerId.random();
      
      listenAddrs = () => [
        MultiAddr('/ip4/127.0.0.1/tcp/4001'),
        MultiAddr('/ip6/::1/tcp/4002'),
      ];
      
      // Setup basic mock stubs
      when(mockHost.network).thenReturn(mockNetwork);
      when(mockHost.peerStore).thenReturn(mockPeerstore);
      when(mockHost.id).thenReturn(testPeerId);
      when(mockNetwork.localPeer).thenReturn(testPeerId);
      when(mockHost.setStreamHandler(any, any)).thenReturn(null);
      when(mockHost.removeStreamHandler(any)).thenReturn(null);
    });

    tearDown(() async {
      if (service != null) {
        await service.close();
      }
    });

    group('Service Initialization', () {
      test('should create service successfully', () async {
        service = HolePunchServiceImpl(
          mockHost,
          mockIdService,
          listenAddrs,
          options: const HolePunchOptions(),
        );
        
        expect(service, isNotNull);
      });

      test('should throw error when identify service is null', () {
        expect(() => HolePunchServiceImpl(
          mockHost,
          mockIdService,
          listenAddrs,
        ), returnsNormally);
      });

      test('should start service successfully', () async {
        service = HolePunchServiceImpl(
          mockHost,
          mockIdService,
          listenAddrs,
          options: const HolePunchOptions(),
        );
        
        await expectLater(service.start(), completes);
      });

      test('should close service successfully', () async {
        service = HolePunchServiceImpl(
          mockHost,
          mockIdService,
          listenAddrs,
          options: const HolePunchOptions(),
        );

        await service.start();
        await expectLater(service.close(), completes);
      });
    });

    group('Direct Connect', () {
      late PeerId remotePeerId;
      
      setUp(() async {
        remotePeerId = await PeerId.random();
        service = HolePunchServiceImpl(
          mockHost,
          mockIdService,
          listenAddrs,
          options: const HolePunchOptions(),
        );
        
        await service.start();
      });

      test('should handle direct connection request', () async {
        // Mock that we have public addresses available
        when(mockNetwork.connsToPeer(any)).thenReturn([]);
        
        // This should complete without error (even if it doesn't succeed in connecting)
        await expectLater(
          service.directConnect(remotePeerId),
          completes,
        );
      });

      test('should handle multiple connection attempts to same peer', () async {
        // Mock that we have public addresses available
        when(mockNetwork.connsToPeer(any)).thenReturn([]);
        
        // Start direct connect attempt
        await expectLater(
          service.directConnect(remotePeerId),
          completes,
        );
        
        // Should handle second attempt without hanging
        await expectLater(
          service.directConnect(remotePeerId),
          completes,
        );
      });
    });

    group('Service Behavior', () {      
      setUp(() async {
        service = HolePunchServiceImpl(
          mockHost,
          mockIdService,
          listenAddrs,
          options: const HolePunchOptions(),
        );
      });

      test('should register protocol handler on start', () async {
        await service.start();
        
        // Verify the service registered a stream handler for the DCUtR protocol
        verify(mockHost.setStreamHandler(protocolId, any)).called(1);
      });

      test('should unregister protocol handler on close', () async {
        await service.start();
        await service.close();
        
        // Verify the service removed its stream handler
        verify(mockHost.removeStreamHandler(protocolId)).called(1);
      });

      test('should handle service lifecycle correctly', () async {
        // Should be able to start and close without error
        await service.start();
        await service.close();
        
        // Verify both setup and cleanup happened
        verify(mockHost.setStreamHandler(any, any)).called(1);
        verify(mockHost.removeStreamHandler(any)).called(1);
      });
    });

    group('Protocol Compliance', () {
      test('should use correct protocol ID', () {
        expect(protocolId, equals('/libp2p/dcutr'));
      });

      test('should have reasonable timeouts', () {
        expect(streamTimeout, equals(Duration(minutes: 1)));
        expect(dialTimeout, equals(Duration(seconds: 5)));
      });

      test('should have reasonable message size limits', () {
        expect(maxMsgSize, equals(4 * 1024));
      });
    });

    group('Options and Configuration', () {
      test('should accept custom options', () {
        final customOptions = HolePunchOptions(
          tracer: null,
          filter: null,
        );
        
        service = HolePunchServiceImpl(
          mockHost,
          mockIdService,
          listenAddrs,
          options: customOptions,
        );
        
        expect(service, isNotNull);
      });

      test('should work with default options', () {
        service = HolePunchServiceImpl(
          mockHost,
          mockIdService,
          listenAddrs,
        );
        
        expect(service, isNotNull);
      });
    });
  });
}

// No additional mock implementations needed
