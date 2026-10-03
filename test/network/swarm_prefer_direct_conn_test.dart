import 'package:dart_libp2p/core/multiaddr.dart';
import 'package:dart_libp2p/core/network/context.dart';
import 'package:dart_libp2p/core/network/network.dart' show Reachability;
import 'package:dart_libp2p/core/network/rcmgr.dart';
import 'package:dart_libp2p/core/peer/addr_info.dart';
import 'package:dart_libp2p/p2p/host/eventbus/basic.dart' as p2p_event_bus;
import 'package:dart_libp2p/p2p/protocol/circuitv2/client/reservation.dart';
import 'package:dart_libp2p/p2p/transport/connection_manager.dart' as p2p_conn_mgr;
import 'package:dart_udx/dart_udx.dart';
import 'package:test/test.dart';

import '../real_net_stack.dart';

void main() {
  group('Swarm.dialPeer with direct and relayed connections', () {
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

    test('reuses the direct connection when a newer relayed one exists', () async {
      await a.host.connect(AddrInfo(b.peerId, b.listenAddrs));
      final direct = await a.host.network.dialPeer(Context(), b.peerId);
      expect(direct.remoteMultiaddr.hasProtocol('p2p-circuit'), isFalse);

      // Open a relayed connection to B, made after the direct one.
      await b.host.connect(AddrInfo(relay.peerId, relay.listenAddrs));
      await b.host.circuitV2Client!.reserve(relay.peerId);
      await a.host.connect(AddrInfo(relay.peerId, relay.listenAddrs));
      await a.host.peerStore.addrBook.clearAddrs(b.peerId);
      await a.host.peerStore.addrBook.addAddrs(
        b.peerId,
        [MultiAddr('${relay.listenAddrs.first}/p2p/${relay.peerId.toBase58()}/p2p-circuit')],
        const Duration(minutes: 5),
      );
      final relayed = await a.host.network.dialPeer(Context().withForceFreshDial('test'), b.peerId);
      expect(relayed.remoteMultiaddr.hasProtocol('p2p-circuit'), isTrue);

      final chosen = await a.host.network.dialPeer(Context(), b.peerId);
      expect(chosen.id, direct.id);
    }, timeout: const Timeout(Duration(seconds: 60)));
  });
}
