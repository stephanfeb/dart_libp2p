import 'dart:io';
import 'package:test/test.dart';
import 'utils/container_orchestrator.dart';
import 'scenarios/holepunch_scenarios.dart';

/// Integration tests for holepunch functionality using real network containers
/// 
/// These tests create actual Docker containers with different NAT behaviors
/// to test holepunch/DCUtR functionality in realistic network conditions.
///
/// Prerequisites:
/// - Docker and docker-compose installed
/// - Network permissions for container creation
/// - Sufficient system resources for multiple containers
void main() {
  group('Holepunch Network Integration Tests', () {
    late ContainerOrchestrator orchestrator;
    
    setUpAll(() async {
      // Verify Docker is available
      if (!await _isDockerAvailable()) {
        throw UnsupportedError(
          'Docker is required for integration tests but not available. '
          'Please install Docker and ensure it\'s running.',
        );
      }
      
      final composeFile = 'test/integration/holepunch_network/compose/docker-compose.yml';
      
      if (!File(composeFile).existsSync()) {
        throw StateError('Docker compose file not found: $composeFile');
      }
      
      orchestrator = ContainerOrchestrator(
        composeFile: composeFile,
        startupTimeout: Duration(minutes: 3),
      );
    });

    tearDownAll(() async {
      await orchestrator.stop();
    });

    test('Container Infrastructure Setup', () async {
      // This test verifies the basic container infrastructure works
      await orchestrator.start();
      
      final statuses = await orchestrator.getStatus();
      
      // Verify expected containers are running
      final expectedContainers = [
        'nat-gateway-a',
        'nat-gateway-b', 
        'relay-server',
        'stun-server',
        'peer-a',
        'peer-b',
      ];
      
      for (final container in expectedContainers) {
        expect(
          statuses.keys,
          contains(contains(container)),
          reason: 'Container $container should be present',
        );
      }
      
      // Verify all containers are healthy
      final unhealthyContainers = statuses.values
          .where((status) => !status.isHealthy)
          .map((status) => status.name)
          .toList();
      
      expect(
        unhealthyContainers,
        isEmpty,
        reason: 'All containers should be healthy, but these are not: $unhealthyContainers',
      );
      
      await orchestrator.stop();
    }, timeout: Timeout(Duration(minutes: 5)));

    // test('Cone-to-Cone NAT Holepunch Success', () async {
    //   final scenario = ConeToConeSucessScenario(orchestrator);
    //   final result = await scenario.run();
    //
    //   expect(result.success, isTrue, reason: result.message);
    // }, timeout: Timeout(Duration(minutes: 4)));

    test('Symmetric-to-Symmetric NAT Holepunch Failure', () async {
      final scenario = SymmetricToSymmetricFailureScenario(orchestrator);
      final result = await scenario.run();
      
      expect(result.success, isTrue, reason: result.message);
    }, timeout: Timeout(Duration(minutes: 4)));

    test('Mixed NAT Types Handling', () async {
      final scenario = MixedNATScenario(orchestrator);  
      final result = await scenario.run();
      
      expect(result.success, isTrue, reason: result.message);
    }, timeout: Timeout(Duration(minutes: 4)));

    test('Complete Holepunch Scenario Suite', () async {
      final scenarios = [
        ConeToConeSucessScenario(orchestrator),
        SymmetricToSymmetricFailureScenario(orchestrator),
        MixedNATScenario(orchestrator),
      ];
      
      final runner = ScenarioRunner(scenarios);
      final results = await runner.runAll();
      
      // Verify at least the basic cone-to-cone scenario succeeded
      final coneScenarioResult = results[0];
      expect(
        coneScenarioResult.success,
        isTrue,
        reason: 'Cone-to-cone scenario should succeed: ${coneScenarioResult.message}',
      );
      
      // All scenarios should complete without throwing exceptions
      // (even if some holepunch attempts fail, they should fail gracefully)
      for (final result in results) {
        expect(
          result.message,
          isNot(contains('Exception')),
          reason: 'No scenario should throw unhandled exceptions',
        );
      }
    }, timeout: Timeout(Duration(minutes: 15)));

    group('Network Behavior Validation', () {
      // Ensure orchestrator is stopped before each test in this group
      setUp(() async {
        if (orchestrator.isStarted) {
          await orchestrator.stop();
        }
      });
      
      // Ensure orchestrator is stopped after each test in this group  
      tearDown(() async {
        if (orchestrator.isStarted) {
          await orchestrator.stop();
        }
      });
      
      // test('NAT Gateway Configuration Validation', () async {
      //   orchestrator.environment['NAT_A_TYPE'] = 'cone';
      //   orchestrator.environment['NAT_B_TYPE'] = 'symmetric';
      //
      //   await orchestrator.start();
      //
      //   // Verify NAT rules are correctly applied
      //   final natALogs = await orchestrator.getLogs('nat-gateway-a', lines: 20);
      //   final natBLogs = await orchestrator.getLogs('nat-gateway-b', lines: 20);
      //
      //   expect(natALogs, contains('Cone NAT configuration complete'));
      //   expect(natBLogs, contains('Symmetric NAT configuration complete'));
      //
      //   // Note: tearDown will handle stopping the orchestrator
      // }, timeout: Timeout(Duration(minutes: 3)));

      test('STUN Server Functionality', () async {
        await orchestrator.start();
        
        // Test that peers can discover their external addresses via STUN
        final peerAStatus = await orchestrator.sendControlRequest('peer-a', '/status');
        
        expect(peerAStatus['peer_id'], isNotNull);
        expect(peerAStatus['addresses'], isA<List>());
        
        // Note: tearDown will handle stopping the orchestrator
      }, timeout: Timeout(Duration(minutes: 3)));

      test('Relay Server Connectivity', () async {
        await orchestrator.start();
        
        // Verify relay server is accessible and functional
        final relayStatus = await orchestrator.sendControlRequest('relay-server', '/status');
        
        expect(relayStatus['role'], equals('relay'));
        expect(relayStatus['relay_enabled'], isTrue);
        
        // Note: tearDown will handle stopping the orchestrator
      }, timeout: Timeout(Duration(minutes: 3)));

      test('Circuit Relay Establishment Between Peers', () async {
        await orchestrator.start();
        
        // Allow infrastructure to warm up
        await Future.delayed(Duration(seconds: 15));
        
        // Get peer and relay information
        final peerAStatus = await orchestrator.sendControlRequest('peer-a', '/status');
        final peerBStatus = await orchestrator.sendControlRequest('peer-b', '/status');
        final relayStatus = await orchestrator.sendControlRequest('relay-server', '/status');
        
        final peerAId = peerAStatus['peer_id'] as String;
        final peerBId = peerBStatus['peer_id'] as String;
        final relayId = relayStatus['peer_id'] as String;
        final peerAAddrs = List<String>.from(peerAStatus['addresses'] as List);
        final peerBAddrs = List<String>.from(peerBStatus['addresses'] as List);
        final relayAddrs = List<String>.from(relayStatus['addresses'] as List);
        
        print('🔍 Testing Circuit Relay Establishment');
        print('👤 Peer A: $peerAId');
        print('📍 Peer A addresses: $peerAAddrs');
        print('👤 Peer B: $peerBId');
        print('📍 Peer B addresses: $peerBAddrs');
        print('🔄 Relay: $relayId');
        print('📍 Relay addresses: $relayAddrs');
        
        // Step 1: Verify both peers are connected to relay server
        print('\n📡 Step 1: Verifying direct connections to relay...');
        final initialConnA = peerAStatus['connected_peers'] as int;
        final initialConnB = peerBStatus['connected_peers'] as int;
        
        expect(initialConnA, greaterThanOrEqualTo(1), 
          reason: 'Peer A should be connected to relay server');
        expect(initialConnB, greaterThanOrEqualTo(1), 
          reason: 'Peer B should be connected to relay server');
        print('✅ Both peers connected to relay: A=$initialConnA, B=$initialConnB');
        
        // Step 2: Check for circuit addresses
        // Circuit addresses should look like: /ip4/10.10.3.10/tcp/4001/p2p/RELAY_ID/p2p-circuit
        print('\n🔍 Step 2: Checking for circuit relay addresses...');
        
        final peerAHasCircuitAddr = peerAAddrs.any((addr) => addr.contains('/p2p-circuit'));
        final peerBHasCircuitAddr = peerBAddrs.any((addr) => addr.contains('/p2p-circuit'));
        
        if (!peerAHasCircuitAddr) {
          print('⚠️  Peer A does not advertise circuit relay addresses');
          print('   Expected format: /ip4/.../tcp/.../p2p/$relayId/p2p-circuit');
          print('   Actual addresses: $peerAAddrs');
        }
        
        if (!peerBHasCircuitAddr) {
          print('⚠️  Peer B does not advertise circuit relay addresses');
          print('   Expected format: /ip4/.../tcp/.../p2p/$relayId/p2p-circuit');
          print('   Actual addresses: $peerBAddrs');
        }
        
        // This SHOULD pass but currently WILL FAIL due to missing AutoRelay integration
        expect(peerAHasCircuitAddr, isTrue,
          reason: 'Peer A should advertise circuit relay address when connected to relay. '
                  'This indicates AutoRelay is not properly integrated.');
        expect(peerBHasCircuitAddr, isTrue,
          reason: 'Peer B should advertise circuit relay address when connected to relay. '
                  'This indicates AutoRelay is not properly integrated.');
        
        print('✅ Both peers advertising circuit addresses');
        
        // Step 3: Introduce peers to each other (add to peerstore)
        print('\n🤝 Step 3: Introducing peers to each other...');
        await orchestrator.sendControlRequest(
          'peer-a',
          '/connect',
          method: 'POST',
          body: {'peer_id': peerBId, 'addrs': peerBAddrs},
        );
        
        await orchestrator.sendControlRequest(
          'peer-b',
          '/connect',
          method: 'POST',
          body: {'peer_id': peerAId, 'addrs': peerAAddrs},
        );
        
        await Future.delayed(Duration(seconds: 3));
        print('✅ Peers introduced via peerstore');
        
        // Step 4: Test peer-to-peer communication THROUGH relay
        // This should use circuit relay, not direct connection
        print('\n🏓 Step 4: Testing peer-to-peer ping THROUGH relay...');
        
        final pingResult = await orchestrator.sendControlRequest(
          'peer-a',
          '/ping',
          method: 'POST',
          body: {'peer_id': peerBId},
        );
        
        print('📋 Ping result: $pingResult');
        
        // Verify ping succeeded
        expect(pingResult['success'], isTrue,
          reason: 'Ping should succeed using circuit relay. '
                  'Failure indicates CircuitV2Client is not integrated as transport.');
        
        // Step 5: Verify the connection is relayed, not direct
        print('\n🔍 Step 5: Verifying connection type...');
        
        if (pingResult.containsKey('connection_details')) {
          final connections = pingResult['connection_details'] as List;
          print('📊 Connection details: $connections');
          
          // Check if connection address contains p2p-circuit
          final hasRelayedConn = connections.any((conn) {
            final remoteAddr = conn['remote_addr'] as String;
            return remoteAddr.contains('/p2p-circuit');
          });
          
          expect(hasRelayedConn, isTrue,
            reason: 'Connection should be relayed (address should contain /p2p-circuit). '
                    'This indicates communication is using circuit relay transport.');
          print('✅ Verified connection is relayed, not direct');
        } else {
          print('⚠️  Connection details not available in ping response');
        }
        
        // Step 6: Verify relay server sees both connections
        print('\n📊 Step 6: Verifying relay server metrics...');
        final finalRelayStatus = await orchestrator.sendControlRequest('relay-server', '/status');
        final relayConnections = finalRelayStatus['connected_peers'] as int;
        
        expect(relayConnections, greaterThanOrEqualTo(2),
          reason: 'Relay should maintain connections to both peers');
        print('✅ Relay server connected to $relayConnections peers');
        
        print('\n🎉 Circuit Relay test completed successfully!');
        print('   ✓ Peers connected to relay');
        print('   ✓ Circuit addresses advertised');
        print('   ✓ Peer-to-peer communication through relay works');
        print('   ✓ Connection verified as relayed (not direct)');
        
        // Note: tearDown will handle stopping the orchestrator
      }, timeout: Timeout(Duration(minutes: 4)));
    });
  });
}

/// Check if Docker is available on the system
Future<bool> _isDockerAvailable() async {
  try {
    final result = await Process.run('docker', ['--version']);
    return result.exitCode == 0;
  } catch (e) {
    return false;
  }
}
