import 'package:dart_libp2p/core/multiaddr.dart';
import 'package:dart_libp2p/p2p/protocol/identify/observed_addr_manager.dart';
import 'package:test/test.dart';

class _TestConn implements ConnMultiaddrs {
  _TestConn(this.localMultiaddr, this.remoteMultiaddr);

  @override
  final MultiAddr localMultiaddr;

  @override
  final MultiAddr remoteMultiaddr;

  @override
  bool isClosed() => false;
}

void main() {
  const local = '/ip4/10.0.0.2/udp/4001/udx';
  const observed = '/ip4/46.96.54.236/udp/51000/udx';

  ObservedAddrManager manager({int threshold = 4}) => ObservedAddrManager(
        listenAddrs: () => List.unmodifiable([MultiAddr(local)]),
        hostAddrs: () => List.unmodifiable([MultiAddr(local)]),
    interfaceListenAddrs: () async => [MultiAddr(local)],
    activationThreshold: threshold,
  );

  test('records and activates one valid observation when configured', () async {
    final subject = manager(threshold: 1);
    addTearDown(subject.close);

    subject.recordFromMultiaddrs(
      _TestConn(MultiAddr(local), MultiAddr('/ip4/8.8.8.1/tcp/4001')),
      MultiAddr(observed),
    );

    expect(subject.addrs().map((a) => a.toString()), contains(observed));
  });

  test('retains the conservative four-observer default', () async {
    final subject = manager();
    addTearDown(subject.close);

    for (var i = 1; i <= 3; i++) {
      subject.recordFromMultiaddrs(
        _TestConn(MultiAddr(local), MultiAddr('/ip4/8.8.8.$i/tcp/4001')),
        MultiAddr(observed),
      );
    }
    expect(subject.addrs(), isEmpty);

    subject.recordFromMultiaddrs(
      _TestConn(MultiAddr(local), MultiAddr('/ip4/8.8.8.4/tcp/4001')),
      MultiAddr(observed),
    );
    expect(subject.addrs().map((a) => a.toString()), contains(observed));
  });
}
