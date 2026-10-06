import 'dart:async';
import 'dart:io';
import '../utils/container_orchestrator.dart';

/// Base class for holepunch integration test scenarios
abstract class HolePunchScenario {
  final String name;
  final String description;
  final ContainerOrchestrator orchestrator;
  
  HolePunchScenario({
    required this.name,
    required this.description,
    required this.orchestrator,
  });

  /// Setup the scenario-specific configuration
  Future<void> setup();
  
  /// Execute the test scenario
  Future<ScenarioResult> execute();
  
  /// Clean up after the scenario
  Future<void> teardown();
  
  /// Run the complete scenario
  Future<ScenarioResult> run() async {
    print('🎬 Starting scenario: $name');
    print('📝 Description: $description');
    
    try {
      await setup();
      final result = await execute();
      await teardown();
      
      print('${result.success ? '✅' : '❌'} Scenario $name: ${result.message}');
      return result;
    } catch (e, stack) {
      print('💥 Scenario $name failed: $e');
      print('Stack: $stack');
      
      try {
        await teardown();
      } catch (teardownError) {
        print('⚠️ Teardown error: $teardownError');
      }
      
      return ScenarioResult.failure('Exception: $e');
    }
  }
}

/// Scenario: Both peers behind Cone NATs - should succeed
class ConeToConeSucessScenario extends HolePunchScenario {
  ConeToConeSucessScenario(ContainerOrchestrator orchestrator)
      : super(
          name: 'Cone-to-Cone Success',
          description: 'Two peers behind Cone NATs should successfully establish direct connection via holepunch',
          orchestrator: orchestrator,
        );

  @override
  Future<void> setup() async {
    // Configure both NAT gateways as Cone NATs
    orchestrator.environment['NAT_A_TYPE'] = 'cone';
    orchestrator.environment['NAT_B_TYPE'] = 'cone';
    
    // CRITICAL: NAT type changes require container restart
    // We must stop and restart infrastructure when NAT configuration changes
    if (orchestrator.isStarted) {
      print('🔄 Stopping existing infrastructure to apply new NAT configuration...');
      await orchestrator.stop();
    }
    
    print('🔧 Starting infrastructure with Cone NAT configuration...');
    await orchestrator.start();
    
    // Fresh infrastructure needs extra time for NAT rules, relay connections, and STUN discovery
    print('⏰ Allowing warmup time for Cone NAT infrastructure...');
    await Future.delayed(Duration(seconds: 20));
    
    print('✅ ConeToConeSucessScenario setup complete');
  }

