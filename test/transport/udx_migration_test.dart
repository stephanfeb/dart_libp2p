import 'dart:async';
import 'dart:io' show InternetAddress, RawDatagramSocket;
import 'dart:typed_data';

import 'package:dart_libp2p/core/multiaddr.dart';
import 'package:dart_libp2p/p2p/transport/connection_manager.dart' as p2p_conn_manager;
import 'package:dart_libp2p/p2p/transport/udx_transport.dart';
import 'package:dart_udx/dart_udx.dart';
import 'package:test/test.dart';

void main() {
  // A phone that changes network (Wi-Fi to cellular) or a NAT that rebinds
  // sends from a new address. dart_udx validates the new path and moves the
  // connection to it, but the session kept the old remote address, so the
  // swarm, identify and the peerstore saw an address that was gone
  // (dart-libp2p-1pp).
  test('the session follows the peer to a new path', () async {
    final server = UDXTransport(connManager: p2p_conn_manager.ConnectionManager());
    final client = UDXTransport(connManager: p2p_conn_manager.ConnectionManager());
    final listener = await server.listen(MultiAddr('/ip4/127.0.0.1/udp/0/udx'));
    addTearDown(() async {
      await client.dispose();
      await server.dispose();
    });

    final accepted = listener.accept();
    final clientConn = await client.dial(listener.addr) as UDXSessionConn;
    final serverConn = (await accepted)! as UDXSessionConn;
    final oldPort = serverConn.remoteMultiaddr.valueForProtocol('udp');

    // Move the client's connection to a new local socket, as after a
    // network change.
    final socket = clientConn.udpSocket;
    final newRaw = await RawDatagramSocket.bind(InternetAddress.loopbackIPv4, 0);
    final newMux = UDXMultiplexer(newRaw);
    addTearDown(newMux.close);
    socket.multiplexer.removeSocket(socket.cids.localCid);
    newMux.addSocket(socket);
    socket.multiplexer = newMux;

    // Data from the new path makes the server validate it and move.
    await clientConn.write(Uint8List.fromList([1, 2, 3]));
    final received = await serverConn.read().timeout(const Duration(seconds: 5));
    expect(received, [1, 2, 3]);

    final deadline = DateTime.now().add(const Duration(seconds: 5));
    while (serverConn.remoteMultiaddr.valueForProtocol('udp') == oldPort &&
        DateTime.now().isBefore(deadline)) {
      await Future.delayed(const Duration(milliseconds: 50));
    }
    expect(serverConn.remoteMultiaddr.valueForProtocol('udp'), '${newRaw.port}');
    expect(serverConn.remoteMultiaddr.toString(), '/ip4/127.0.0.1/udp/${newRaw.port}/udx');
  });
}
