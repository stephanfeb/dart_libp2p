import 'package:dart_libp2p/core/multiaddr.dart';
import 'package:dart_libp2p/core/network/context.dart';
import 'package:dart_libp2p/core/network/network.dart' show Reachability;
import 'package:dart_libp2p/core/network/rcmgr.dart';
import 'package:dart_libp2p/core/peer/addr_info.dart';
import 'package:dart_libp2p/p2p/host/eventbus/basic.dart' as p2p_event_bus;
import 'package:dart_libp2p/p2p/network/swarm/swarm.dart';
import 'package:dart_libp2p/p2p/protocol/circuitv2/client/reservation.dart';
import 'package:dart_libp2p/p2p/network/swarm/swarm_conn.dart';
import 'package:dart_libp2p/p2p/transport/connection_manager.dart' as p2p_conn_mgr;
import 'package:dart_libp2p/p2p/network/swarm/connection_health.dart' show ConnectionHealthState;
import 'package:dart_udx/dart_udx.dart';
import 'package:test/test.dart';

import '../real_net_stack.dart';

void main() {
  group('Swarm connection health', () {
    late Libp2pNode relay;
    late Libp2pNode a;
    late Libp2pNode b;

    setUp(() async {
      final udx = UDX();
      final resourceManager = NullResourceManager();
      final connManager = p2p_conn_mgr.ConnectionManager();
      Future<Libp2pNode> node({bool enableRelay = false, Reachability? reachability}) => createLibp2pNode(
            udxInstance: udx,
            resourceManager: resourceManager,
            connManager: connManager,
            hostEventBus: p2p_event_bus.BasicBus(),
            enableRelay: enableRelay,
            enableAutoRelay: !enableRelay,
            forceReachability: reachability,
          );
      relay = await node(enableRelay: true, reachability: Reachability.public);
      a = await node();
      b = await node();
      await Future.delayed(const Duration(milliseconds: 500));
    });

    tearDown(() async {
      await a.host.close();
      await b.host.close();
      await relay.host.close();
    });

    /// Makes a relayed connection from A to B through the relay.
    Future<SwarmConn> dialThroughRelay() async {
      await b.host.connect(AddrInfo(relay.peerId, relay.listenAddrs));
      await b.host.circuitV2Client!.reserve(relay.peerId);
      await a.host.connect(AddrInfo(relay.peerId, relay.listenAddrs));
      await a.host.peerStore.addrBook.clearAddrs(b.peerId);
      await a.host.peerStore.addrBook.addAddrs(
        b.peerId,
        [MultiAddr('${relay.listenAddrs.first}/p2p/${relay.peerId.toBase58()}/p2p-circuit')],
        const Duration(minutes: 5),
      );
      final conn = await a.host.network.dialPeer(Context().withForceFreshDial('test'), b.peerId);
      expect(conn.remoteMultiaddr.hasProtocol('p2p-circuit'), isTrue);
      return conn as SwarmConn;
    }

    // Health was kept for each peer, not for each connection. A failed
    // relayed connection marked the peer as failed, and the next dialPeer
    // closed the peer's working direct connection too.
    test('a failed relayed connection does not condemn the direct one', () async {
      await a.host.connect(AddrInfo(b.peerId, b.listenAddrs));
      final direct = await a.host.network.dialPeer(Context(), b.peerId);
      expect(direct.remoteMultiaddr.hasProtocol('p2p-circuit'), isFalse);
      final relayed = await dialThroughRelay();

      (a.host.network as Swarm).onConnectionHealthChanged(relayed, ConnectionHealthState.failed);
      await Future.delayed(const Duration(milliseconds: 200));

      final chosen = await a.host.network.dialPeer(Context(), b.peerId);
      expect(chosen.id, direct.id);
      expect(direct.isClosed, isFalse);
    }, timeout: const Timeout(Duration(seconds: 60)));

    // The peer that accepted a relayed connection uses it to reach the
    // dialer; it does not dial a new one.
    test('dialPeer reuses an inbound relayed connection', () async {
      final relayed = await dialThroughRelay();
      await Future.delayed(const Duration(milliseconds: 300));

      final inbound = b.host.network.connsToPeer(a.peerId);
      expect(inbound, hasLength(1));
      final chosen = await b.host.network.dialPeer(Context(), a.peerId);
      expect(chosen.id, inbound.single.id);
      expect(chosen.remoteMultiaddr.hasProtocol('p2p-circuit'), isTrue);
      expect(relayed.isClosed, isFalse);
    }, timeout: const Timeout(Duration(seconds: 60)));
  });
}
