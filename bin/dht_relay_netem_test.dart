/// DHT + Relay netem test for reproducing stream failure under network pressure.
///
/// Usage: dart run bin/dht_relay_netem_test.dart <multiaddr/p2p/peerid> [wait_secs]
///
/// Runs 6 test phases sequentially:
///   1. Connect + Identify over UDX
///   2. Start DHT (server mode), add Go to routing table
///   3. Baseline DHT findPeer (should succeed)
///   4. Make relay reservation (creates long-lived HOP stream)
///   5. Wait for Go DHT RT refresh window (production failure point)
///   6. Post-idle DHT findPeer + echo (the failure point)
///
/// Exit code: 0 = all phases pass, 1 = failure (bug reproduced).
import 'dart:io';
import 'dart:typed_data';

import 'package:dart_udx/dart_udx.dart';

import 'package:dart_libp2p/core/crypto/ed25519.dart' as crypto_ed25519;
import 'package:dart_libp2p/core/crypto/keys.dart';
import 'package:dart_libp2p/core/multiaddr.dart';
import 'package:dart_libp2p/core/network/conn.dart';
import 'package:dart_libp2p/core/network/transport_conn.dart';
import 'package:dart_libp2p/core/peer/peer_id.dart';
import 'package:dart_libp2p/core/peer/addr_info.dart';
import 'package:dart_libp2p/core/network/context.dart' as core_context;
import 'package:dart_libp2p/config/config.dart' as p2p_config;
import 'package:dart_libp2p/config/stream_muxer.dart';
import 'package:dart_libp2p/p2p/host/basic/basic_host.dart';
import 'package:dart_libp2p/p2p/protocol/circuitv2/client/reservation.dart';
import 'package:dart_libp2p/p2p/security/noise/noise_protocol.dart';
import 'package:dart_libp2p/p2p/transport/connection_manager.dart';
import 'package:dart_libp2p/p2p/transport/multiplexing/multiplexer.dart';
import 'package:dart_libp2p/p2p/transport/multiplexing/yamux/session.dart';
import 'package:dart_libp2p/p2p/transport/udx_transport.dart';
import 'package:dart_libp2p/p2p/multiaddr/protocol.dart';
import 'package:dart_libp2p_kad_dht/dart_libp2p_kad_dht.dart';

const String echoProtocol = '/echo/1.0.0';

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

/// Yamux muxer provider matching production config.
class _TestYamuxMuxerProvider extends StreamMuxer {
  _TestYamuxMuxerProvider({required MultiplexerConfig yamuxConfig})
      : super(
          id: YamuxConstants.protocolId,
          muxerFactory: (Conn secureConn, bool isClient) {
            if (secureConn is! TransportConn) {
              throw ArgumentError(
                  'YamuxMuxer factory expects a TransportConn, got ${secureConn.runtimeType}');
            }
            return YamuxSession(secureConn, yamuxConfig, isClient, null, null);
          },
        );
}

