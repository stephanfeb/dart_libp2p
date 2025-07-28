import 'dart:async';

import 'package:dart_libp2p/p2p/discovery/mdns/mdns.dart';
import 'package:dart_libp2p/core/peer/addr_info.dart';
import 'package:dart_libp2p/core/host/host.dart';
import 'package:dart_libp2p/core/multiaddr.dart';
import 'package:dart_libp2p/core/peer/peer_id.dart';
import 'package:test/test.dart';

// Mock implementation of Host for testing
class MockHost implements Host {
  final PeerId _peerId;
  final List<MultiAddr> _listenAddrs;

  MockHost(this._peerId, this._listenAddrs);

  @override
  PeerId get id => _peerId;

  @override
  List<MultiAddr> get addrs => _listenAddrs;

  @override
  dynamic noSuchMethod(Invocation invocation) {
    throw UnimplementedError('${invocation.memberName} is not implemented');
  }
}

// Implementation of MdnsNotifee for testing
class TestNotifee implements MdnsNotifee {
  final List<AddrInfo> discoveredPeers = [];

  @override
  void handlePeerFound(AddrInfo peer) {
    discoveredPeers.add(peer);
  }
}

void main() {
  late PeerId peerIdFuture;

  setUpAll(() {
    // Create the PeerId once before all tests
    peerIdFuture = PeerId.fromString('QmYyQSo1c1Ym7orWxLYvCrM2EmxFTANf8wXmmE7DWjhx5N');
  });

  group('MdnsDiscovery', () {
    test('creates with default service name', () async {
      final peerId = await peerIdFuture;
      final host = MockHost(peerId, []);

      final mdns = MdnsDiscovery(host);

      expect(mdns, isNotNull);
    });

    test('advertise returns a duration', () async {
      final peerId = await peerIdFuture;
      final host = MockHost(peerId, []);

      final mdns = MdnsDiscovery(host);

      final duration = await mdns.advertise('test');

      expect(duration, isA<Duration>());

      await mdns.stop();
    });

    test('findPeers returns a stream', () async {
      final peerId = await peerIdFuture;
      final host = MockHost(peerId, []);

      final mdns = MdnsDiscovery(host);

      final stream = await mdns.findPeers('test');

      expect(stream, isA<Stream<AddrInfo>>());

      await mdns.stop();
    });

    // Note: Testing actual peer discovery would require running multiple instances
    // and would be more complex. This would be better suited for integration tests.
  });
}
