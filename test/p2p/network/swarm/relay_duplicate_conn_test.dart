/// Two connections to one peer through the same relay: the dialer opens
/// only one per relay, and a newer one never costs the peer a connection
/// that carries streams. Before, one dialPeer dialled the relay twice (the
/// peer's circuit address with and without its id), the dialer closed the
/// second as redundant and the peer closed the first in favour of the
/// second, so neither survived.
library;

import 'dart:async';
import 'dart:typed_data';

import 'package:dart_libp2p/core/host/host.dart';
import 'package:dart_libp2p/core/multiaddr.dart';
import 'package:dart_libp2p/core/network/conn.dart';
import 'package:dart_libp2p/core/network/context.dart';
import 'package:dart_libp2p/core/network/network.dart';
import 'package:dart_libp2p/core/network/rcmgr.dart';
import 'package:dart_libp2p/core/network/stream.dart';
import 'package:dart_libp2p/core/peer/addr_info.dart';
import 'package:dart_libp2p/core/peer/peer_id.dart';
import 'package:dart_libp2p/p2p/host/autonat/ambient_config.dart';
import 'package:dart_libp2p/p2p/host/eventbus/basic.dart';
import 'package:dart_libp2p/p2p/network/swarm/swarm.dart';
import 'package:dart_libp2p/p2p/transport/connection_manager.dart';
import 'package:dart_udx/dart_udx.dart';
import 'package:test/test.dart';

import '../../../real_net_stack.dart';

const _echo = '/test/relay-echo/1.0.0';

void main() {
  group('circuit addresses for one relay', () {
    const relay = '12D3KooWREzBR9cXLsF5dMQ2nFZc8ihhJ7c6NFWENZemoBr9h5nM';
    const other = '12D3KooWHvRcknexpTsdUw3mGWtqHkPkfZkD8NJFC6rVnQo8CKdz';
    const dest = '12D3KooWQYhTNQdmr3ArTeUHRYzFg94BKyTkoWBDWez9kSCVe2Xo';

    test('with and without the destination are one route', () {
      final kept = Swarm.deduplicateCircuitAddrs([
        MultiAddr('/ip4/10.0.0.1/udp/4001/udx/p2p/$relay/p2p-circuit'),
        MultiAddr('/ip4/10.0.0.1/udp/4001/udx/p2p/$relay/p2p-circuit/p2p/$dest'),
        MultiAddr('/ip6/::1/udp/4001/udx/p2p/$relay/p2p-circuit/p2p/$dest'),
      ]);

      expect(kept.map((a) => a.toString()), ['/ip4/10.0.0.1/udp/4001/udx/p2p/$relay/p2p-circuit']);
    });

    test('through another relay, or direct, are kept', () {
      final addrs = [
        MultiAddr('/ip4/10.0.0.1/udp/4001/udx/p2p/$relay/p2p-circuit'),
        MultiAddr('/ip4/10.0.0.2/udp/4001/udx/p2p/$other/p2p-circuit/p2p/$dest'),
        MultiAddr('/ip4/10.0.0.3/udp/4001/udx'),
      ];

      expect(Swarm.deduplicateCircuitAddrs(addrs), addrs);
    });
  });

  group('connections through one relay', () {
    late UDX udx;
    late Host relay;
    late Host a;
    late Host b;
    late List<MultiAddr> bThroughRelay;
    late List<MultiAddr> aThroughRelay;

    setUp(() async {
      udx = UDX();
      final resources = NullResourceManager();
      final connections = ConnectionManager();
      relay = (await createLibp2pNode(
        udxInstance: udx,
        resourceManager: resources,
        connManager: connections,
        hostEventBus: BasicBus(),
        enableRelay: true,
        forceReachability: Reachability.public,
        userAgentPrefix: 'relay',
      ))
          .host;
      final relayAddrs = [
        for (final addr in relay.addrs)
          if (!addr.hasProtocol('p2p-circuit')) '${addr.toString().replaceFirst('/0.0.0.0/', '/127.0.0.1/')}/p2p/${relay.id}'
      ];
      Future<Host> peer(String name) async => (await createLibp2pNode(
            udxInstance: udx,
            resourceManager: resources,
            connManager: connections,
            hostEventBus: BasicBus(),
            enableAutoRelay: true,
            userAgentPrefix: name,
            ambientAutoNATConfig: AmbientAutoNATv2Config(
              bootDelay: const Duration(milliseconds: 500),
              retryInterval: const Duration(seconds: 1),
              refreshInterval: const Duration(seconds: 5),
            ),
            relayServers: relayAddrs,
          ))
              .host;
      a = await peer('a');
      b = await peer('b');
      for (final host in [a, b]) {
        host.setStreamHandler(_echo, (stream, _) async {
          while (true) {
            final chunk = await stream.read();
            if (chunk.isEmpty) break;
            await stream.write(chunk);
          }
          await stream.close();
        });
      }
      bThroughRelay = await _circuitAddrs(b, relay.id);
      aThroughRelay = await _circuitAddrs(a, relay.id);
      // Each peer knows the other only through the relay, by the address
      // with its id and the one without, as identify and the DHT give them.
      await a.peerStore.addrBook.addAddrs(b.id, _bothForms(bThroughRelay, b.id), const Duration(hours: 1));
      await b.peerStore.addrBook.addAddrs(a.id, _bothForms(aThroughRelay, a.id), const Duration(hours: 1));
    });

    tearDown(() async {
      await Future.wait([a.close(), b.close()]);
      await relay.close();
    });

    test('a newer connection does not close one that carries a stream', () async {
      await a.connect(AddrInfo(b.id, const []));
      final held = await a.newStream(b.id, [_echo], Context());
      expect(await _echoed(held, 1), 1);

      // A dials again through the same relay while the first connection
      // carries the stream (identify has taught A B's direct address, which
      // a phone behind NAT could not dial).
      await a.peerStore.addrBook.clearAddrs(b.id);
      await a.peerStore.addrBook.addAddrs(b.id, _bothForms(bThroughRelay, b.id), const Duration(hours: 1));
      await a.network.dialPeer(Context().withForceFreshDial('test'), b.id);
      await Future<void>.delayed(const Duration(seconds: 2));

      expect(await _echoed(held, 2), 2, reason: 'the stream on the first connection still works');
      expect(_open(a, b.id).where((c) => c.remoteMultiaddr.hasProtocol('p2p-circuit')), hasLength(2),
          reason: 'the second dial went through the relay');
      expect(_open(b, a.id), isNotEmpty);
    }, timeout: const Timeout(Duration(seconds: 90)));

    test('peers that dial each other at once keep a connection', () async {
      await Future.wait([a.connect(AddrInfo(b.id, const [])), b.connect(AddrInfo(a.id, const []))]);
      await Future<void>.delayed(const Duration(seconds: 2));

      expect(_open(a, b.id), isNotEmpty, reason: 'a still holds a connection to b');
      expect(_open(b, a.id), isNotEmpty, reason: 'b still holds a connection to a');
      final stream = await a.newStream(b.id, [_echo], Context()).timeout(const Duration(seconds: 10));
      expect(await _echoed(stream, 3), 3);
    }, timeout: const Timeout(Duration(seconds: 90)));

    test('one dial opens one connection through the relay', () async {
      await a.connect(AddrInfo(b.id, const []));
      await Future<void>.delayed(const Duration(seconds: 2));

      expect(_open(a, b.id), hasLength(1));
      expect(_open(b, a.id), hasLength(1));
      final stream = await a.newStream(b.id, [_echo], Context()).timeout(const Duration(seconds: 10));
      expect(await _echoed(stream, 4), 4);
    }, timeout: const Timeout(Duration(seconds: 90)));
  });
}