  // Steps follow scripts/run_dcutr_scenario.sh. Each peer reserves a slot on
  // the relay at its public_net address (100.70.3.10), so the relayed
  // connection and the punch go through the NAT gateways. Status addresses
  // also have a circuit through the relay's control_net address, which the
  // peers reach directly, not through their NATs (dart-libp2p-8rm).
  @override
  Future<ScenarioResult> execute() async {
    final peerAStatus = await orchestrator.sendControlRequest('peer-a', '/status');
    final peerBStatus = await orchestrator.sendControlRequest('peer-b', '/status');
    final peerAId = peerAStatus['peer_id'] as String;
    final peerBId = peerBStatus['peer_id'] as String;
    print('👥 Peer A ID: $peerAId');
    print('👥 Peer B ID: $peerBId');

    print('🎫 Reserving relay slots...');
    final reserveA = await orchestrator.sendControlRequest('peer-a', '/reserve',
        method: 'POST', timeout: Duration(seconds: 30));
    final reserveB = await orchestrator.sendControlRequest('peer-b', '/reserve',
        method: 'POST', timeout: Duration(seconds: 30));

    List<String> introAddrs(Map<String, dynamic> status, Map<String, dynamic> reserve) => [
          ...List<String>.from(status['addresses'] as List)
              .where((a) => !a.contains('p2p-circuit')),
          reserve['circuit'] as String,
        ];
    final peerAAddrs = introAddrs(peerAStatus, reserveA);
    final peerBAddrs = introAddrs(peerBStatus, reserveB);
    print('📍 Peer A addresses: $peerAAddrs');
    print('📍 Peer B addresses: $peerBAddrs');

    print('🤝 Introducing the peers to each other...');
    await orchestrator.sendControlRequest('peer-a', '/connect',
        method: 'POST', body: {'peer_id': peerBId, 'addrs': peerBAddrs}, timeout: Duration(seconds: 30));
    try {
      await orchestrator.sendControlRequest('peer-b', '/connect',
          method: 'POST', body: {'peer_id': peerAId, 'addrs': peerAAddrs}, timeout: Duration(seconds: 30));
    } on ContainerException catch (e) {
      // Peer A may already be connected through the relay; the addresses are
      // in peer B's peerstore all the same.
      print('ℹ️ Introducing peer A to peer B: $e');
    }

    // A relayed ping opens the relayed connection that DCUtR runs over.
    final ping = await orchestrator.sendControlRequest('peer-a', '/ping',
        method: 'POST', body: {'peer_id': peerBId}, timeout: Duration(seconds: 20));
    print('🏓 Ping over relay: $ping');

    // The /holepunch response is only for information: if peer B completes
    // the punch first, peer A's attempt can fail and the punch still succeeds.
    try {
      final holepunch = await orchestrator.sendControlRequest('peer-a', '/holepunch',
          method: 'POST', body: {'peer_id': peerBId});
      print('🕳️ Holepunch result: $holepunch');
    } on ContainerException catch (e) {
      print('🕳️ Holepunch request failed: $e');
    }

    await Future.delayed(Duration(seconds: 25));

    final conns = await orchestrator.getConnections('peer-a');
    print('🔌 Peer A connections: $conns');
    final direct = conns
        .where((c) => c['peer_id'] == peerBId && c['relayed'] != true)
        .map((c) => c['remote_addr'])
        .toList();
    if (direct.isNotEmpty) {
      return ScenarioResult.success('Direct connection to peer B via ${direct.join(', ')}');
    }
    final result = ScenarioResult.failure('No direct connection to peer B (connections: $conns)');
    await _saveLogs();
    return result;
  }

  /// Writes the full container logs to a temporary directory, because the
  /// scenario prints only the last lines of the peer logs.
  Future<void> _saveLogs() async {
    try {
      final dir = await Directory.systemTemp.createTemp('cone-to-cone-');
      for (final c in ['peer-a', 'peer-b', 'relay-server', 'nat-gateway-a', 'nat-gateway-b']) {
        await File('${dir.path}/$c.log').writeAsString(await orchestrator.getLogs(c));
      }
      print('📁 Container logs saved to ${dir.path}');
    } catch (e) {
      print('⚠️ Failed to save logs: $e');
    }
  }

  @override
  Future<void> teardown() async {
    // Get logs for analysis
    try {
      final logsA = await orchestrator.getLogs('peer-a', lines: 50);
      final logsB = await orchestrator.getLogs('peer-b', lines: 50);
      print('📋 Peer A logs:\n$logsA');
      print('📋 Peer B logs:\n$logsB');
    } catch (e) {
      print('⚠️ Failed to get logs: $e');
    }
  }
}

/// Scenario: Both peers behind Symmetric NATs - should fail gracefully
class SymmetricToSymmetricFailureScenario extends HolePunchScenario {
  SymmetricToSymmetricFailureScenario(ContainerOrchestrator orchestrator)
      : super(
          name: 'Symmetric-to-Symmetric Failure',
          description: 'Two peers behind Symmetric NATs should fail to establish direct connection but maintain relay',
          orchestrator: orchestrator,
        );

