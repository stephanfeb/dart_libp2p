/// DHT + Relay netem test for reproducing production stream failure.
///
/// Usage: dart run bin/dht_relay_netem_test.dart <multiaddr/p2p/peerid> [wait_secs]
///
/// Matches overnode_v2 production network stack as closely as possible:
///   - Yamux: 30s keepalive, 10s write timeout, 256KB initial window
///   - DHT: client mode with production options
///   - Relay: enabled with autoRelay + relay servers
///   - AutoNAT v2: enabled
///   - Hole punching: enabled
///
/// Exit code: 0 = all phases pass, 1 = failure (bug reproduced).
import 'dart:io';

import 'package:dart_libp2p/core/crypto/ed25519.dart' as crypto_ed25519;
import 'package:dart_libp2p/core/crypto/keys.dart';
import 'package:dart_libp2p/core/multiaddr.dart';
import 'package:dart_libp2p/core/network/conn.dart';
import 'package:dart_libp2p/core/network/transport_conn.dart';
import 'package:dart_libp2p/core/peer/peer_id.dart';
import 'package:dart_libp2p/core/peer/addr_info.dart';
import 'package:dart_libp2p/core/network/context.dart' as core_context;
import 'package:dart_libp2p/config/config.dart' as p2p_config;
import 'package:dart_libp2p/p2p/host/basic/basic_host.dart';
import 'package:dart_libp2p/p2p/protocol/circuitv2/client/reservation.dart';
import 'package:dart_libp2p/p2p/host/autonat/ambient_config.dart';
import 'package:dart_libp2p/p2p/security/noise/noise_protocol.dart';
import 'package:dart_libp2p/p2p/transport/connection_manager.dart';
import 'package:dart_libp2p/p2p/transport/multiplexing/multiplexer.dart';
import 'package:dart_libp2p/p2p/transport/multiplexing/yamux/session.dart';
import 'package:dart_libp2p/p2p/transport/udx_transport.dart';
import 'package:dart_libp2p/p2p/multiaddr/protocol.dart';
import 'package:dart_libp2p_kad_dht/dart_libp2p_kad_dht.dart';

int passed = 0;
int failed = 0;

void report(String phase, bool ok, [String? detail]) {
  if (ok) {
    passed++;
    stderr.writeln('  PASS: $phase');
  } else {
    failed++;
    stderr.writeln('  FAIL: $phase${detail != null ? " — $detail" : ""}');
  }
}

/// Creates a host matching overnode_v2 production network stack.
Future<BasicHost> createHost(KeyPair keyPair, String relayServerAddr) async {
  final connMgr = ConnectionManager(
    idleTimeout: const Duration(seconds: 30),
  );
  final udxTransport = UDXTransport(connManager: connMgr);

  // Yamux config matching production (network_actor.dart:84-90)
  final yamuxConfig = MultiplexerConfig(
    keepAliveInterval: const Duration(seconds: 30),
    maxStreamWindowSize: 1024 * 1024,
    initialStreamWindowSize: 256 * 1024,
    streamWriteTimeout: const Duration(seconds: 10),
    maxStreams: 256,
  );

  final hostOptions = <p2p_config.Option>[
    await p2p_config.Libp2p.identity(keyPair),
    await p2p_config.Libp2p.connManager(connMgr),
    await p2p_config.Libp2p.transport(udxTransport),
    await p2p_config.Libp2p.security(await NoiseSecurity.create(keyPair)),
    await p2p_config.Libp2p.muxer(
      '/yamux/1.0.0',
      (Conn secureConn, bool isClient) {
        if (secureConn is! TransportConn) {
          throw ArgumentError(
              'YamuxMuxer factory expects a TransportConn, got ${secureConn.runtimeType}');
        }
        return YamuxSession(secureConn, yamuxConfig, isClient, null);
      },
    ),
    await p2p_config.Libp2p.listenAddrs([MultiAddr('/ip4/0.0.0.0/udp/0/udx')]),
    // Relay + AutoRelay (production enables both)
    await p2p_config.Libp2p.relay(true),
    await p2p_config.Libp2p.autoRelay(true),
    await p2p_config.Libp2p.relayServers([relayServerAddr]),
    // Hole punching
    await p2p_config.Libp2p.holePunching(true),
    // AutoNAT v2 (production config from network_actor.dart:140-150)
    await p2p_config.Libp2p.autoNAT(true),
    await p2p_config.Libp2p.ambientAutoNATv2Config(
      AmbientAutoNATv2Config(
        bootDelay: const Duration(seconds: 3),
        retryInterval: const Duration(seconds: 5),
        refreshInterval: const Duration(minutes: 5),
        ipv4Only: true,
      ),
    ),
  ];

  final host = await p2p_config.Libp2p.new_(hostOptions) as BasicHost;
  await host.start();
  return host;
}

