import 'dart:async';

import 'package:dart_libp2p/config/config.dart' as p2p_config;
import 'package:dart_libp2p/core/crypto/ed25519.dart' as crypto_ed25519;
import 'package:dart_libp2p/core/host/host.dart';
import 'package:dart_libp2p/core/multiaddr.dart';
import 'package:dart_libp2p/core/network/network.dart' show Connectedness;
import 'package:dart_libp2p/core/network/notifiee.dart';
import 'package:dart_libp2p/core/network/rcmgr.dart' show NullResourceManager;
import 'package:dart_libp2p/core/peer/addr_info.dart';
import 'package:dart_libp2p/core/peer/peer_id.dart';
import 'package:dart_libp2p/p2p/security/noise/noise_protocol.dart';
import 'package:dart_libp2p/p2p/transport/connection_manager.dart' as p2p_conn_manager;
import 'package:dart_libp2p/p2p/transport/tcp_transport.dart';
import 'package:dart_libp2p/p2p/transport/udx_transport.dart';
import 'package:test/test.dart';

Future<Host> _host(String transport) async {
  final keyPair = await crypto_ed25519.generateEd25519KeyPair();
  final connManager = p2p_conn_manager.ConnectionManager();
  final host = await p2p_config.Libp2p.new_([
    p2p_config.Libp2p.identity(keyPair),
    p2p_config.Libp2p.connManager(connManager),
    if (transport == 'udx')
      p2p_config.Libp2p.transport(UDXTransport(connManager: connManager))
    else
      p2p_config.Libp2p.transport(TCPTransport(connManager: connManager, resourceManager: NullResourceManager())),
    p2p_config.Libp2p.security(await NoiseSecurity.create(keyPair)),
    p2p_config.Libp2p.listenAddrs([
      MultiAddr(transport == 'udx' ? '/ip4/127.0.0.1/udp/0/udx' : '/ip4/127.0.0.1/tcp/0'),
    ]),
  ]);
  await host.start();
  return host;
}

/// Records the peers that [host]'s network reports disconnected.
List<PeerId> _watchDisconnects(Host host) {
  final disconnected = <PeerId>[];
  host.network.notify(NotifyBundle(
    disconnectedF: (network, conn) => disconnected.add(conn.remotePeer),
  ));
  return disconnected;
}

/// Waits until [condition] is true, or fails after [timeout].
Future<void> _eventually(bool Function() condition,
    {Duration timeout = const Duration(seconds: 10)}) async {
  final deadline = DateTime.now().add(timeout);
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) {
      fail('condition not met within $timeout');
    }
    await Future.delayed(const Duration(milliseconds: 50));
  }
}

void main() {
  for (final transport in ['tcp', 'udx']) {
    group('Swarm disconnect notification ($transport)', () {
      late Host a;
      late Host b;
      late List<PeerId> aDisconnects;
      late List<PeerId> bDisconnects;

      setUp(() async {
        a = await _host(transport);
        b = await _host(transport);
        aDisconnects = _watchDisconnects(a);
        bDisconnects = _watchDisconnects(b);
        await a.connect(AddrInfo(b.id, b.network.listenAddresses));
        await _eventually(() => b.network.connectedness(a.id) == Connectedness.connected);
      });

      tearDown(() async {
        await a.close();
        await b.close();
      });

      test('closePeer on this side notifies once', () async {
        await a.network.closePeer(b.id);

        expect(aDisconnects, [b.id]);
        expect(a.network.connectedness(b.id), Connectedness.notConnected);
        await Future.delayed(const Duration(milliseconds: 500));
        expect(aDisconnects, [b.id], reason: 'reported more than once');
      });

      test('a remote close notifies this side', () async {
        await b.network.closePeer(a.id);

        await _eventually(() => aDisconnects.isNotEmpty);
        expect(aDisconnects, [b.id]);
        expect(bDisconnects, [a.id]);
        expect(a.network.connectedness(b.id), Connectedness.notConnected);
      });

      test('closing the network notifies for each connection', () async {
        await a.network.close();

        expect(aDisconnects, [b.id]);
        await _eventually(() => bDisconnects.isNotEmpty);
        expect(bDisconnects, [a.id]);
      });
    });
  }
}