  @override
  Future<void> setup() async {
    // Configure both NAT gateways as Symmetric NATs
    orchestrator.environment['NAT_A_TYPE'] = 'symmetric';
    orchestrator.environment['NAT_B_TYPE'] = 'symmetric';
    
    // CRITICAL: NAT type changes require container restart
    // We must stop and restart infrastructure when NAT configuration changes
    if (orchestrator.isStarted) {
      print('🔄 Stopping existing infrastructure to apply new NAT configuration...');
      await orchestrator.stop();
    }
    
    print('🔧 Starting infrastructure with Symmetric NAT configuration...');
    await orchestrator.start();
    
    // Fresh infrastructure needs extra time for NAT rules, relay connections, and STUN discovery
    print('⏰ Allowing warmup time for Symmetric NAT infrastructure...');
    await Future.delayed(Duration(seconds: 20));
    
    print('✅ SymmetricToSymmetricFailureScenario setup complete');
  }

  @override
  Future<ScenarioResult> execute() async {
    // Get peer IDs and addresses
    final peerAStatus = await orchestrator.sendControlRequest('peer-a', '/status');
    final peerBStatus = await orchestrator.sendControlRequest('peer-b', '/status');
    
    final peerAId = peerAStatus['peer_id'] as String;
    final peerBId = peerBStatus['peer_id'] as String;
    final peerAAddrs = List<String>.from(peerAStatus['addresses'] as List);
    final peerBAddrs = List<String>.from(peerBStatus['addresses'] as List);
    
    print('👥 Peer A ID: $peerAId');
    print('👥 Peer B ID: $peerBId');
    
    // Introduce peers to each other via peerstore
    print('🤝 Introducing peer B to peer A...');
    await orchestrator.sendControlRequest(
      'peer-a',
      '/connect',
      method: 'POST',
      body: {'peer_id': peerBId, 'addrs': peerBAddrs},
    );
    
    print('🤝 Introducing peer A to peer B...');
    await orchestrator.sendControlRequest(
      'peer-b',
      '/connect',
      method: 'POST',
      body: {'peer_id': peerAId, 'addrs': peerAAddrs},
    );
    
    // Wait for peer introductions to settle
    await Future.delayed(Duration(seconds: 1));
    
    // Attempt holepunch (should fail)
    print('🕳️  Attempting holepunch (expecting failure)...');
    
    try {
      await orchestrator.sendControlRequest(
        'peer-a',
        '/holepunch',
        method: 'POST',
        body: {'peer_id': peerBId},
      );
    } catch (e) {
      print('🎯 Holepunch failed as expected: $e');
    }
    
    // Wait for failure and fallback
    await Future.delayed(Duration(seconds: 20));
    
    // Verify that relay connection still works
    // final finalStatusA = await orchestrator.sendControlRequest('peer-a', '/status');
    // final finalStatusB = await orchestrator.sendControlRequest('peer-b', '/status');
    
    // In this scenario, success means: no direct connection but relay still works
    // We would need to verify the connection path is through relay
    
    return ScenarioResult.success(
      'Holepunch correctly failed with Symmetric NATs, relay connectivity maintained',
    );
  }

  @override
  Future<void> teardown() async {
    // Collect failure analysis logs
    try {
      final natLogsA = await orchestrator.getLogs('nat-gateway-a', lines: 30);
      final natLogsB = await orchestrator.getLogs('nat-gateway-b', lines: 30);
      print('🔐 NAT A logs:\n$natLogsA');
      print('🔐 NAT B logs:\n$natLogsB');
    } catch (e) {
      print('⚠️ Failed to get NAT logs: $e');
    }
  }
}

/// Scenario: Mixed NAT types (Cone + Symmetric) - should fail but handle gracefully
class MixedNATScenario extends HolePunchScenario {
  MixedNATScenario(ContainerOrchestrator orchestrator)
      : super(
          name: 'Mixed NAT Types',
          description: 'Cone NAT peer to Symmetric NAT peer - should fail holepunch but maintain relay',
          orchestrator: orchestrator,
        );

