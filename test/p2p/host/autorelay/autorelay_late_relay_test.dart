import 'package:dart_libp2p/core/network/network.dart' show Reachability;
import 'package:dart_libp2p/core/network/rcmgr.dart';
import 'package:dart_libp2p/core/peer/addr_info.dart';
import 'package:dart_libp2p/p2p/host/eventbus/basic.dart' as p2p_event_bus;
import 'package:dart_libp2p/p2p/transport/connection_manager.dart' as p2p_conn_mgr;
import 'package:dart_udx/dart_udx.dart';
import 'package:test/test.dart';

import '../../../real_net_stack.dart';

void main() {
  group('AutoRelay', () {
    late Libp2pNode relay;
    late Libp2pNode client;

    setUp(() async {
      final udx = UDX();
      final resourceManager = NullResourceManager();
      final connManager = p2p_conn_mgr.ConnectionManager();
      relay = await createLibp2pNode(
        udxInstance: udx,
        resourceManager: resourceManager,
        connManager: connManager,
        hostEventBus: p2p_event_bus.BasicBus(),
        enableRelay: true,
        forceReachability: Reachability.public,
      );
      client = await createLibp2pNode(
        udxInstance: udx,
        resourceManager: resourceManager,
        connManager: connManager,
        hostEventBus: p2p_event_bus.BasicBus(),
        enableAutoRelay: true,
        forceReachability: Reachability.private,
      );
    });

    tearDown(() async {
      await client.host.close();
      await relay.host.close();
    });

    test('reserves on a relay connected after it started', () async {
      // RelayFinder's first peer-source call runs at start, before this
      // connection exists; it must ask again later.
      await Future.delayed(const Duration(seconds: 1));
      await client.host.connect(AddrInfo(relay.peerId, relay.listenAddrs));

      final relayCircuit = '/p2p/${relay.peerId.toBase58()}/p2p-circuit';
      final deadline = DateTime.now().add(const Duration(seconds: 30));
      while (DateTime.now().isBefore(deadline) &&
          !client.host.addrs.any((a) => a.toString().contains(relayCircuit))) {
        await Future.delayed(const Duration(milliseconds: 500));
      }

      final addrs = client.host.addrs.map((a) => a.toString()).toList();
      expect(addrs, contains(contains(relayCircuit)));
      expect(addrs, isNot(contains('/p2p-circuit')),
          reason: 'the circuit client\'s bare listen address is not dialable');
    }, timeout: const Timeout(Duration(seconds: 60)));

    // A phone on a carrier's NAT loses its connection to the relay many times
    // an hour. With one relay, an hour's backoff after each reservation left
    // it undialable (NO_RESERVATION) until the hour was up.
    test('reserves again at once when the connection to its relay drops and comes back', () async {
      final relayCircuit = '/p2p/${relay.peerId.toBase58()}/p2p-circuit';
      bool reserved() => client.host.addrs.any((a) => a.toString().contains(relayCircuit));
      Future<bool> until(bool Function() done, Duration within) async {
        final deadline = DateTime.now().add(within);
        while (DateTime.now().isBefore(deadline) && !done()) {
          await Future.delayed(const Duration(milliseconds: 250));
        }
        return done();
      }

      await client.host.connect(AddrInfo(relay.peerId, relay.listenAddrs));
      expect(await until(reserved, const Duration(seconds: 30)), isTrue, reason: 'first reservation');

      await client.host.network.closePeer(relay.peerId);
      expect(await until(() => !reserved(), const Duration(seconds: 10)), isTrue,
          reason: 'the circuit address goes with the reservation');

      await client.host.connect(AddrInfo(relay.peerId, relay.listenAddrs));
      expect(await until(reserved, const Duration(seconds: 30)), isTrue,
          reason: 'a relay whose reservation ended with its connection is not on backoff');
    }, timeout: const Timeout(Duration(seconds: 90)));
  });
}
