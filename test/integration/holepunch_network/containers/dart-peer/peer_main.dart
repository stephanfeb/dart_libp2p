import 'dart:async';
import 'dart:io';
import 'dart:convert';

import 'package:dart_libp2p/dart_libp2p.dart';
import 'package:dart_libp2p/config/config.dart';
import 'package:dart_libp2p/p2p/protocol/ping/ping.dart';
import 'package:dart_libp2p/p2p/security/noise/noise_protocol.dart';
import 'package:dart_libp2p/p2p/transport/multiplexing/yamux/session.dart';
import 'package:dart_libp2p/p2p/transport/multiplexing/multiplexer.dart';
import 'package:dart_libp2p/config/stream_muxer.dart';




import 'package:dart_libp2p/p2p/host/basic/basic_host.dart';
import 'package:dart_libp2p/p2p/protocol/holepunch/holepunch.dart';
import 'package:dart_libp2p/p2p/network/swarm/swarm.dart';
import 'package:dart_libp2p/p2p/transport/basic_upgrader.dart';
import 'package:dart_libp2p/p2p/transport/tcp_transport.dart';
import 'package:dart_libp2p/p2p/transport/connection_manager.dart';
import 'package:dart_libp2p/p2p/host/peerstore/pstoremem.dart';


import 'package:logging/logging.dart';

// Helper class for providing YamuxMuxer to the config  
class _YamuxMuxerProvider extends StreamMuxer {
  final MultiplexerConfig yamuxConfig;

  _YamuxMuxerProvider({required this.yamuxConfig})
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

    // Create Yamux multiplexer config
    final yamuxMultiplexerConfig = MultiplexerConfig(
      keepAliveInterval: Duration(seconds: 30),
      maxStreamWindowSize: 1024 * 1024,
      initialStreamWindowSize: 256 * 1024,
      streamWriteTimeout: Duration(seconds: 10),
      maxStreams: 256,
    );

    // Configure based on environment variables
    config = Config()
      ..peerKey = keyPair
      ..enableHolePunching = _getBoolEnv('ENABLE_HOLEPUNCH', true)
      ..enableRelay = _getBoolEnv('ENABLE_RELAY', role == 'relay')
      ..enableAutoNAT = _getBoolEnv('ENABLE_AUTONAT', false)
      ..enablePing = true
      // 🔒 SECURITY: Add Noise security protocol (fixes "No security protocols configured")
      ..securityProtocols = [await NoiseSecurity.create(keyPair)]
      // 🔀 MUXING: Add Yamux multiplexer (fixes "No muxers configured")  
      ..muxers = [_YamuxMuxerProvider(yamuxConfig: yamuxMultiplexerConfig)];

    // Parse listen addresses
    final listenAddrsStr = Platform.environment['LISTEN_ADDRS'] ?? '/ip4/0.0.0.0/tcp/4001';
    config.listenAddrs = listenAddrsStr
        .split(',')
        .map((addr) => MultiAddr(addr.trim()))
        .toList();

    // Create network infrastructure
    final peerstore = MemoryPeerstore();
    
    // 🔑 CRITICAL: Initialize peerstore with own keys (fixes peerstore lookup hangs)
    peerstore.keyBook.addPrivKey(peerId, keyPair.privateKey);
    peerstore.keyBook.addPubKey(peerId, keyPair.publicKey);
    
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
      print('📥 [HTTP] Incoming request received!');
      print('📥 [HTTP] Method: ${request.method}');
      print('📥 [HTTP] Path: ${request.uri.path}');
      print('📥 [HTTP] Remote address: ${request.connectionInfo?.remoteAddress}');
      print('📥 [HTTP] Content-Length: ${request.headers.contentLength}');
      
