import 'dart:io' show InternetAddress, InternetAddressType, NetworkInterface, RawDatagramSocket;

import 'package:dart_libp2p/config/config.dart' as p2p_config;
import 'package:dart_libp2p/core/crypto/ed25519.dart' as crypto_ed25519;
import 'package:dart_libp2p/core/host/host.dart';
import 'package:dart_libp2p/core/multiaddr.dart';
import 'package:dart_libp2p/core/peer/addr_info.dart';
import 'package:dart_libp2p/p2p/security/noise/noise_protocol.dart';
import 'package:dart_libp2p/p2p/transport/connection_manager.dart' as p2p_conn_manager;
import 'package:dart_libp2p/p2p/transport/udx_transport.dart';
import 'package:test/test.dart';

Future<Host> _host([String listen = '/ip4/0.0.0.0/udp/0/udx']) async {
  final keyPair = await crypto_ed25519.generateEd25519KeyPair();
  final connManager = p2p_conn_manager.ConnectionManager();
  final host = await p2p_config.Libp2p.new_([
    p2p_config.Libp2p.identity(keyPair),
    p2p_config.Libp2p.connManager(connManager),
    p2p_config.Libp2p.transport(UDXTransport(connManager: connManager)),
    p2p_config.Libp2p.security(await NoiseSecurity.create(keyPair)),
    p2p_config.Libp2p.listenAddrs([MultiAddr(listen)]),
  ]);
  await host.start();
  return host;
}

int _udpPort(MultiAddr a) => int.parse(a.valueForProtocol('udp')!);

void main() {
  // A host behind NAT learns its public address from what the peers it
  // dials observe, and that is only useful for the listen socket's NAT
  // mapping. So an ordinary dial must leave from the listen socket.
  test('an ordinary UDX dial leaves from the listener port', () async {
    final a = await _host();
    final b = await _host();
    addTearDown(() async {
      await a.close();
      await b.close();
    });

    final listenPort = _udpPort(a.network.listenAddresses.firstWhere((m) => m.hasProtocol('udx')));
    final bAddr = b.addrs.firstWhere((m) => m.hasProtocol('udx'));
    await a.connect(AddrInfo(b.id, [bAddr]));

    final conns = a.network.connsToPeer(b.id);
    expect(conns, isNotEmpty);
    expect(_udpPort(conns.first.localMultiaddr), listenPort);

    // b sees a coming from a's listen port, which is the address b reports
    // back to a through Identify.
    final bConns = b.network.connsToPeer(a.id);
    expect(bConns, isNotEmpty);
    expect(_udpPort(bConns.first.remoteMultiaddr), listenPort);
  });

  // Nodes on a fixed port all listen on the same port number. A dial to
  // such a peer is not a dial to our own listener, so it must also leave
  // from the listen socket. a listens on this machine's LAN address with
  // port P, and b on 127.0.0.1 with the same port P.
  test('a dial to a peer on the same port number leaves from the listener port', () async {
    final interfaces = await NetworkInterface.list(type: InternetAddressType.IPv4);
    final lan = interfaces.expand((i) => i.addresses).where((a) => !a.isLoopback).firstOrNull;
    if (lan == null) {
      markTestSkipped('no non-loopback IPv4 address');
      return;
    }
    final probe = await RawDatagramSocket.bind(lan, 0);
    final port = probe.port;
    probe.close();

    final a = await _host('/ip4/${lan.address}/udp/$port/udx');
    final b = await _host('/ip4/127.0.0.1/udp/$port/udx');
    addTearDown(() async {
      await a.close();
      await b.close();
    });

    await a.connect(AddrInfo(b.id, [MultiAddr('/ip4/127.0.0.1/udp/$port/udx')]));

    final bConns = b.network.connsToPeer(a.id);
    expect(bConns, isNotEmpty);
    expect(_udpPort(bConns.first.remoteMultiaddr), port);
  });

  // A socket bound to loopback cannot send to another host, so a dial there
  // must not leave from a loopback listener.
  group('listenerSocketFor', () {
    final loop4 = InternetAddress('127.0.0.1');
    final any4 = InternetAddress('0.0.0.0');
    final lan4 = InternetAddress('192.168.1.5');
    InternetAddress id(InternetAddress a) => a;

    test('prefers a listener on all interfaces', () {
      expect(listenerSocketFor([loop4, any4, lan4], id, '203.0.113.7'), any4);
      expect(listenerSocketFor([loop4, any4], id, '127.0.0.1'), any4);
    });

    test('never dials another host from a loopback listener', () {
      expect(listenerSocketFor([loop4], id, '10.255.255.1'), isNull);
      expect(listenerSocketFor([loop4, lan4], id, '10.255.255.1'), lan4);
    });

    test('dials loopback from a loopback or a specific listener', () {
      expect(listenerSocketFor([loop4], id, '127.0.0.1'), loop4);
      expect(listenerSocketFor([lan4], id, '127.0.0.1'), lan4);
    });

    test('no listener, no reuse', () {
      expect(listenerSocketFor(<InternetAddress>[], id, '127.0.0.1'), isNull);
    });
  });

  // Only a dial to one of our own listeners keeps a fresh socket. A peer on
  // another host that listens on the same port number, as nodes on a fixed
  // port all do, must still be dialed from the listen socket.
  group('isOwnListenAddress', () {
    final any4 = InternetAddress('0.0.0.0');
    final any6 = InternetAddress('::');
    final loop4 = InternetAddress('127.0.0.1');
    final lan4 = InternetAddress('192.168.1.5');

    test('the same address and port', () {
      expect(isOwnListenAddress(loop4, 4001, '127.0.0.1', 4001), isTrue);
      expect(isOwnListenAddress(lan4, 4001, '192.168.1.5', 4001), isTrue);
      expect(isOwnListenAddress(InternetAddress('::1'), 4001, '::1', 4001), isTrue);
    });

    test('a listener on all interfaces, dialed through loopback or unspecified', () {
      expect(isOwnListenAddress(any4, 4001, '127.0.0.1', 4001), isTrue);
      expect(isOwnListenAddress(any4, 4001, '0.0.0.0', 4001), isTrue);
      expect(isOwnListenAddress(any6, 4001, '::1', 4001), isTrue);
    });

    test('a remote peer on the same port number', () {
      expect(isOwnListenAddress(any4, 4001, '203.0.113.7', 4001), isFalse);
      expect(isOwnListenAddress(loop4, 4001, '127.0.0.2', 4001), isFalse);
      expect(isOwnListenAddress(lan4, 4001, '192.168.1.6', 4001), isFalse);
      expect(isOwnListenAddress(any6, 4001, '2001:db8::1', 4001), isFalse);
    });

    test('another port', () {
      expect(isOwnListenAddress(loop4, 4001, '127.0.0.1', 4002), isFalse);
      expect(isOwnListenAddress(any4, 4001, '127.0.0.1', 4002), isFalse);
    });

    test('a host name is not an address', () {
      expect(isOwnListenAddress(any4, 4001, 'localhost', 4001), isFalse);
    });
  });
}
