import 'package:dart_libp2p/config/config.dart' as p2p_config;
import 'package:dart_libp2p/core/crypto/ed25519.dart' as crypto_ed25519;
import 'package:dart_libp2p/core/host/host.dart';
import 'package:dart_libp2p/core/multiaddr.dart';
import 'package:dart_libp2p/core/peer/addr_info.dart';
import 'package:dart_libp2p/p2p/protocol/ping/ping.dart';
import 'package:dart_libp2p/p2p/security/noise/noise_protocol.dart';
import 'package:dart_libp2p/p2p/transport/connection_manager.dart' as p2p_conn_manager;
import 'package:dart_libp2p/p2p/transport/udx_transport.dart';
import 'package:test/test.dart';

Future<Host> _host() async {
  final keyPair = await crypto_ed25519.generateEd25519KeyPair();
  final connManager = p2p_conn_manager.ConnectionManager();
  final host = await p2p_config.Libp2p.new_([
    p2p_config.Libp2p.identity(keyPair),
    p2p_config.Libp2p.connManager(connManager),
    p2p_config.Libp2p.transport(UDXTransport(connManager: connManager)),
    p2p_config.Libp2p.security(await NoiseSecurity.create(keyPair)),
    p2p_config.Libp2p.listenAddrs([MultiAddr('/ip4/127.0.0.1/udp/0/udx')]),
    p2p_config.Libp2p.ping(true),
  ]);
  await host.start();
  return host;
}

void main() {
  group('Ping Protocol', () {
    late Host host1;
    late Host host2;

    setUp(() async {
      host1 = await _host();
      host2 = await _host();
      await host1.connect(AddrInfo(host2.id, host2.network.listenAddresses));
    });

    tearDown(() async {
      await host1.close();
      await host2.close();
    });

    test('PingService measures a round-trip time in both directions', () async {
      final there = await PingService(host1).ping(host2.id).first;
      expect(there.hasError, isFalse, reason: '${there.error}');
      expect(there.rtt, isNotNull);
      expect(there.rtt! > Duration.zero, isTrue);

      final back = await PingService(host2).ping(host1.id).first;
      expect(back.hasError, isFalse, reason: '${back.error}');
      expect(back.rtt, isNotNull);
    });

    test('a peer keeps answering pings on one stream', () async {
      final results = await PingService(host1).ping(host2.id).take(3).toList();
      expect(results, hasLength(3));
      for (final r in results) {
        expect(r.hasError, isFalse, reason: '${r.error}');
      }
    });
  });
}