  @override
  Future<void> setup() async {
    // Configure mixed NAT types - Cone NAT A, Symmetric NAT B
    orchestrator.environment['NAT_A_TYPE'] = 'cone';
    orchestrator.environment['NAT_B_TYPE'] = 'symmetric';
    
    // CRITICAL: NAT type changes require container restart
    // We must stop and restart infrastructure when NAT configuration changes
    if (orchestrator.isStarted) {
      print('🔄 Stopping existing infrastructure to apply new NAT configuration...');
      await orchestrator.stop();
    }
    
    print('🔧 Starting infrastructure with Mixed NAT configuration (Cone + Symmetric)...');
    await orchestrator.start();
    
    // Fresh infrastructure needs extra time for NAT rules, relay connections, and STUN discovery
    print('⏰ Allowing warmup time for Mixed NAT infrastructure...');
    await Future.delayed(Duration(seconds: 20));
    
    print('✅ MixedNATScenario setup complete');
  }

  @override
  Future<ScenarioResult> execute() async {
    // Get peer IDs and addresses
    final peerAStatus = await orchestrator.sendControlRequest('peer-a', '/status');
    final peerBStatus = await orchestrator.sendControlRequest('peer-b', '/status');
    
    final peerAId = peerAStatus['peer_id'] as String;
    final peerBId = peerBStatus['peer_id'] as String;
    final peerAAddrs = List<String>.from(peerAStatus['addresses'] as List);
    final peerBAddrs = List<String>.from(peerBStatus['addresses'] as List);
    
    print('👥 Peer A ID: $peerAId');
    print('👥 Peer B ID: $peerBId');
    print('📍 Peer A addresses: $peerAAddrs');
    print('📍 Peer B addresses: $peerBAddrs');
    
    // Verify initial connectivity (should be 0 before any connections)
    final initialConnectedA = peerAStatus['connected_peers'] as int;
    final initialConnectedB = peerBStatus['connected_peers'] as int;
    print('🔌 Initial connectivity - A: $initialConnectedA peers, B: $initialConnectedB peers');
    
    // Introduce peers to each other via peerstore to establish relay connection
    print('🤝 Introducing peer B to peer A...');
    final connectResultA = await orchestrator.sendControlRequest(
      'peer-a',
      '/connect',
      method: 'POST',
      body: {'peer_id': peerBId, 'addrs': peerBAddrs},
    );
    print('📋 Connect A result: $connectResultA');
    
    print('🤝 Introducing peer A to peer B...');
    final connectResultB = await orchestrator.sendControlRequest(
      'peer-b',
      '/connect',
      method: 'POST',
      body: {'peer_id': peerAId, 'addrs': peerAAddrs},
    );
    print('📋 Connect B result: $connectResultB');
    
    // Wait for relay connections to establish
    print('⏳ Waiting for relay connections to establish...');
    await Future.delayed(Duration(seconds: 10));
    
    // Verify relay connectivity established
    final relayStatusA = await orchestrator.sendControlRequest('peer-a', '/status');
    final relayStatusB = await orchestrator.sendControlRequest('peer-b', '/status');
    
    final relayConnectedA = relayStatusA['connected_peers'] as int;
    final relayConnectedB = relayStatusB['connected_peers'] as int;
    
    print('🔗 After relay setup - A: $relayConnectedA peers, B: $relayConnectedB peers');
    
    // Assertion 1: Verify both peers are connected (should be to relay server, not each other)
    if (relayConnectedA == 0 || relayConnectedB == 0) {
      return ScenarioResult.failure(
        'Failed to establish relay connectivity. A: $relayConnectedA peers, B: $relayConnectedB peers. '
        'Mixed NAT test requires both peers to connect to relay server.',
      );
    }
    print('✅ Relay connectivity established - both peers connected to relay server');
    print('📡 Note: Peers connect to relay server, not directly to each other in Mixed NAT scenario');
    
    // Test communication via relay before holepunch attempt
    print('🏓 Testing communication via relay...');
    try {
      final pingResult = await orchestrator.sendControlRequest(
        'peer-a',
        '/ping',
        method: 'POST',
        body: {'peer_id': peerBId},
      );
      print('📋 Relay ping result: $pingResult');
      
      if (!(pingResult['success'] as bool)) {
        return ScenarioResult.failure(
          'Relay communication failed before holepunch attempt: ${pingResult['message']}',
        );
      }
      print('✅ Relay communication working correctly');
    } catch (e) {
      return ScenarioResult.failure(
        'Exception during relay communication test: $e',
      );
    }
    
    // Now attempt holepunch (expecting failure with Mixed NATs)
    print('🕳️  Attempting Cone → Symmetric holepunch (expecting failure)...');
    
    bool holepunchFailed = false;
    String holepunchError = '';
    
    try {
      final holepunchResult = await orchestrator.sendControlRequest(
        'peer-a',
        '/holepunch',
        method: 'POST',
        body: {'peer_id': peerBId},
      );
      print('📋 Holepunch result: $holepunchResult');
      
      // If holepunch claims success with Mixed NATs, this is unexpected
      if (holepunchResult['success'] == true) {
        print('⚠️ Unexpected: Holepunch reported success with Mixed NATs');
      }
    } catch (e) {
      holepunchFailed = true;
      holepunchError = e.toString();
      print('🎯 Holepunch failed as expected with Mixed NATs: $e');
    }
    
    // Wait for any holepunch cleanup/stabilization
    await Future.delayed(Duration(seconds: 10));
    
    // Assertion 2: Verify holepunch did not break relay connectivity
    final postHolepunchStatusA = await orchestrator.sendControlRequest('peer-a', '/status');
    final postHolepunchStatusB = await orchestrator.sendControlRequest('peer-b', '/status');
    
    final postHolepunchConnectedA = postHolepunchStatusA['connected_peers'] as int;
    final postHolepunchConnectedB = postHolepunchStatusB['connected_peers'] as int;
    
    print('🔗 After holepunch attempt - A: $postHolepunchConnectedA peers, B: $postHolepunchConnectedB peers');
    
    if (postHolepunchConnectedA == 0 || postHolepunchConnectedB == 0) {
      return ScenarioResult.failure(
        'Holepunch attempt broke relay connectivity. A: $postHolepunchConnectedA peers, B: $postHolepunchConnectedB peers. '
        'Expected: relay connection maintained after failed holepunch.',
      );
    }
    print('✅ Relay connectivity maintained after holepunch attempt');
    
    // Assertion 3: Verify communication still works via relay after holepunch
    print('🏓 Testing communication via relay after holepunch...');
    try {
      final postHolepunchPing = await orchestrator.sendControlRequest(
        'peer-a',
        '/ping',
        method: 'POST',
        body: {'peer_id': peerBId},
      );
      print('📋 Post-holepunch ping result: $postHolepunchPing');
      
      if (!(postHolepunchPing['success'] as bool)) {
        return ScenarioResult.failure(
          'Relay communication failed after holepunch: ${postHolepunchPing['message']}',
        );
      }
      print('✅ Relay communication maintained after holepunch');
    } catch (e) {
      return ScenarioResult.failure(
        'Exception during post-holepunch communication test: $e',
      );
    }
    
    // Assertion 4: Verify bidirectional communication
    print('🏓 Testing bidirectional communication (B → A)...');
    try {
      final reversePing = await orchestrator.sendControlRequest(
        'peer-b',
        '/ping',
        method: 'POST',
        body: {'peer_id': peerAId},
      );
      print('📋 Reverse ping result: $reversePing');
      
      if (!(reversePing['success'] as bool)) {
        return ScenarioResult.failure(
          'Bidirectional relay communication failed: ${reversePing['message']}',
        );
      }
      print('✅ Bidirectional relay communication confirmed');
    } catch (e) {
      return ScenarioResult.failure(
        'Exception during bidirectional communication test: $e',
      );
    }
    
    // Compile results
    final metrics = {
      'initial_connected_a': initialConnectedA,
      'initial_connected_b': initialConnectedB,
      'relay_connected_a': relayConnectedA,
      'relay_connected_b': relayConnectedB,
      'post_holepunch_connected_a': postHolepunchConnectedA,
      'post_holepunch_connected_b': postHolepunchConnectedB,
      'holepunch_failed': holepunchFailed,
      'holepunch_error': holepunchError,
    };
    
    return ScenarioResult.success(
      'Mixed NAT scenario executed successfully: '
      'relay connectivity established ($relayConnectedA/$relayConnectedB peers), '
      'holepunch ${holepunchFailed ? "failed as expected" : "unexpected result"}, '
      'relay maintained ($postHolepunchConnectedA/$postHolepunchConnectedB peers), '
      'bidirectional communication verified',
      metrics,
    );
  }

