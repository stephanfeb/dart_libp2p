import 'dart:async';
import 'dart:io';
import 'dart:convert';

import 'package:dart_libp2p/dart_libp2p.dart';
import 'package:dart_libp2p/config/config.dart';




import 'package:dart_libp2p/p2p/host/basic/basic_host.dart';
import 'package:dart_libp2p/p2p/protocol/holepunch/holepunch.dart';
import 'package:dart_libp2p/p2p/network/swarm/swarm.dart';
import 'package:dart_libp2p/p2p/transport/basic_upgrader.dart';
import 'package:dart_libp2p/p2p/transport/tcp_transport.dart';
import 'package:dart_libp2p/p2p/transport/connection_manager.dart';
import 'package:dart_libp2p/p2p/host/peerstore/pstoremem.dart';


import 'package:logging/logging.dart';

/// Integration test peer for holepunch testing
/// Can run as a relay server or regular peer
class IntegrationTestPeer {
  late final BasicHost host;
  late final Swarm network;
  late final Config config;
  final String role;
  final String peerName;
  
  IntegrationTestPeer({
    required this.role,
    required this.peerName,
  });

  Future<void> initialize() async {
    // Setup logging
    Logger.root.level = Level.ALL;
    Logger.root.onRecord.listen((record) {
      print('${DateTime.now().toIso8601String()} [${record.level}] ${record.loggerName}: ${record.message}');
      if (record.error != null) print('ERROR: ${record.error}');
      if (record.stackTrace != null) print('STACK: ${record.stackTrace}');
    });

    print('🚀 Initializing $role peer: $peerName');

    // Create key pair (deterministic for testing)
    final keyPair = await generateEd25519KeyPair();
    final peerId = PeerId.fromPublicKey(keyPair.publicKey);
    
    print('📱 Peer ID: ${peerId.toBase58()}');

    // Configure based on environment variables
    config = Config()
      ..peerKey = keyPair
      ..enableHolePunching = _getBoolEnv('ENABLE_HOLEPUNCH', true)
      ..enableRelay = _getBoolEnv('ENABLE_RELAY', role == 'relay')
      ..enableAutoNAT = _getBoolEnv('ENABLE_AUTONAT', false)
      ..enablePing = true;

    // Parse listen addresses
    final listenAddrsStr = Platform.environment['LISTEN_ADDRS'] ?? '/ip4/0.0.0.0/tcp/4001';
    config.listenAddrs = listenAddrsStr
        .split(',')
        .map((addr) => MultiAddr(addr.trim()))
        .toList();

    // Create network infrastructure
    final peerstore = MemoryPeerstore();
    final resourceManager = NullResourceManager();
    final connManager = ConnectionManager(
      idleTimeout: Duration(seconds: 30),
      shutdownTimeout: Duration(seconds: 5),
    );
    final upgrader = BasicUpgrader(resourceManager: resourceManager);
    
    // Create network (Swarm)
    network = Swarm(
      host: null, // Will be set after host creation
      localPeer: peerId,
      peerstore: peerstore,
      resourceManager: resourceManager,
      upgrader: upgrader,
      config: config,
      transports: [
        TCPTransport(
          resourceManager: resourceManager,
          connManager: connManager,
        ),
      ],
    );

    // Create host with network
    host = await BasicHost.create(network: network, config: config);
    
    // Link network back to host
    network.setHost(host);
    
    if (role == 'relay') {
      await _setupRelayServer();
    } else {
      await _setupPeer();
    }

    print('✅ $role peer $peerName initialized successfully');
  }

  Future<void> _setupRelayServer() async {
    print('🌐 Setting up relay server...');
    
    // Configure relay service if needed
    // The relay functionality should be automatically enabled via config.enableRelay
    
    print('📡 Relay server ready to accept connections');
  }

  Future<void> _setupPeer() async {
    print('🔗 Setting up regular peer...');
    
    // Parse relay servers if provided
    final relayServersStr = Platform.environment['RELAY_SERVERS'];
    if (relayServersStr != null) {
      final relayAddrs = relayServersStr
          .split(',')
          .map((addr) => MultiAddr(addr.trim()))
          .toList();
      
      print('🎯 Relay servers configured: $relayAddrs');
      
      // Connect to relay servers
      for (final relayAddr in relayAddrs) {
        try {
          await _connectToRelay(relayAddr);
        } catch (e) {
          print('⚠️  Failed to connect to relay $relayAddr: $e');
        }
      }
    }

    // Setup STUN servers for address discovery
    final stunServersStr = Platform.environment['STUN_SERVERS'];
    if (stunServersStr != null) {
      final stunServers = stunServersStr.split(',').map((s) => s.trim()).toList();
      print('🎯 STUN servers configured: $stunServers');
      // STUN integration would be handled by the NAT discovery system
    }
  }

  Future<void> _connectToRelay(MultiAddr relayAddr) async {
    print('🔌 Attempting to connect to relay: $relayAddr');
    
    // Extract relay peer ID from the multiaddr  
    // This is a simplified version - real implementation would parse properly
    try {
      // Extract peer ID from relay address and create AddrInfo
      final relayPeerId = _extractPeerIdFromAddr(relayAddr) ?? PeerId.fromString('12D3KooWDefaultRelay'); // Fallback ID
      final addrInfo = AddrInfo(relayPeerId, [relayAddr]);
      await host.connect(addrInfo);
      print('✅ Connected to relay: $relayAddr');
    } catch (e) {
      print('❌ Failed to connect to relay: $e');
      rethrow;
    }
  }

