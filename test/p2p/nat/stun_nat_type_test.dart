import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:dart_libp2p/config/config.dart' as p2p_config;
import 'package:dart_libp2p/core/crypto/ed25519.dart' as crypto_ed25519;
import 'package:dart_libp2p/core/event/nattype.dart';
import 'package:dart_libp2p/core/multiaddr.dart';
import 'package:dart_libp2p/p2p/host/basic/basic_host.dart';
import 'package:dart_libp2p/p2p/host/eventbus/basic.dart';
import 'package:dart_libp2p/p2p/nat/stun/stun_message.dart';
import 'package:dart_libp2p/p2p/nat/stun/stun_nat_type.dart';
import 'package:dart_libp2p/p2p/protocol/holepunch/holepuncher.dart';
import 'package:dart_libp2p/p2p/protocol/holepunch/util.dart' show maxRetries;
import 'package:dart_libp2p/p2p/security/noise/noise_protocol.dart';
import 'package:dart_libp2p/p2p/transport/connection_manager.dart';
import 'package:dart_libp2p/p2p/transport/udx_transport.dart';
import 'package:mockito/mockito.dart';
import 'package:test/test.dart';

import '../../protocol/holepunch/holepunch_basic_test.mocks.dart';

/// A STUN server on localhost that answers with the address it sees, with
/// [portOffset] added to the port. An offset makes it look like a symmetric
/// NAT gave this server a different mapping. A [silent] server never answers.
class _FakeStunServer {
  final RawDatagramSocket socket;

  _FakeStunServer._(this.socket, int portOffset, bool silent) {
    socket.listen((event) {
      if (event != RawSocketEvent.read) return;
      // Take the datagram even when silent: a socket left unread raises
      // read events again at once and starves the event loop.
      final d = socket.receive();
      if (d == null || silent) return;
      final request = StunMessage.decode(d.data);
      if (request == null) return;
      final value = ByteData(8)
        ..setUint8(1, 1) // IPv4
        ..setUint16(2, d.port + portOffset);
      final bytes = value.buffer.asUint8List()..setRange(4, 8, d.address.rawAddress);
      final response = StunMessage(StunMessageType.bindingResponse, request.transactionId,
          {StunAttribute.mappedAddress: bytes});
      socket.send(response.encode(), d.address, d.port);
    });
  }

  static Future<_FakeStunServer> start({int portOffset = 0, bool silent = false}) async =>
      _FakeStunServer._(await RawDatagramSocket.bind(InternetAddress.loopbackIPv4, 0), portOffset, silent);

  ({String host, int port}) get endpoint => (host: '127.0.0.1', port: socket.port);
}

void main() {
  final servers = <_FakeStunServer>[];
  Future<_FakeStunServer> server({int portOffset = 0, bool silent = false}) async {
    final s = await _FakeStunServer.start(portOffset: portOffset, silent: silent);
    servers.add(s);
    return s;
  }

  tearDown(() {
    for (final s in servers) {
      s.socket.close();
    }
    servers.clear();
  });

  group('StunNatTypeProbe', () {
    test('the same mapping at both servers is a cone NAT', () async {
      final a = await server();
      final b = await server();
      final type = await StunNatTypeProbe(servers: [a.endpoint, b.endpoint]).probe();
      expect(type, NATDeviceType.cone);
    });

    test('a different mapping at each server is a symmetric NAT', () async {
      final a = await server();
      final b = await server(portOffset: 1);
      final type = await StunNatTypeProbe(servers: [a.endpoint, b.endpoint]).probe();
      expect(type, NATDeviceType.symmetric);
    });

    test('fewer than two answers is unknown', () async {
      final a = await server();
      final b = await server(silent: true);
      final type = await StunNatTypeProbe(
        servers: [a.endpoint, b.endpoint],
        timeout: const Duration(milliseconds: 500),
      ).probe();
      expect(type, NATDeviceType.unknown);
    });
  });

  group('hole punch attempts', () {
    test('one attempt behind a symmetric NAT, otherwise maxRetries', () {
      expect(holePunchAttempts(NATDeviceType.symmetric), 1);
      expect(holePunchAttempts(NATDeviceType.cone), maxRetries);
      expect(holePunchAttempts(NATDeviceType.unknown), maxRetries);
    });

    test('the hole puncher follows the UDP NAT type events', () async {
      final bus = BasicBus();
      final host = MockHost();
      when(host.eventBus).thenReturn(bus);
      when(host.network).thenReturn(MockNetwork());
      final puncher = HolePuncher(host, MockIDService(), () => []);
      await Future.delayed(const Duration(milliseconds: 50));

      final emitter = await bus.emitter(EvtNATDeviceTypeChanged);
      await emitter.emit(EvtNATDeviceTypeChanged(
          transportProtocol: NATTransportProtocol.tcp, natDeviceType: NATDeviceType.symmetric));
      await emitter.emit(EvtNATDeviceTypeChanged(
          transportProtocol: NATTransportProtocol.udp, natDeviceType: NATDeviceType.symmetric));
      await Future.delayed(const Duration(milliseconds: 50));

      expect(puncher.udpNatType, NATDeviceType.symmetric);
      await puncher.close();
    });
  });

  test('a host with STUN NAT detection publishes its UDP NAT type', () async {
    final a = await server();
    final b = await server(portOffset: 1);
    final keyPair = await crypto_ed25519.generateEd25519KeyPair();
    final connManager = ConnectionManager();
    final host = await p2p_config.Libp2p.new_([
      p2p_config.Libp2p.identity(keyPair),
      p2p_config.Libp2p.connManager(connManager),
      p2p_config.Libp2p.transport(UDXTransport(connManager: connManager)),
      p2p_config.Libp2p.security(await NoiseSecurity.create(keyPair)),
      p2p_config.Libp2p.listenAddrs([MultiAddr('/ip4/127.0.0.1/udp/0/udx')]),
      p2p_config.Libp2p.stunNatDetection(true, servers: [a.endpoint, b.endpoint]),
    ]) as BasicHost;
    await host.start();
    addTearDown(host.close);

    final deadline = DateTime.now().add(const Duration(seconds: 5));
    while (host.udpNatDeviceType == NATDeviceType.unknown && DateTime.now().isBefore(deadline)) {
      await Future.delayed(const Duration(milliseconds: 50));
    }
    expect(host.udpNatDeviceType, NATDeviceType.symmetric);
  });
}
