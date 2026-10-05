import 'dart:async';
import 'dart:typed_data';

import 'package:dart_libp2p/config/config.dart' as p2p_config;
import 'package:dart_libp2p/core/crypto/ed25519.dart' as crypto_ed25519;
import 'package:dart_libp2p/core/host/host.dart';
import 'package:dart_libp2p/core/multiaddr.dart';
import 'package:dart_libp2p/core/network/context.dart';
import 'package:dart_libp2p/core/network/stream.dart';
import 'package:dart_libp2p/core/peer/addr_info.dart';
import 'package:dart_libp2p/p2p/security/noise/noise_protocol.dart';
import 'package:dart_libp2p/p2p/transport/connection_manager.dart' as p2p_conn_manager;
import 'package:dart_libp2p/p2p/transport/udx_transport.dart';
import 'package:test/test.dart';

const _echo = '/test/echo/1.0.0';

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
  host.setStreamHandler(_echo, (stream, _) async {
    final data = await stream.read();
    await stream.write(data);
    await stream.close();
  });
  return (host, transport);
}

Future<Uint8List> _roundTrip(Host from, Host to) async {
  final P2PStream stream = await from.newStream(to.id, [_echo], Context());
  await stream.write(Uint8List.fromList([1, 2, 3]));
  final reply = await stream.read().timeout(const Duration(seconds: 5));
  await stream.close();
  return reply;
}

void main() {
  // Two dials to the same peer at once (for example, two services that start
  // together) shared one UDX socket. The second dial waited on the socket the
  // first dial had already set up, timed out after 15 s, and its cleanup
  // closed the shared socket. The connection that the first dial made then
  // died 30 s after it opened, with no close from the peer.
  group('concurrent dials to one peer', () {
    late Host a;
    late Host b;
    late UDXTransport aTransport;

    setUp(() async {
      (a, aTransport) = await _host();
      (b, _) = await _host();
    });

    tearDown(() async {
      await a.close();
      await b.close();
    });

    test('give one connection that stays alive', () async {
      final info = AddrInfo(b.id, b.network.listenAddresses);
      await Future.wait([a.connect(info), a.connect(info)]).timeout(const Duration(seconds: 10));

      expect(a.network.connsToPeer(b.id), hasLength(1));
      expect(await _roundTrip(a, b), [1, 2, 3]);

      // Longer than the 15-s dial timeout plus the 30-s UDX idle timeout.
      await Future.delayed(const Duration(seconds: 45));

      expect(a.network.connsToPeer(b.id), isNotEmpty, reason: 'the connection died');
      expect(await _roundTrip(a, b), [1, 2, 3]);
    }, timeout: const Timeout(Duration(seconds: 90)));

    // Below the swarm, each transport dial is its own UDX connection, so
    // closing one does not close the other.
    test('at the transport are separate UDX connections', () async {
      final addr = b.network.listenAddresses.first;
      final conns = await Future.wait([aTransport.dial(addr), aTransport.dial(addr)]);
      addTearDown(() async {
        for (final c in conns) {
          await c.close();
        }
      });

      final sessions = aTransport.dialerSessions.toList();
      expect(sessions, hasLength(2));
      expect(identical(sessions[0].udpSocket, sessions[1].udpSocket), isFalse);

      await conns[0].close();
      await Future.delayed(const Duration(milliseconds: 500));
      expect(conns[1].isClosed, isFalse);
      expect(sessions[1].udpSocket.closing, isFalse);
    });
  });
}
