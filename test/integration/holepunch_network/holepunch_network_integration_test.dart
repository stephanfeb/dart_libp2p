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

    test('Cone-to-Cone NAT Holepunch Success', () async {
      final scenario = ConeToConeSucessScenario(orchestrator);
      final result = await scenario.run();
      
      expect(result.success, isTrue, reason: result.message);
    }, timeout: Timeout(Duration(minutes: 4)));

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
      test('NAT Gateway Configuration Validation', () async {
        orchestrator.environment['NAT_A_TYPE'] = 'cone';
        orchestrator.environment['NAT_B_TYPE'] = 'symmetric';
        
        await orchestrator.start();
        
        // Verify NAT rules are correctly applied
        final natALogs = await orchestrator.getLogs('nat-gateway-a', lines: 20);
        final natBLogs = await orchestrator.getLogs('nat-gateway-b', lines: 20);
        
        expect(natALogs, contains('Cone NAT configuration complete'));
        expect(natBLogs, contains('Symmetric NAT configuration complete'));
        
        await orchestrator.stop();
      }, timeout: Timeout(Duration(minutes: 3)));

      test('STUN Server Functionality', () async {
        await orchestrator.start();
        
        // Test that peers can discover their external addresses via STUN
        final peerAStatus = await orchestrator.sendControlRequest('peer-a', '/status');
        
        expect(peerAStatus['peer_id'], isNotNull);
        expect(peerAStatus['addresses'], isA<List>());
        
        await orchestrator.stop();
      }, timeout: Timeout(Duration(minutes: 3)));

      test('Relay Server Connectivity', () async {
        await orchestrator.start();
        
        // Verify relay server is accessible and functional
        final relayStatus = await orchestrator.sendControlRequest('relay-server', '/status');
        
        expect(relayStatus['role'], equals('relay'));
        expect(relayStatus['relay_enabled'], isTrue);
        
        await orchestrator.stop();
      }, timeout: Timeout(Duration(minutes: 3)));
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