      try {
        print('📥 [HTTP] About to call _handleControlRequest...');
        await _handleControlRequest(request);
        print('📥 [HTTP] _handleControlRequest completed successfully');
      } catch (e, stackTrace) {
        print('❌ Control API error: $e');
        print('❌ Stack trace: $stackTrace');
        try {
          request.response.statusCode = 500;
          request.response.write('Error: $e');
          await request.response.close();
        } catch (closeError) {
          print('❌ Error closing response after error: $closeError');
        }
      }
    });
  }

  Future<void> _handleControlRequest(HttpRequest request) async {
    final path = request.uri.path;
    print('🌍 Control request: ${request.method} $path');
    
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
      case '/ping':
        await _handlePingRequest(request);
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
    final targetPeerIdStr = data['peer_id'] as String;
    final addrsJson = data['addrs'] as List<dynamic>;
    
    try {
      final targetPeerId = PeerId.fromString(targetPeerIdStr);
      final addrs = addrsJson.map((a) => MultiAddr(a)).toList();
      
      // Add peer addresses to peerstore
      for (final addr in addrs) {
        host.peerStore.addrBook.addAddr(targetPeerId, addr, Duration(hours: 1));
      }
      
      print('✅ Added ${addrs.length} addresses for peer $targetPeerIdStr');
      request.response.headers.contentType = ContentType.json;
      request.response.write(jsonEncode({
        'success': true,
        'message': 'Peer addresses added to peerstore',
        'addresses_added': addrs.length,
      }));
    } catch (e) {
      request.response.statusCode = 500;
      request.response.headers.contentType = ContentType.json;
      request.response.write(jsonEncode({
        'success': false,
        'message': 'Failed to add peer addresses: $e',
      }));
    }
    
    await request.response.close();
  }

  Future<void> _handlePingRequest(HttpRequest request) async {
    final body = await utf8.decoder.bind(request).join();
    final data = jsonDecode(body) as Map<String, dynamic>;
    final targetPeerIdStr = data['peer_id'] as String;
    
    try {
      final targetPeerId = PeerId.fromString(targetPeerIdStr);
      
      print('🏓 Attempting ping to $targetPeerIdStr using libp2p ping protocol (supports relay)');
      
      // Use libp2p's built-in ping protocol which handles relay routing transparently
      try {
        // Create a connection to the peer (will use relay if needed)
        print('🔍 Looking up addresses for target peer in peerstore...');
        final targetAddrs = await host.peerStore.addrBook.addrs(targetPeerId);
        
        if (targetAddrs.isEmpty) {
          throw Exception('No addresses found for peer $targetPeerIdStr in peerstore');
        }
        
        print('📍 Target peer addresses: $targetAddrs');
        
        // Use the host's ping service to ping the peer
        // This will work through relay connections if direct connection is not possible
        final pingService = PingService(host);
        if (pingService == null) {
          throw Exception('Ping service not available on this host');
        }
        
        print('🏓 Initiating libp2p ping to $targetPeerIdStr...');
        final pingStartTime = DateTime.now();
        
        // Ping the peer - this should work through relay if needed
        await pingService.ping(targetPeerId).timeout(
          Duration(seconds: 10),
          onTimeout: (EventSink<PingResult> res) {
            throw Exception('Ping timed out after 10 seconds');
          },
        );
        
        final pingDuration = DateTime.now().difference(pingStartTime);
        print('✅ Ping successful to $targetPeerIdStr in ${pingDuration.inMilliseconds}ms');
        
        // Get connection info for debugging
        final connectedness = host.network.connectedness(targetPeerId);
        final connections = host.network.conns;
        
        print('📊 Connection state: $connectedness');
        print('📊 Active connections: ${connections.length}');
        
        request.response.headers.contentType = ContentType.json;
        request.response.write(jsonEncode({
          'success': true,
          'message': 'Ping successful via libp2p protocol (may use relay)',
          'target_peer': targetPeerIdStr,
          'ping_duration_ms': pingDuration.inMilliseconds,
          'connectedness': connectedness.toString(),
          'connections_count': connections.length,
          'connection_details': connections.map((c) => {
            'remote_addr': c.remoteMultiaddr.toString(),
            'connection_type': c.runtimeType.toString(),
          }).toList(),
        }));
        
      } catch (e) {
        throw Exception('Libp2p ping failed: $e');
      }
      
    } catch (e) {
      print('❌ Ping failed: $e');
      request.response.statusCode = 500;
      request.response.headers.contentType = ContentType.json;
      request.response.write(jsonEncode({
        'success': false,
        'message': 'Ping failed: $e',
        'target_peer': targetPeerIdStr,
      }));
    }
    
    await request.response.close();
  }

  Future<void> _handleHolepunchRequest(HttpRequest request) async {
    print('🔥 ENTERING HOLEPUNCH HANDLER!');
    print('🚀 HOLEPUNCH HANDLER STARTED!');
    print('📥 Starting to read request body...');
    
    String? targetPeerIdStr;
    PeerId? targetPeerId;
    
    try {
      final body = await utf8.decoder.bind(request).join();
      print('📥 Request body read successfully: ${body.length} characters');
      print('🚀 Request body: $body');
      
      print('📊 About to parse JSON...');
      final data = jsonDecode(body) as Map<String, dynamic>;
      print('📊 JSON parsed successfully: $data');
      
      print('🔍 Extracting peer_id from data...');
      targetPeerIdStr = data['peer_id'] as String;
      print('🚀 Target peer extracted: $targetPeerIdStr');
      
      print('🆔 Creating PeerId object...');
      targetPeerId = PeerId.fromString(targetPeerIdStr);
      print('🆔 PeerId created successfully: ${targetPeerId.toString()}');
      
      print('🎯 Starting main holepunch logic...');
      // Check if we have addresses for this peer in our peerstore
      print('🔎 Looking up addresses for peer $targetPeerIdStr in peerstore...');
      final existingAddrs = await host.peerStore.addrBook.addrs(targetPeerId);
      print('🔎 Found ${existingAddrs.length} addresses for peer $targetPeerIdStr');
      if (existingAddrs.isEmpty) {
        throw Exception('No addresses found for peer $targetPeerIdStr. Call /connect first to add peer addresses.');
      }
      
      print('🔍 Found ${existingAddrs.length} addresses for peer $targetPeerIdStr');
      for (final addr in existingAddrs) {
        print('  📍 Target address: $addr');
      }
      
      // Show our own addresses for debugging  
      final ourAddrs = host.addrs;
      print('🏠 Our addresses (${ourAddrs.length}):');
      for (final addr in ourAddrs) {
        print('  📍 Our address: $addr (isPublic: ${addr.isPublic()})');
      }
      
      // Show public addresses that holepunch service will see
      if (host is BasicHost) {
        final publicAddrs = (host as dynamic).publicAddrs as List;
        print('🔍 Public addresses for holepunch (${publicAddrs.length}):');
        for (final addr in publicAddrs) {
          print('  📍 Public address: $addr');
        }
      }
      
      // Use the existing holepunch service from BasicHost
      final holePunchService = host.holePunchService;
      if (holePunchService == null) {
        throw Exception('Holepunch service is not enabled on this host');
      }
      
      print('🔍 Ensuring holepunch service is fully initialized...');
      // Wait for the service to be properly initialized to avoid race conditions
      await holePunchService.start();
      print('✅ Holepunch service initialization confirmed');
      
      print('🕳️ Starting holepunch operation to $targetPeerIdStr...');
      print('🕳️ Checking if target peer has existing connection...');
      
      // Check if already connected
      final existingConnection = host.network.connectedness(targetPeerId);
      print('🕳️ Existing connection status: $existingConnection');
      
      // Check addresses in peerstore
      final peerAddrs = await host.peerStore.addrBook.addrs(targetPeerId);
      print('🕳️ Target peer addresses in peerstore: $peerAddrs');
      
      // Check our own addresses
      final ownAddrs = host.allAddrs;
      print('🕳️ Our own addresses: $ownAddrs');
      
      // Check relay connections 
      final allConnections = host.network.connectedness;
      print('🕳️ All network connections: $allConnections');
      
      print('🕳️ About to call holePunchService.directConnect()...');
      final stopwatch = Stopwatch()..start();
      
      // Add timeout to prevent infinite hang
      await holePunchService.directConnect(targetPeerId).timeout(
        Duration(seconds: 30),
        onTimeout: () {
          print('❌ Holepunch timed out after ${stopwatch.elapsedMilliseconds}ms');
          throw Exception('Holepunch timed out after 30 seconds - likely waiting for public addresses that never arrive');
        },
      );
      
      stopwatch.stop();
      print('✅ Holepunch completed in ${stopwatch.elapsedMilliseconds}ms');
      
      request.response.headers.contentType = ContentType.json;
      request.response.write(jsonEncode({
        'success': true,
        'message': 'Holepunch initiated successfully',
        'target_peer': targetPeerIdStr,
      }));
    } catch (e, stackTrace) {
      print('❌ Error in holepunch handler: $e');
      print('❌ Stack trace: $stackTrace');
      request.response.statusCode = 500;
      request.response.headers.contentType = ContentType.json;
      request.response.write(jsonEncode({
        'success': false,
        'message': 'Holepunch failed: $e',
        'target_peer': targetPeerIdStr ?? 'unknown',
      }));
    }
    
    await request.response.close();
  }

  /// Attempts to discover a peer via relay connection
  Future<void> _discoverPeerViaRelay(PeerId targetPeerId) async {
    print('🔍 Attempting to discover peer $targetPeerId via relay...');
    
    // Check if we already have addresses for this peer
    final existingAddrs = await host.peerStore.addrBook.addrs(targetPeerId);
    if (existingAddrs.isNotEmpty) {
      print('✅ Peer $targetPeerId already known with ${existingAddrs.length} addresses');
      return;
    }
    
    // Try to connect to the relay first to ensure we have a communication path
    final relayServers = Platform.environment['RELAY_SERVERS'];
    if (relayServers != null && relayServers.isNotEmpty) {
      final relayAddrs = relayServers.split(',').map((s) => MultiAddr(s.trim())).toList();
      
      for (final relayAddr in relayAddrs) {
        try {
          await _connectToRelay(relayAddr);
          print('✅ Connected to relay for peer discovery: $relayAddr');
          break; // Exit after first successful connection
        } catch (e) {
          print('⚠️ Failed to connect to relay $relayAddr: $e');
          continue;
        }
      }
    }
    
    // For now, we'll rely on the relay and identify protocol to discover peers
    // In a more sophisticated setup, we could implement active peer discovery
    print('🔍 Waiting for peer discovery via identify protocol...');
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
