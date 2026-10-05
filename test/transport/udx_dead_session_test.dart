import 'dart:async';
import 'dart:io' show InternetAddress, RawDatagramSocket;

import 'package:dart_libp2p/config/config.dart' as p2p_config;
import 'package:dart_libp2p/core/crypto/ed25519.dart' as crypto_ed25519;
import 'package:dart_libp2p/core/host/host.dart';
import 'package:dart_libp2p/core/multiaddr.dart';
import 'package:dart_libp2p/core/peer/addr_info.dart';
import 'package:dart_libp2p/p2p/security/noise/noise_protocol.dart';
import 'package:dart_libp2p/p2p/transport/connection_manager.dart' as p2p_conn_manager;
import 'package:dart_libp2p/p2p/transport/udx_transport.dart';
import 'package:test/test.dart';

Future<(Host, UDXTransport)> _host() async {
  final keyPair = await crypto_ed25519.generateEd25519KeyPair();
  final connManager = p2p_conn_manager.ConnectionManager();
  final transport = UDXTransport(connManager: connManager);
  final host = await p2p_config.Libp2p.new_([
    p2p_config.Libp2p.identity(keyPair),
    p2p_config.Libp2p.connManager(connManager),
    p2p_config.Libp2p.transport(transport),
    p2p_config.Libp2p.security(await NoiseSecurity.create(keyPair)),
    p2p_config.Libp2p.listenAddrs([MultiAddr('/ip4/127.0.0.1/udp/0/udx')]),
  ]);
  await host.start();
  return (host, transport);
}

/// Waits until [condition] is true, for at most [limit]. Returns how long it
/// took, or null if it did not become true.
Future<Duration?> _waitFor(bool Function() condition, Duration limit) async {
  final watch = Stopwatch()..start();
  while (watch.elapsed < limit) {
    if (condition()) return watch.elapsed;
    await Future.delayed(const Duration(milliseconds: 50));
  }
  return null;
}

void main() {
  // When the UDX session under a connection closes, the swarm must drop the
  // connection at once. Before 4.1.5, yamux's read loop waited forever on the
  // closed session, and the connection stayed in the swarm until a write or
  // a keepalive ping failed, about 30 s later. Messages pushed to the peer in
  // that time were lost.
  group('a closed UDX session', () {
    late Host a;
    late Host b;
    late UDXTransport aTransport;

    setUp(() async {
      (a, aTransport) = await _host();
      (b, _) = await _host();
      await a.connect(AddrInfo(b.id, b.network.listenAddresses));
      expect(a.network.connsToPeer(b.id), isNotEmpty);
      // Let Identify finish, so that the connection is idle and yamux's read
      // loop waits for data, as on a real idle connection.
      await Future.delayed(const Duration(seconds: 1));
    });

    tearDown(() async {
      await a.close();
      await b.close();
    });

    test('is dropped from the swarm when the session closes', () async {
      final session = aTransport.dialerSessions.single;
      await session.close();
      final took = await _waitFor(() => a.network.connsToPeer(b.id).isEmpty, const Duration(seconds: 5));
      expect(took, isNotNull, reason: 'the swarm kept the connection after its session closed');
    });

    test('is dropped from the swarm when its UDP socket closes', () async {
      final session = aTransport.dialerSessions.single;
      await session.udpSocket.close();
      final took = await _waitFor(() => a.network.connsToPeer(b.id).isEmpty, const Duration(seconds: 5));
      expect(took, isNotNull, reason: 'the swarm kept the connection after its UDP socket closed');
      expect(session.isClosed, isTrue);
    });
  });

  // A dial to an address that never answers must fail after one dial
  // timeout. Before 4.1.5 the handshake was retried 4 times inside each of
  // 4 dial attempts, so one dead address held a dial for 16 timeouts.
  test('a dial to an address that never answers fails after one timeout', () async {
    final silent = await RawDatagramSocket.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(silent.close);
    final transport = UDXTransport(connManager: p2p_conn_manager.ConnectionManager());
    addTearDown(transport.dispose);

    final watch = Stopwatch()..start();
    await expectLater(
      transport.dial(MultiAddr('/ip4/127.0.0.1/udp/${silent.port}/udx'), timeout: const Duration(seconds: 1)),
      throwsA(anything),
    );
    expect(watch.elapsed, lessThan(const Duration(seconds: 3)));
  });
}