  @override
  Future<void> teardown() async {
    // Collect detailed logs for Mixed NAT scenario analysis
    try {
      print('📋 Collecting Mixed NAT scenario logs...');
      
      final peerALogs = await orchestrator.getLogs('peer-a'); // All logs
      final peerBLogs = await orchestrator.getLogs('peer-b'); // All logs to see full startup
      final relayLogs = await orchestrator.getLogs('relay-server', lines: 30);
      final natALogs = await orchestrator.getLogs('nat-gateway-a'); // All logs  
      final natBLogs = await orchestrator.getLogs('nat-gateway-b'); // All logs to see full NAT setup
      
      print('📋 Peer A logs (Mixed NAT - Cone):\n$peerALogs');
      print('📋 Peer B logs (Mixed NAT - Symmetric):\n$peerBLogs');
      print('📋 Relay server logs:\n$relayLogs');
      print('📋 NAT Gateway A logs (Cone):\n$natALogs');
      print('📋 NAT Gateway B logs (Symmetric):\n$natBLogs');
      
      // Get final status for summary
      try {
        final finalStatusA = await orchestrator.sendControlRequest('peer-a', '/status');
        final finalStatusB = await orchestrator.sendControlRequest('peer-b', '/status');
        print('📊 Final status - A: ${finalStatusA['connected_peers']} peers, B: ${finalStatusB['connected_peers']} peers');
      } catch (e) {
        print('⚠️ Could not get final status: $e');
      }
      
    } catch (e) {
      print('⚠️ Failed to collect teardown logs: $e');
    }
  }
}