  Future<void> start() async {
    print('🎬 Starting $role peer $peerName...');
    
    await host.start();
    
    print('📍 Listening on addresses:');
    for (final addr in host.addrs) {
      print('  - $addr');
    }

    // Start the main event loop
    await _eventLoop();
  }

  Future<void> _eventLoop() async {
    print('🔄 Starting event loop...');
    
    // Set up signal handlers
    ProcessSignal.sigint.watch().listen((_) async {
      print('📧 Received SIGINT, shutting down...');
      await shutdown();
      exit(0);
    });

    ProcessSignal.sigterm.watch().listen((_) async {
      print('📧 Received SIGTERM, shutting down...');
      await shutdown();
      exit(0);
    });

    // For testing, we can expose a simple HTTP API for control
    await _startControlAPI();

    // Keep the peer alive
    while (true) {
      await Future.delayed(Duration(seconds: 10));
      print('💓 Peer $peerName heartbeat - Connected peers: ${host.network.peers.length}');
    }
  }

  Future<void> _startControlAPI() async {
    final port = int.tryParse(Platform.environment['CONTROL_PORT'] ?? '8080') ?? 8080;
    
    final server = await HttpServer.bind(InternetAddress.anyIPv4, port);
    print('🌐 Control API listening on port $port');
    
    server.listen((request) async {
      try {
        await _handleControlRequest(request);
      } catch (e) {
        print('❌ Control API error: $e');
        request.response.statusCode = 500;
        request.response.write('Error: $e');
        await request.response.close();
      }
    });
  }

  Future<void> _handleControlRequest(HttpRequest request) async {
    final path = request.uri.path;
    
    switch (path) {
      case '/status':
        await _handleStatusRequest(request);
        break;
      case '/connect':
        await _handleConnectRequest(request);
        break;
      case '/holepunch':
        await _handleHolepunchRequest(request);
        break;
      default:
        request.response.statusCode = 404;
        request.response.write('Not found');
        await request.response.close();
    }
  }

  Future<void> _handleStatusRequest(HttpRequest request) async {
    final status = {
      'peer_id': host.id.toBase58(),
      'role': role,
      'name': peerName,
      'addresses': host.addrs.map((a) => a.toString()).toList(),
      'connected_peers': host.network.peers.length,
      'holepunch_enabled': config.enableHolePunching,
      'relay_enabled': config.enableRelay,
    };
    
    request.response.headers.contentType = ContentType.json;
    request.response.write(jsonEncode(status));
    await request.response.close();
  }

  Future<void> _handleConnectRequest(HttpRequest request) async {
    final body = await utf8.decoder.bind(request).join();
    final data = jsonDecode(body) as Map<String, dynamic>;
    final targetAddr = MultiAddr(data['address'] as String);
    
    try {
      // Create AddrInfo with a dummy peer ID for connection
      final targetPeerId = _extractPeerIdFromAddr(targetAddr) ?? PeerId.fromString('12D3KooWDefaultTarget');
      final addrInfo = AddrInfo(targetPeerId, [targetAddr]);
      await host.connect(addrInfo);
      request.response.write('Connected successfully');
    } catch (e) {
      request.response.statusCode = 500;
      request.response.write('Connection failed: $e');
    }
    
    await request.response.close();
  }

  Future<void> _handleHolepunchRequest(HttpRequest request) async {
    final body = await utf8.decoder.bind(request).join();
    final data = jsonDecode(body) as Map<String, dynamic>;
    final targetPeerIdStr = data['peer_id'] as String;
    final targetPeerId = PeerId.fromString(targetPeerIdStr);
    
    try {
      // Trigger holepunch attempt
      // Get IDService from host (assuming it's accessible)
      final idService = (host as dynamic).idService; // Cast needed for accessing internal field
      final holePunchService = await newHolePunchService(
        host,
        idService,
        () => host.addrs, // Function that returns listen addresses
      );
      await holePunchService.directConnect(targetPeerId);
      request.response.write('Holepunch initiated');
    } catch (e) {
      request.response.statusCode = 500;
      request.response.write('Holepunch failed: $e');
    }
    
    await request.response.close();
  }

  Future<void> shutdown() async {
    print('🛑 Shutting down $role peer $peerName...');
    await host.close();
    print('✅ Shutdown complete');
  }

  bool _getBoolEnv(String key, bool defaultValue) {
    final value = Platform.environment[key]?.toLowerCase();
    if (value == null) return defaultValue;
    return value == 'true' || value == '1' || value == 'yes';
  }
  
  /// Extract peer ID from a MultiAddr if it contains a p2p component
  PeerId? _extractPeerIdFromAddr(MultiAddr addr) {
    try {
      final peerIdStr = addr.valueForProtocol('p2p');
      return peerIdStr != null ? PeerId.fromString(peerIdStr) : null;
    } catch (e) {
      return null;
    }
  }
  
  /// Set the host reference in the network after host creation
  void setHost(BasicHost host) {
    // This would be called from network.setHost(host) which is already done above
  }
}

Future<void> main() async {
  final role = Platform.environment['PEER_ROLE'] ?? 'peer';
  final peerName = Platform.environment['PEER_NAME'] ?? 'unknown';
  
  final peer = IntegrationTestPeer(role: role, peerName: peerName);
  
  try {
    await peer.initialize();
    await peer.start();
  } catch (e, stack) {
    print('💥 Fatal error in peer $peerName: $e');
    print('Stack trace: $stack');
    exit(1);
  }
}
