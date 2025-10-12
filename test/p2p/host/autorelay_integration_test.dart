import 'dart:async';

import 'package:dart_libp2p/core/peer/peer_id.dart';
import 'package:dart_libp2p/core/host/host.dart';
import 'package:dart_libp2p/core/network/network.dart'; // For Reachability
import 'package:dart_libp2p/p2p/host/autorelay/autorelay.dart'; // For EvtAutoRelayAddrsUpdated
import 'package:dart_libp2p/p2p/host/autonat/ambient_config.dart'; // For AmbientAutoNATv2Config
import 'package:dart_libp2p/p2p/protocol/ping/ping.dart';
import 'package:dart_libp2p/p2p/multiaddr/protocol.dart'; // For Protocols
import 'package:dart_libp2p/core/network/rcmgr.dart';
import 'package:dart_libp2p/p2p/transport/connection_manager.dart' as p2p_conn_mgr;
import 'package:dart_libp2p/p2p/host/eventbus/basic.dart' as p2p_event_bus;
import 'package:dart_udx/dart_udx.dart';
import 'package:logging/logging.dart';
import 'package:test/test.dart';

import '../../real_net_stack.dart';

void main() {
  Logger.root.level = Level.FINE; // Enable more detailed logging
  Logger.root.onRecord.listen((record) {
    // Show logs from AutoRelay, RelayFinder, BasicHost, RelayManager, AutoNAT
    if (record.loggerName.contains('AutoRelay') ||
        record.loggerName.contains('RelayFinder') ||
        record.loggerName.contains('BasicHost') ||
        record.loggerName.contains('RelayManager') ||
        record.loggerName.contains('ambient_autonat_v2') ||
        record.loggerName.contains('identify') ||
        record.loggerName.contains('autonatv2'))
    {
      print('${record.level.name}: ${record.time}: ${record.loggerName}: ${record.message}');
    }
  });

  group('AutoRelay Integration', () {
    late Libp2pNode relayNode;
    late Libp2pNode peerANode;
    late Libp2pNode peerBNode;
    late Host relayHost;
    late Host peerAHost;
    late Host peerBHost;
    late PeerId relayPeerId;
    late PeerId peerAPeerId;
    late PeerId peerBPeerId;
    late UDX udx;
    StreamSubscription? autoRelaySubA;
    StreamSubscription? autoRelaySubB;

    setUp(() async {
      udx = UDX();
      final resourceManager = NullResourceManager();
      final connManager = p2p_conn_mgr.ConnectionManager();

      print('\n=== Setting up test nodes ===');

      // Create relay server with forced public reachability
      print('Creating relay server...');
      final relayEventBus = p2p_event_bus.BasicBus();
      relayNode = await createLibp2pNode(
        udxInstance: udx,
        resourceManager: resourceManager,
        connManager: connManager,
        hostEventBus: relayEventBus,
        enableRelay: true,
        enablePing: true,
        userAgentPrefix: 'relay-server',
        forceReachability: Reachability.public, // Force public to start relay service
      );
      relayHost = relayNode.host;
      relayPeerId = relayNode.peerId;
      print('Relay server created: ${relayPeerId.toBase58()}');
      print('Relay addresses: ${relayHost.addrs}');
      
      await Future.delayed(Duration(milliseconds: 500)); // Give it time to start
      print('Relay service should now be active (via forceReachability)');

      // Build relay server addresses for auto-connect configuration
      // Filter to get only direct (non-circuit) addresses
      final relayDirectAddrs = relayHost.addrs
          .where((addr) => !addr.toString().contains('/p2p-circuit'))
          .toList();
      
      // Construct full relay addresses with peer ID
      final relayServerAddrs = relayDirectAddrs.map((addr) {
        return '${addr.toString()}/p2p/${relayPeerId.toBase58()}';
      }).toList();
      
      print('Relay server addresses for auto-connect: $relayServerAddrs');

      // Create peer A with its own event bus, fast AutoNAT config, and relay auto-connect
      print('\nCreating peer A...');
      final peerAEventBus = p2p_event_bus.BasicBus();
      final autoNATConfig = AmbientAutoNATv2Config(
        bootDelay: Duration(milliseconds: 500), // Fast boot for testing
        retryInterval: Duration(seconds: 1),
        refreshInterval: Duration(seconds: 5),
      );
      peerANode = await createLibp2pNode(
        udxInstance: udx,
        resourceManager: resourceManager,
        connManager: connManager,
        hostEventBus: peerAEventBus,
        enableAutoRelay: true,
        enablePing: true,
        userAgentPrefix: 'peer-a',
        ambientAutoNATConfig: autoNATConfig,
        relayServers: relayServerAddrs, // Auto-connect to relay servers
      );
      peerAHost = peerANode.host;
      peerAPeerId = peerANode.peerId;
      print('Peer A created: ${peerAPeerId.toBase58()}');
      print('Peer A addresses: ${peerAHost.addrs}');
      print('✅ Peer A configured to auto-connect to ${relayServerAddrs.length} relay servers');

      // Create peer B with its own event bus, fast AutoNAT config, and relay auto-connect
      print('\nCreating peer B...');
      final peerBEventBus = p2p_event_bus.BasicBus();
      peerBNode = await createLibp2pNode(
        udxInstance: udx,
        resourceManager: resourceManager,
        connManager: connManager,
        hostEventBus: peerBEventBus,
        enableAutoRelay: true,
        enablePing: true,
        userAgentPrefix: 'peer-b',
        ambientAutoNATConfig: autoNATConfig, // Use same config as peer A
        relayServers: relayServerAddrs, // Auto-connect to relay servers
      );
      peerBHost = peerBNode.host;
      peerBPeerId = peerBNode.peerId;
      print('Peer B created: ${peerBPeerId.toBase58()}');
      print('Peer B addresses: ${peerBHost.addrs}');
      print('✅ Peer B configured to auto-connect to ${relayServerAddrs.length} relay servers');

      print('\n=== Test: Circuit Relay Advertisement and Ping ===');

      // Subscribe to AutoRelay events for debugging - use each peer's own event bus
      final autoRelaySubASub = peerAHost.eventBus.subscribe(EvtAutoRelayAddrsUpdated);
      autoRelaySubA = autoRelaySubASub.stream.listen((event) {
        if (event is EvtAutoRelayAddrsUpdated) {
          print('🔄 Peer A AutoRelay addresses updated (${event.advertisableAddrs.length}):');
          for (var addr in event.advertisableAddrs) {
            print('   - $addr');
            print('     Is circuit: ${addr.toString().contains('/p2p-circuit')}');
          }
        }
      });

      final autoRelaySubBSub = peerBHost.eventBus.subscribe(EvtAutoRelayAddrsUpdated);
      autoRelaySubB = autoRelaySubBSub.stream.listen((event) {
        if (event is EvtAutoRelayAddrsUpdated) {
          print('🔄 Peer B AutoRelay addresses updated (${event.advertisableAddrs.length}):');
          for (var addr in event.advertisableAddrs) {
            print('   - $addr');
            print('     Is circuit: ${addr.toString().contains('/p2p-circuit')}');
          }
        }
      });
    });

    tearDown(() async {
      print('\n=== Tearing down test nodes ===');
      await autoRelaySubA?.cancel();
      await autoRelaySubB?.cancel();
      
      print('Closing hosts...');
      // await peerAHost.close();
      // await peerBHost.close();
      // await relayHost.close();
      // print('Hosts closed');

      // Give connections a moment to finish closing, but don't wait too long
      await Future.delayed(Duration(milliseconds: 500));
      print('✅ Teardown complete');
    });

    test('Peers advertise circuit relay addresses and can ping through relay', () async {
      // Step 1: Verify auto-connection to relay server
      // NOTE: Peers should already be connected to relay via Config.relayServers during host.start()
      print('\n📡 Step 1: Verifying auto-connection to relay server...');
      
      // Verify connections established automatically
      expect(peerAHost.network.connectedness(relayPeerId).name, equals('connected'));
      expect(peerBHost.network.connectedness(relayPeerId).name, equals('connected'));
      print('✅ Both peers automatically connected to relay server via Config.relayServers');
      
      // Step 1b: AutoNAT will automatically detect reachability after connections are established
      // No manual event emission needed - AmbientAutoNATv2 handles this automatically
      print('\n🔧 Waiting for AutoNAT to detect reachability and trigger AutoRelay...');
      // Give AutoNAT time to probe and determine reachability
      // bootDelay=500ms + probe time + AutoRelay processing
      await Future.delayed(Duration(seconds: 2));
      print('✅ AutoNAT should have detected reachability by now');
      
      // Debug: Check what protocols the relay server advertises
      print('\n🔍 Debug: Checking relay server protocols...');
      final relayProtocols = await peerAHost.peerStore.protoBook.getProtocols(relayPeerId);
      print('Relay server protocols: $relayProtocols');
      final hasCircuitV2 = relayProtocols.any((p) => p.contains('circuit') || p.contains('libp2p/circuit'));
      print('Has circuit relay protocol: $hasCircuitV2');
      
      // Debug: Check connected peers from Peer A's perspective
      print('\n🔍 Debug: Checking Peer A\'s connected peers...');
      final peerAConnectedPeers = peerAHost.network.peers;
      print('Peer A connected peers: ${peerAConnectedPeers.length}');
      for (final peerId in peerAConnectedPeers) {
        print('  - ${peerId.toBase58()}');
      }

      // Step 2: Wait for AutoRelay to discover relay and reserve slot
      print('\n⏳ Step 2: Waiting for AutoRelay to discover relay (bootDelay=5s + processing)...');
      await Future.delayed(Duration(seconds: 12));
      
      // Step 3: Verify peers advertise circuit addresses
      print('\n🔍 Step 3: Verifying circuit relay addresses...');
      final peerAAddrs = peerAHost.addrs;
      final peerBAddrs = peerBHost.addrs;
      
      print('Peer A addresses: $peerAAddrs');
      print('Peer B addresses: $peerBAddrs');
      
      // Check for circuit addresses containing relay peer ID
      final peerACircuitAddrs = peerAAddrs.where((addr) {
        final addrStr = addr.toString();
        return addrStr.contains('/p2p-circuit') && addrStr.contains(relayPeerId.toBase58());
      }).toList();
      
      final peerBBaseCircuitAddrs = peerBAddrs.where((addr) {
        final addrStr = addr.toString();
        return addrStr.contains('/p2p-circuit') && addrStr.contains(relayPeerId.toBase58());
      }).toList();
      
      print('Peer A circuit addresses: $peerACircuitAddrs');
      print('Peer B base circuit addresses: $peerBBaseCircuitAddrs');
      
      expect(peerACircuitAddrs, isNotEmpty, 
        reason: 'Peer A should advertise at least one circuit relay address through relay ${relayPeerId.toBase58()}');
      expect(peerBBaseCircuitAddrs, isNotEmpty,
        reason: 'Peer B should advertise at least one circuit relay address through relay ${relayPeerId.toBase58()}');
      
      print('✅ Both peers advertise circuit relay addresses');

      // Step 3.5: Verify relay server's peerstore was updated via Identify Push
      print('\n🔍 Step 3.5: Verifying relay server\'s peerstore has peers\' circuit addresses...');
      
      // Check relay's peerstore for peer A's addresses
      final relayKnownPeerAAddrs = await relayHost.peerStore.addrBook.addrs(peerAPeerId);
      print('Relay server knows ${relayKnownPeerAAddrs.length} addresses for Peer A:');
      for (var addr in relayKnownPeerAAddrs) {
        print('   - $addr');
      }
      
      // Check relay's peerstore for peer B's addresses
      final relayKnownPeerBAddrs = await relayHost.peerStore.addrBook.addrs(peerBPeerId);
      print('Relay server knows ${relayKnownPeerBAddrs.length} addresses for Peer B:');
      for (var addr in relayKnownPeerBAddrs) {
        print('   - $addr');
      }
      
      // Filter for circuit addresses
      final relayKnownPeerACircuitAddrs = relayKnownPeerAAddrs.where((addr) {
        return addr.toString().contains('/p2p-circuit');
      }).toList();
      
      final relayKnownPeerBCircuitAddrs = relayKnownPeerBAddrs.where((addr) {
        return addr.toString().contains('/p2p-circuit');
      }).toList();
      
      print('Relay knows ${relayKnownPeerACircuitAddrs.length} circuit addresses for Peer A');
      print('Relay knows ${relayKnownPeerBCircuitAddrs.length} circuit addresses for Peer B');
      
      // Verify relay server received circuit addresses via Identify Push
      expect(relayKnownPeerACircuitAddrs, isNotEmpty,
        reason: 'Relay server should have received Peer A\'s circuit addresses via Identify Push');
      expect(relayKnownPeerBCircuitAddrs, isNotEmpty,
        reason: 'Relay server should have received Peer B\'s circuit addresses via Identify Push');
      
      print('✅ Relay server\'s peerstore correctly updated with both peers\' circuit addresses');

      // Step 4: Construct full dialable circuit addresses for peer B
      // AutoRelay advertises: /ip4/X.X.X.X/udp/PORT/udx/p2p/RELAY_ID/p2p-circuit
      // We need to dial:      /ip4/X.X.X.X/udp/PORT/udx/p2p/RELAY_ID/p2p-circuit/p2p/DEST_PEER_ID
      print('\n📋 Step 4: Constructing dialable circuit addresses for peer B...');
      final peerBDialableCircuitAddrs = peerBBaseCircuitAddrs.map((addr) {
        // Append destination peer ID to make it dialable
        return addr.encapsulate(Protocols.p2p.name, peerBPeerId.toString());
      }).toList();
      
      print('Peer B dialable circuit addresses: $peerBDialableCircuitAddrs');
      
      // Debug: Check what addresses peer A already knows about peer B (if any)
      // NOTE: Peer A and Peer B have NOT connected to each other yet, only to the relay server.
      // Identify runs when peers connect, so peer A shouldn't know peer B's addresses yet
      // unless there's automatic discovery through the relay.
      print('\n🔍 Debug: Checking peer A\'s peerstore for peer B BEFORE manual add...');
      final existingPeerBAddrs = await peerAHost.peerStore.addrBook.addrs(peerBPeerId);
      print('Existing addresses for peer B in peer A\'s peerstore: ${existingPeerBAddrs.length}');
      if (existingPeerBAddrs.isEmpty) {
        print('   → Empty (as expected - peers haven\'t connected to each other yet)');
      } else {
        for (var addr in existingPeerBAddrs) {
          print('   - $addr');
          final hasCircuit = addr.toString().contains('/p2p-circuit');
          print('     Is circuit: $hasCircuit');
        }
      }
      
      // Add ONLY dialable circuit addresses to peer A's peerstore
      // This forces peer A to dial peer B via circuit relay
      await peerAHost.peerStore.addrBook.clearAddrs(peerBPeerId);
      await peerAHost.peerStore.addrBook.addAddrs(
        peerBPeerId,
        peerBDialableCircuitAddrs,  // Full circuit addresses with destination peer ID
        Duration(hours: 1),
      );
      print('✅ Peer B dialable circuit addresses added to peer A peerstore (${peerBDialableCircuitAddrs.length} addresses)');

      // Verify peerstore was properly updated with circuit addresses
      print('\n🔍 Verifying peerstore contains circuit addresses...');
      final storedAddrs = await peerAHost.peerStore.addrBook.addrs(peerBPeerId);
      print('Stored addresses for peer B in peer A\'s peerstore: ${storedAddrs.length}');
      for (var addr in storedAddrs) {
        print('   - $addr');
      }
      
      final storedCircuitAddrs = storedAddrs.where((addr) {
        final addrStr = addr.toString();
        return addrStr.contains('/p2p-circuit') && 
               addrStr.contains(relayPeerId.toBase58()) &&
               addrStr.contains(peerBPeerId.toBase58());
      }).toList();
      
      expect(storedCircuitAddrs.length, equals(peerBDialableCircuitAddrs.length),
        reason: 'Peerstore should contain exactly ${peerBDialableCircuitAddrs.length} circuit addresses');
      expect(storedCircuitAddrs, isNotEmpty,
        reason: 'Peerstore must contain circuit relay addresses for peer B');
      
      print('✅ Peerstore verified: ${storedCircuitAddrs.length} circuit addresses stored correctly');

      // Step 5: Ping peer B from peer A via circuit relay
      print('\n🏓 Step 5: Pinging peer B from peer A via circuit relay...');
      final pingService = PingService(peerAHost);
      
      try {
        final pingResult = await pingService.ping(peerBPeerId).first.timeout(
          Duration(seconds: 15),
          onTimeout: () {
            throw TimeoutException('Ping timed out after 15 seconds');
          },
        );
        
        print('Ping result: error=${pingResult.hasError}, rtt=${pingResult.rtt?.inMilliseconds}ms');
        
        expect(pingResult.hasError, isFalse,
          reason: 'Ping should succeed through circuit relay');
        expect(pingResult.rtt, isNotNull,
          reason: 'Ping should return a valid RTT');
        
        print('✅ Ping succeeded! RTT: ${pingResult.rtt?.inMilliseconds}ms');
        
        // Verify the connection is using circuit relay
        final conns = peerAHost.network.connsToPeer(peerBPeerId);
        expect(conns, isNotEmpty, 
          reason: 'Should have at least one connection to peer B');
        
        final connAddr = conns.first.remoteMultiaddr.toString();
        print('Connection address: $connAddr');
        
        expect(connAddr.contains('/p2p-circuit'), isTrue,
          reason: 'Connection MUST be using circuit relay (address should contain /p2p-circuit). '
                  'Got: $connAddr');
        print('✅ Verified: Connection is using circuit relay');
      } catch (e, stackTrace) {
        print('❌ Ping failed: $e');
        print('Stack trace: $stackTrace');
        rethrow;
      }
      
      print('\n✅ Test completed successfully!');
    }, timeout: Timeout(Duration(seconds: 30))); // Increased timeout for teardown
  });
}
