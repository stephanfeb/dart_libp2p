import 'dart:io' show InternetAddress, RawDatagramSocket;

import 'package:dart_libp2p/config/config.dart' as p2p_config;
import 'package:dart_libp2p/core/crypto/ed25519.dart' as crypto_ed25519;
import 'package:dart_libp2p/core/multiaddr.dart';
import 'package:dart_libp2p/core/network/conn.dart';
import 'package:dart_libp2p/core/network/context.dart';
import 'package:dart_libp2p/core/peer/peer_id.dart';
import 'package:dart_libp2p/core/peerstore.dart';
import 'package:dart_libp2p/p2p/protocol/holepunch/holepuncher.dart';
import 'package:dart_libp2p/p2p/protocol/holepunch/util.dart';
import 'package:dart_libp2p/p2p/security/noise/noise_protocol.dart';
import 'package:dart_libp2p/p2p/transport/connection_manager.dart' as p2p_conn_manager;
import 'package:dart_libp2p/p2p/transport/udx_transport.dart';
import 'package:mockito/mockito.dart';
import 'package:test/test.dart';

import 'holepunch_basic_test.mocks.dart';

/// An address book that knows no addresses, so the hole puncher skips its
/// direct dial and goes straight to the hole punch.
class _EmptyAddrBook implements AddrBook {
  @override
  Future<List<MultiAddr>> addrs(PeerId p) async => [];

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// A connection that is direct (not relayed), for getDirectConnection.
class _DirectConn implements Conn {
  @override
  MultiAddr get remoteMultiaddr => MultiAddr('/ip4/5.6.7.8/udp/4001/udx');

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  const relayAddr = '/ip4/1.2.3.4/udp/4001/udx'
      '/p2p/12D3KooWJfrcqqdoAcKUjAB6dGkC9KHCsTG5WKHZH8hk1wLs67it/p2p-circuit';

  // A hole punch uses public addresses only, as in go-libp2p. A private
  // address (for example, 10.0.2.15 inside an Android emulator) cannot be
  // reached from another network, and a dial to it waits for the full dial
  // timeout.
  group('holePunchAddrs', () {
    test('keeps public direct addresses only', () {
      final addrs = [
        MultiAddr('/ip4/10.0.2.15/udp/52818/udx'),
        MultiAddr('/ip4/192.168.1.5/udp/4001/udx'),
        MultiAddr('/ip4/172.20.0.3/tcp/4001'),
        MultiAddr('/ip4/127.0.0.1/udp/4001/udx'),
        MultiAddr('/ip6/::1/udp/4001/udx'),
        MultiAddr(relayAddr),
        MultiAddr('/ip4/5.6.7.8/udp/4001/udx'),
        MultiAddr('/ip6/2001:db8::1/udp/4001/udx'),
      ];
      expect(holePunchAddrs(addrs).map((a) => a.toString()), [
        '/ip4/5.6.7.8/udp/4001/udx',
        '/ip6/2001:db8::1/udp/4001/udx',
      ]);
    });
  });

  group('HolePuncher without a public address', () {
    late MockHost host;
    late MockNetwork network;
    late MockPeerstore peerstore;
    late PeerId local;
    late PeerId remote;

    setUp(() async {
      host = MockHost();
      network = MockNetwork();
      peerstore = MockPeerstore();
      local = await PeerId.random();
      remote = await PeerId.random();
      when(host.id).thenReturn(local);
      when(host.network).thenReturn(network);
      when(host.peerStore).thenReturn(peerstore);
      when(peerstore.addrBook).thenReturn(_EmptyAddrBook());
      when(network.connsToPeer(any)).thenReturn([]);
      when(host.newStream(any, any, any)).thenThrow(Exception('newStream called'));
    });

    test('does not ask the peer for a hole punch', () async {
      final puncher = HolePuncher(host, MockIDService(), () => [
            MultiAddr('/ip4/10.0.2.15/udp/52818/udx'),
            MultiAddr('/ip4/127.0.0.1/udp/52818/udx'),
            MultiAddr(relayAddr),
          ]);

      await expectLater(puncher.directConnect(remote), throwsA(anything));
      verifyNever(host.newStream(any, any, any));
    });

    test('asks the peer when it has a public address', () async {
      final puncher = HolePuncher(host, MockIDService(), () => [
            MultiAddr('/ip4/5.6.7.8/udp/52818/udx'),
          ]);

      await expectLater(puncher.directConnect(remote), throwsA(anything));
      verify(host.newStream(any, any, any)).called(1);
    });
  });

  // Both peers often start a hole punch at the same time. When the peer's
  // punch succeeds first, the relayed connection that carries ours can close,
  // and our protocol exchange fails although a direct connection now exists.
  test('a direct connection made meanwhile counts as success', () async {
    final host = MockHost();
    final network = MockNetwork();
    final peerstore = MockPeerstore();
    final remote = await PeerId.random();
    when(host.id).thenReturn(await PeerId.random());
    when(host.network).thenReturn(network);
    when(host.peerStore).thenReturn(peerstore);
    when(peerstore.addrBook).thenReturn(_EmptyAddrBook());
    var punched = false;
    when(network.connsToPeer(any)).thenAnswer((_) => punched ? [_DirectConn()] : []);
    when(host.newStream(any, any, any)).thenAnswer((_) async {
      punched = true; // the peer's punch wins while ours is under way
      throw Exception('Unexpected EOF while reading byte');
    });

    final puncher = HolePuncher(host, MockIDService(), () => [MultiAddr('/ip4/9.9.9.9/udp/4001/udx')]);

    await puncher.directConnect(remote);
    verify(host.newStream(any, any, any)).called(1);
  });

  // A hole punch dial waits 5 s, as in go-libp2p, not the 15-s dial timeout.
  test('a dial gives up after the dial-peer timeout of its context', () async {
    final silent = await RawDatagramSocket.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(silent.close);

    final keyPair = await crypto_ed25519.generateEd25519KeyPair();
    final connManager = p2p_conn_manager.ConnectionManager();
    final host = await p2p_config.Libp2p.new_([
      p2p_config.Libp2p.identity(keyPair),
      p2p_config.Libp2p.connManager(connManager),
      p2p_config.Libp2p.transport(UDXTransport(connManager: connManager)),
      p2p_config.Libp2p.security(await NoiseSecurity.create(keyPair)),
      p2p_config.Libp2p.listenAddrs([MultiAddr('/ip4/127.0.0.1/udp/0/udx')]),
    ]);
    await host.start();
    addTearDown(host.close);

    final peer = await PeerId.random();
    await host.peerStore.addrBook.addAddrs(
        peer, [MultiAddr('/ip4/127.0.0.1/udp/${silent.port}/udx')], AddressTTL.permanentAddrTTL);

    final watch = Stopwatch()..start();
    await expectLater(
      host.network.dialPeer(Context().withDialPeerTimeout(const Duration(seconds: 2)), peer),
      throwsA(anything),
    );
    expect(watch.elapsed, lessThan(const Duration(seconds: 5)));
  });
}