/// [host]'s addresses through [relay], once AutoRelay holds a reservation.
Future<List<MultiAddr>> _circuitAddrs(Host host, PeerId relay) async {
  final deadline = DateTime.now().add(const Duration(seconds: 30));
  while (DateTime.now().isBefore(deadline)) {
    final circuit = [
      for (final addr in host.addrs)
        if (addr.hasProtocol('p2p-circuit') && addr.toString().contains(relay.toString())) addr
    ];
    if (circuit.isNotEmpty) return circuit;
    await Future<void>.delayed(const Duration(milliseconds: 250));
  }
  throw TimeoutException('${host.id} holds no reservation on the relay');
}

/// Each of [circuit] without [peer]'s id on the end and with it.
List<MultiAddr> _bothForms(List<MultiAddr> circuit, PeerId peer) {
  final suffix = '/p2p/$peer';
  return [
    for (final addr in circuit.map((a) => a.toString()))
      for (final bare in [addr.endsWith(suffix) ? addr.substring(0, addr.length - suffix.length) : addr])
        ...[MultiAddr(bare), MultiAddr('$bare$suffix')]
  ];
}

List<Conn> _open(Host host, PeerId peer) => [
      for (final conn in host.network.connsToPeer(peer))
        if (!conn.isClosed) conn
    ];

/// Sends [byte] on [stream] and reads it back.
Future<int> _echoed(P2PStream stream, int byte) async {
  await stream.write(Uint8List.fromList([byte]));
  final reply = await stream.read().timeout(const Duration(seconds: 10));
  return reply.single;
}
