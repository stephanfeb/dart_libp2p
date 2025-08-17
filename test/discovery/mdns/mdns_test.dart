import 'dart:async';

import 'package:dart_libp2p/p2p/discovery/mdns/mdns.dart';
import 'package:dart_libp2p/core/peer/addr_info.dart';
import 'package:dart_libp2p/core/host/host.dart';
import 'package:dart_libp2p/core/multiaddr.dart';
import 'package:dart_libp2p/core/peer/peer_id.dart';
import 'package:test/test.dart';
import 'package:dart_libp2p/p2p/discovery/mdns/service_registry.dart';

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

    test('advertise builds TXT records from host addresses (with /p2p)', () async {
      final peerId = await peerIdFuture;
      final addrWithPeer = MultiAddr('/ip4/127.0.0.1/udp/4001/udx/p2p/${peerId.toString()}');
      final host = MockHost(peerId, [addrWithPeer]);

      // Capture arguments passed to the registry
      late List<String> capturedTxtRecords;
      MdnsServiceRegistry registryFactory({
        required client,
        required String serviceName,
        required String domain,
        required String name,
        required int port,
        required List<String> txtRecords,
      }) {
        capturedTxtRecords = txtRecords;
        return _NoopRegistry();
      }

      final mdns = MdnsDiscovery(
        host,
        registryFactory: registryFactory,
      );

      await mdns.start();

      expect(
        capturedTxtRecords,
        contains('${MdnsConstants.dnsaddrPrefix}${addrWithPeer.toString()}'),
      );

      await mdns.stop();
    });

    test('findPeers forwards discovered peers to returned stream', () async {
      final peerId = await peerIdFuture;
      final host = MockHost(peerId, []);
      final mdns = MdnsDiscovery(host);

      final testNotifee = TestNotifee();
      mdns.notifee = testNotifee;

      final stream = await mdns.findPeers('test');

      final completer = Completer<AddrInfo>();
      final sub = stream.listen((peer) {
        if (!completer.isCompleted) {
          completer.complete(peer);
        }
      });

      final discoveredAddr = MultiAddr('/ip4/127.0.0.1/udp/4001/udx/p2p/${peerId.toString()}');
      final discovered = AddrInfo(peerId, [discoveredAddr]);

      mdns.debugInjectPeer(discovered);

      final received = await completer.future.timeout(const Duration(seconds: 2));
      expect(received.id, equals(peerId));
      expect(received.addrs.first.toString(), equals(discoveredAddr.toString()));

      await sub.cancel();
      await mdns.stop();
    });
  });
}

class _NoopRegistry implements MdnsServiceRegistry {
  @override
  void dispose() {}

  @override
  void register() {}

  @override
  void unregister() {}
}
