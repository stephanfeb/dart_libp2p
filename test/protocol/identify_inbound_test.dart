import 'dart:async';

import 'package:dart_libp2p/core/event/identify.dart';
import 'package:dart_libp2p/core/network/rcmgr.dart';
import 'package:dart_libp2p/core/peer/addr_info.dart';
import 'package:dart_libp2p/p2p/host/eventbus/basic.dart' as p2p_event_bus;
import 'package:dart_libp2p/p2p/protocol/identify/identify.dart' as identify;
import 'package:dart_libp2p/p2p/transport/connection_manager.dart' as p2p_conn_mgr;
import 'package:dart_udx/dart_udx.dart';
import 'package:test/test.dart';

import '../real_net_stack.dart';

void main() {
  group('Identify on inbound connections', () {
    late Libp2pNode a;
    late Libp2pNode b;

    setUp(() async {
      final udx = UDX();
      final resourceManager = NullResourceManager();
      final connManager = p2p_conn_mgr.ConnectionManager();
      Future<Libp2pNode> node() => createLibp2pNode(
            udxInstance: udx,
            resourceManager: resourceManager,
            connManager: connManager,
            hostEventBus: p2p_event_bus.BasicBus(),
          );
      a = await node();
      b = await node();
    });

    tearDown(() async {
      await a.host.close();
      await b.host.close();
    });

    // go-libp2p identifies every new connection from both ends. The identify
    // protocol informs only the side that opens the stream, so a listener
    // that waits for the dialer learns nothing about it.
    test('the listener identifies the dialer without opening a stream', () async {
      final sub = a.host.eventBus.subscribe(EvtPeerIdentificationCompleted);
      final identified = sub.stream
          .where((e) => e is EvtPeerIdentificationCompleted && e.peer == b.peerId)
          .first;

      await b.host.connect(AddrInfo(a.peerId, a.listenAddrs));
      await identified.timeout(const Duration(seconds: 10));
      await sub.close();

      final protocols = await a.host.peerStore.protoBook.getProtocols(b.peerId);
      expect(protocols, contains(identify.id));
      expect(await a.host.peerStore.addrBook.addrs(b.peerId), isNotEmpty);
      expect(await a.host.peerStore.peerMetadata.get(b.peerId, 'AgentVersion'), isNotNull);
    }, timeout: const Timeout(Duration(seconds: 30)));
  });
}
