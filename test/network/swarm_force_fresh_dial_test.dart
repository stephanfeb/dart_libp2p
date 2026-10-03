import 'package:dart_libp2p/core/network/context.dart';
import 'package:dart_libp2p/core/network/rcmgr.dart';
import 'package:dart_libp2p/core/peer/addr_info.dart';
import 'package:dart_libp2p/p2p/host/eventbus/basic.dart' as p2p_event_bus;
import 'package:dart_libp2p/p2p/transport/connection_manager.dart' as p2p_conn_mgr;
import 'package:dart_udx/dart_udx.dart';
import 'package:test/test.dart';

import '../real_net_stack.dart';

void main() {
  group('Swarm.dialPeer with forceFreshDial', () {
    late Libp2pNode a;
    late Libp2pNode b;

    setUp(() async {
      final udx = UDX();
      final resourceManager = NullResourceManager();
      final connManager = p2p_conn_mgr.ConnectionManager();
      a = await createLibp2pNode(
        udxInstance: udx,
        resourceManager: resourceManager,
        connManager: connManager,
        hostEventBus: p2p_event_bus.BasicBus(),
      );
      b = await createLibp2pNode(
        udxInstance: udx,
        resourceManager: resourceManager,
        connManager: connManager,
        hostEventBus: p2p_event_bus.BasicBus(),
      );
      await a.host.connect(AddrInfo(b.peerId, b.listenAddrs));
    });

    tearDown(() async {
      await a.host.close();
      await b.host.close();
    });

    test('dials a new connection instead of reusing a healthy one', () async {
      final existing = await a.host.network.dialPeer(Context(), b.peerId);
      expect(
        (await a.host.network.dialPeer(Context(), b.peerId)).id,
        existing.id,
        reason: 'without the option a healthy connection is reused',
      );

      final fresh = await a.host.network.dialPeer(
        Context().withForceFreshDial('connection observed broken'),
        b.peerId,
      );

      expect(fresh.id, isNot(existing.id));
      expect(a.host.network.connsToPeer(b.peerId).map((c) => c.id), contains(fresh.id));
    }, timeout: const Timeout(Duration(seconds: 60)));
  });
}