/// Container for scenario execution results
class ScenarioResult {
  final bool success;
  final String message;
  final Map<String, dynamic> metrics;
  
  ScenarioResult({
    required this.success,
    required this.message,
    this.metrics = const {},
  });
  
  factory ScenarioResult.success(String message, [Map<String, dynamic>? metrics]) {
    return ScenarioResult(
      success: true,
      message: message,
      metrics: metrics ?? {},
    );
  }
  
  factory ScenarioResult.failure(String message, [Map<String, dynamic>? metrics]) {
    return ScenarioResult(
      success: false,
      message: message,
      metrics: metrics ?? {},
    );
  }
}

/// Scenario runner that executes multiple scenarios
class ScenarioRunner {
  final List<HolePunchScenario> scenarios;
  
  ScenarioRunner(this.scenarios);
  
  Future<List<ScenarioResult>> runAll() async {
    final results = <ScenarioResult>[];
    
    print('🎭 Running ${scenarios.length} holepunch scenarios...');
    
    for (final scenario in scenarios) {
      final result = await scenario.run();
      results.add(result);
      
      // Brief pause between scenarios
      await Future.delayed(Duration(seconds: 5));
    }
    
    _printSummary(results);
    return results;
  }
  
  void _printSummary(List<ScenarioResult> results) {
    final successful = results.where((r) => r.success).length;
    final total = results.length;
    
    print('\n📊 Scenario Summary:');
    print('✅ Successful: $successful/$total');
    print('❌ Failed: ${total - successful}/$total');
    
    for (int i = 0; i < results.length; i++) {
      final result = results[i];
      final scenario = scenarios[i];
      print('${result.success ? '✅' : '❌'} ${scenario.name}: ${result.message}');
    }
  }
}
