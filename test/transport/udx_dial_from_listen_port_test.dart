import 'package:dart_libp2p/config/config.dart' as p2p_config;
import 'package:dart_libp2p/core/crypto/ed25519.dart' as crypto_ed25519;
import 'package:dart_libp2p/core/host/host.dart';
import 'package:dart_libp2p/core/multiaddr.dart';
import 'package:dart_libp2p/core/peer/addr_info.dart';
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
    p2p_config.Libp2p.listenAddrs([MultiAddr('/ip4/0.0.0.0/udp/0/udx')]),
  ]);
  await host.start();
  return host;
}

int _udpPort(MultiAddr a) => int.parse(a.valueForProtocol('udp')!);

void main() {
  // A host behind NAT learns its public address from what the peers it
  // dials observe, and that is only useful for the listen socket's NAT
  // mapping. So an ordinary dial must leave from the listen socket.
  test('an ordinary UDX dial leaves from the listener port', () async {
    final a = await _host();
    final b = await _host();
    addTearDown(() async {
      await a.close();
      await b.close();
    });

    final listenPort = _udpPort(a.network.listenAddresses.firstWhere((m) => m.hasProtocol('udx')));
    final bAddr = b.addrs.firstWhere((m) => m.hasProtocol('udx'));
    await a.connect(AddrInfo(b.id, [bAddr]));

    final conns = a.network.connsToPeer(b.id);
    expect(conns, isNotEmpty);
    expect(_udpPort(conns.first.localMultiaddr), listenPort);

    // b sees a coming from a's listen port, which is the address b reports
    // back to a through Identify.
    final bConns = b.network.connsToPeer(a.id);
    expect(bConns, isNotEmpty);
    expect(_udpPort(bConns.first.remoteMultiaddr), listenPort);
  });
}