Future<BasicHost> createHost(KeyPair keyPair) async {
  final connMgr = ConnectionManager();
  final udxInstance = UDX();

  final yamuxConfig = MultiplexerConfig(
    keepAliveInterval: const Duration(seconds: 3),
    maxStreamWindowSize: 1024 * 1024,
    initialStreamWindowSize: 256 * 1024,
    streamWriteTimeout: const Duration(seconds: 10),
    maxStreams: 256,
  );
  final muxerDef = _TestYamuxMuxerProvider(yamuxConfig: yamuxConfig);

  final config = p2p_config.Config()
    ..peerKey = keyPair
    ..securityProtocols = [await NoiseSecurity.create(keyPair)]
    ..muxers = [muxerDef]
    ..transports = [UDXTransport(connManager: connMgr, udxInstance: udxInstance)]
    ..connManager = connMgr
    ..enableRelay = true;
  config.addrsFactory = (addrs) => addrs;
  // Listen on all interfaces so Go can open streams back to us through NAT
  config.listenAddrs = [MultiAddr('/ip4/0.0.0.0/udp/0/udx')];

  final host = await config.newNode() as BasicHost;
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
  final connectAddr = targetMa.decapsulate(Protocols.p2p.name);

  final localKeyPair = await crypto_ed25519.generateEd25519KeyPair();
  final localPeerId = await PeerId.fromPublicKey(localKeyPair.publicKey);

  late BasicHost host;
  IpfsDHT? dht;

  stderr.writeln('=== DHT + Relay Netem Test ===');
  stderr.writeln('Target: $targetAddrStr');
  stderr.writeln('Wait period: ${waitSecs}s');
  stderr.writeln('Local PeerId: ${localPeerId.toBase58()}');
  stderr.writeln('');

  try {
    // ── Phase 1: Connect + Identify over UDX ──
    stderr.writeln('Phase 1: Connect + Identify over UDX');
    try {
      host = await createHost(localKeyPair);
      stderr.writeln('  Dart host listening on: ${host.addrs}');

      // Retry connect up to 3 times — swarm's internal 5s timeout may be
      // too tight for high-latency netem profiles (150ms+ RTT through NAT)
      const maxRetries = 3;
      for (int attempt = 1; attempt <= maxRetries; attempt++) {
        try {
          stderr.writeln('  Connect attempt $attempt/$maxRetries...');
          await host.connect(AddrInfo(targetPeerId, [connectAddr!]),
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
    } catch (e) {
      report('Connect + Identify', false, '$e');
      exit(1); // Fatal — can't continue without connection
    }

    // ── Phase 2: Start DHT (server mode), add Go to routing table ──
    stderr.writeln('Phase 2: Start DHT in server mode');
    try {
      dht = IpfsDHT(
        host: host,
        providerStore: MemoryProviderStore(),
        options: DHTOptions(mode: DHTMode.server),
      );
      await dht.start();
      await dht.routingTable.tryAddPeer(targetPeerId, queryPeer: false);

      final rtSize = await dht.routingTable.size();
      report('DHT started (server mode, RT size: $rtSize)', rtSize > 0,
          rtSize > 0 ? null : 'routing table empty after adding peer');
    } catch (e) {
      report('DHT start', false, '$e');
    }

    // ── Phase 3: Baseline DHT findPeer ──
    stderr.writeln('Phase 3: Baseline DHT findPeer');
    try {
      final result = await dht!
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
      final result = await dht!
          .findPeer(targetPeerId)
          .timeout(const Duration(seconds: 15));
      dhtOk = result != null;
      report('Post-idle findPeer', dhtOk,
          dhtOk ? null : 'findPeer returned null');
    } catch (e) {
      report('Post-idle findPeer', false, '$e');
    }

    // 6b: Echo test (direct UDX connection health)
    try {
      final stream = await host
          .newStream(targetPeerId, [echoProtocol], core_context.Context())
          .timeout(const Duration(seconds: 15));

      final payload = Uint8List(32);
      for (int i = 0; i < 32; i++) {
        payload[i] = i & 0xFF;
      }
      await stream.write(payload);

      final response = await stream.read().timeout(const Duration(seconds: 10));

      bool echoOk = response.length == payload.length;
      if (echoOk) {
        for (int i = 0; i < payload.length; i++) {
          if (response[i] != payload[i]) {
            echoOk = false;
            break;
          }
        }
      }

      if (!stream.isClosed) await stream.close();
      report('Post-idle echo', echoOk,
          echoOk ? null : 'got ${response.length} bytes, expected ${payload.length}');
    } catch (e) {
      report('Post-idle echo', false, '$e');
    }
  } catch (e, s) {
    stderr.writeln('FATAL: $e');
    stderr.writeln(s);
    failed++;
  } finally {
    stderr.writeln('');
    stderr.writeln('=== Results: $passed passed, $failed failed ===');
    if (dht != null) {
      await dht.close();
    }
    await host.close();
  }

  exit(failed > 0 ? 1 : 0);
}
