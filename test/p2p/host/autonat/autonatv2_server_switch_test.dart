import 'package:dart_libp2p/config/config.dart' as p2p_config;
import 'package:dart_libp2p/core/crypto/ed25519.dart' as crypto_ed25519;
import 'package:dart_libp2p/core/multiaddr.dart';
import 'package:dart_libp2p/core/protocol/autonatv2/autonatv2.dart';
import 'package:dart_libp2p/p2p/host/basic/basic_host.dart';
import 'package:dart_libp2p/p2p/security/noise/noise_protocol.dart';
import 'package:dart_libp2p/p2p/transport/connection_manager.dart';
import 'package:dart_libp2p/p2p/transport/udx_transport.dart';
import 'package:test/test.dart';

Future<BasicHost> _host({bool? autoNAT = true, bool? server}) async {
  final keyPair = await crypto_ed25519.generateEd25519KeyPair();
  final connMgr = ConnectionManager();
  final host = await p2p_config.Libp2p.new_([
    p2p_config.Libp2p.identity(keyPair),
    p2p_config.Libp2p.connManager(connMgr),
    p2p_config.Libp2p.transport(UDXTransport(connManager: connMgr)),
    p2p_config.Libp2p.security(await NoiseSecurity.create(keyPair)),
    p2p_config.Libp2p.listenAddrs([MultiAddr('/ip4/127.0.0.1/udp/0/udx')]),
    if (autoNAT != null) p2p_config.Libp2p.autoNAT(autoNAT),
    if (server != null) p2p_config.Libp2p.autoNATv2Server(server),
  ]) as BasicHost;
  await host.start();
  return host;
}

void main() {
  // A host behind NAT, such as a phone, can keep checking its own
  // reachability without answering other peers' checks.
  group('AutoNAT v2 server switch', () {
    test('the server runs by default', () async {
      final host = await _host();
      addTearDown(host.close);

      expect(await host.mux.protocols(), contains(AutoNATv2Protocols.dialProtocol));
      expect(host.autoNATService, isNotNull);
    });

    test('autoNATv2Server(false) keeps the client and drops the server', () async {
      final host = await _host(server: false);
      addTearDown(host.close);

      expect(await host.mux.protocols(), isNot(contains(AutoNATv2Protocols.dialProtocol)));
      // The client still answers dial-backs and the ambient prober runs.
      expect(await host.mux.protocols(), contains(AutoNATv2Protocols.dialBackProtocol));
      expect(host.autoNATService, isNotNull);
    });
  });

  // Libp2p.new_ turned AutoNAT on after the options were applied, so
  // autoNAT(false) had no effect (dart-libp2p-idf).
  group('AutoNAT option', () {
    test('is on when no option sets it', () async {
      final host = await _host(autoNAT: null);
      addTearDown(host.close);

      expect(host.autoNATService, isNotNull);
    });

    test('autoNAT(false) turns it off', () async {
      final host = await _host(autoNAT: false);
      addTearDown(host.close);

      expect(host.autoNATService, isNull);
      final protocols = await host.mux.protocols();
      expect(protocols, isNot(contains(AutoNATv2Protocols.dialProtocol)));
      expect(protocols, isNot(contains(AutoNATv2Protocols.dialBackProtocol)));
    });
  });
}