Future<void> main(List<String> arguments) async {
  if (arguments.isEmpty) {
    stderr.writeln(
        'Usage: dart run bin/dht_relay_netem_test.dart <multiaddr/p2p/peerid> [wait_secs]');
    exit(1);
  }

  final targetAddrStr = arguments[0];
  final waitSecs = arguments.length > 1 ? int.parse(arguments[1]) : 15;
  final targetMa = MultiAddr(targetAddrStr);

  // Extract peer ID
  final targetPeerIdStr = targetMa.valueForProtocol(Protocols.p2p.name);
  if (targetPeerIdStr == null) {
    stderr.writeln('ERROR: multiaddr must include /p2p/<peer-id>');
    exit(1);
  }
  final targetPeerId = PeerId.fromString(targetPeerIdStr);
  final connectAddr = targetMa.decapsulate(Protocols.p2p.name)!;

  final localKeyPair = await crypto_ed25519.generateEd25519KeyPair();
  final localPeerId = await PeerId.fromPublicKey(localKeyPair.publicKey);

  late BasicHost host;
  late IpfsDHT dht;

  stderr.writeln('=== DHT + Relay Netem Test ===');
  stderr.writeln('Target: $targetAddrStr');
  stderr.writeln('Wait period: ${waitSecs}s');
  stderr.writeln('Local PeerId: ${localPeerId.toBase58()}');
  stderr.writeln('');

  try {
    // ── Phase 1: Create host + Start DHT ──
    // DHT must be started BEFORE connecting so that Identify advertises
    // /ipfs/kad/1.0.0 to Go. Otherwise Go marks us as "peer stopped dht"
    // and won't open DHT streams to us.
    stderr.writeln('Phase 1: Create host + Start DHT (matching production config)');
    try {
      host = await createHost(localKeyPair, targetAddrStr);
      stderr.writeln('  Dart host listening on: ${host.addrs}');

      // DHT in client mode with production options (dht_actor.dart:81-107)
      final dhtOptions = <DHTOption>[
        mode(DHTMode.client),
        maxPeersPerBucket(20),
        maxRoutingTableSize(10000),
        refreshInterval(const Duration(minutes: 5)),
        concurrency(6),
        resiliency(3),
        bucketSize(20),
        maxDhtMessageRetries(4),
        dhtMessageRetryInitialBackoff(const Duration(milliseconds: 200)),
        dhtMessageRetryMaxBackoff(const Duration(seconds: 5)),
        dhtMessageRetryBackoffFactor(1.5),
        filterLocalhostInResponses(true),
        routingTableLatencyTolerance(const Duration(seconds: 10)),
        routingTableRefreshQueryTimeout(const Duration(seconds: 30)),
        maxRecordAge(const Duration(hours: 24)),
        routingTableFilter((dht, peerId) => true),
        queryFilter((dht, addrInfo) => addrInfo.addrs.isNotEmpty),
        bootstrapPeers([AddrInfo(targetPeerId, [connectAddr])]),
      ];

      dht = await DHT.new_(host, MemoryProviderStore(), dhtOptions);
      await dht.start();
      report('Host + DHT started (client mode)', true);
    } catch (e) {
      report('Host + DHT start', false, '$e');
      exit(1); // Fatal
    }

    // ── Phase 2: Connect + Identify over UDX, add Go to routing table ──
    stderr.writeln('Phase 2: Connect + Identify over UDX');
    try {
      // Retry connect up to 3 times — swarm's internal 5s timeout may be
      // too tight for high-latency netem profiles (150ms+ RTT through NAT)
      const maxRetries = 3;
      for (int attempt = 1; attempt <= maxRetries; attempt++) {
        try {
          stderr.writeln('  Connect attempt $attempt/$maxRetries...');
          await host.connect(AddrInfo(targetPeerId, [connectAddr]),
              context: core_context.Context());
          break; // Success
        } catch (e) {
          if (attempt == maxRetries) rethrow;
          stderr.writeln('  Attempt $attempt failed ($e), retrying...');
          await Future.delayed(const Duration(seconds: 1));
        }
      }

      final protocols =
          await host.peerStore.protoBook.getProtocols(targetPeerId);
      final hasProtocols = protocols.isNotEmpty;
      report('Connect + Identify', hasProtocols,
          hasProtocols ? null : 'no protocols found');

      // Add Go to DHT routing table after successful connection
      await dht.routingTable.tryAddPeer(targetPeerId, queryPeer: false);
      final rtSize = await dht.routingTable.size();
      stderr.writeln('  DHT routing table size: $rtSize');
    } catch (e) {
      report('Connect + Identify', false, '$e');
      exit(1); // Fatal — can't continue without connection
    }

    // ── Phase 3: Baseline DHT findPeer ──
    stderr.writeln('Phase 3: Baseline DHT findPeer');
    try {
      final result = await dht
          .findPeer(targetPeerId)
          .timeout(const Duration(seconds: 15));
      final found = result != null && result.addrs.isNotEmpty;
      report('Baseline findPeer', found,
          found ? null : 'findPeer returned null or empty addrs');
    } catch (e) {
      report('Baseline findPeer', false, '$e');
    }

    // ── Phase 4: Make relay reservation ──
    stderr.writeln('Phase 4: Relay reservation (creates long-lived HOP stream)');
    try {
      final relayClient = host.circuitV2Client;
      if (relayClient == null) {
        report('Relay reservation', false,
            'CircuitV2Client is null (relay not enabled?)');
      } else {
        final reservation = await relayClient
            .reserve(targetPeerId)
            .timeout(const Duration(seconds: 30));
        report('Relay reservation', true,
            'expires: ${reservation.expire}, addrs: ${reservation.addrs.length}');
      }
    } catch (e) {
      report('Relay reservation', false, '$e');
    }

    // ── Phase 5: Wait for Go DHT RT refresh window ──
    stderr.writeln(
        'Phase 5: Waiting ${waitSecs}s (Go DHT RT refresh window)...');
    stderr.writeln(
        '  During this time, the relay HOP stream is open and Go may try');
    stderr.writeln('  opening DHT streams TO Dart — the production failure point.');
    await Future.delayed(Duration(seconds: waitSecs));
    report('Wait period (${waitSecs}s)', true);

    // ── Phase 6: Post-idle DHT findPeer + echo ──
    stderr.writeln('Phase 6: Post-idle DHT findPeer + echo');

    // 6a: DHT findPeer
    bool dhtOk = false;
    try {
      final result = await dht
          .findPeer(targetPeerId)
          .timeout(const Duration(seconds: 15));
      dhtOk = result != null;
      report('Post-idle findPeer', dhtOk,
          dhtOk ? null : 'findPeer returned null');
    } catch (e) {
      report('Post-idle findPeer', false, '$e');
    }

    // 6b: Second findPeer (verifies connection still healthy after idle)
    try {
      final result2 = await dht
          .findPeer(targetPeerId)
          .timeout(const Duration(seconds: 15));
      final ok = result2 != null && result2.addrs.isNotEmpty;
      report('Post-idle findPeer #2', ok,
          ok ? null : 'second findPeer returned null or empty addrs');
    } catch (e) {
      report('Post-idle findPeer #2', false, '$e');
    }
  } catch (e, s) {
    stderr.writeln('FATAL: $e');
    stderr.writeln(s);
    failed++;
  } finally {
    stderr.writeln('');
    stderr.writeln('=== Results: $passed passed, $failed failed ===');
    await dht.close();
    await host.close();
  }

  exit(failed > 0 ? 1 : 0);
}
