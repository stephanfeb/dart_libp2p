// Two UDX hosts on loopback connect, exchange a stream and close. The
// dialling host does not listen, so its dial binds its own UDP socket. The
// program must then exit on its own: an open socket keeps a Dart process
// alive. Used by udx_dial_socket_close_test.dart.
//
//   dart run test/transport/fixtures/udx_exit_probe.dart
import 'dart:typed_data';

import 'package:dart_libp2p/config/config.dart' as p2p_config;
import 'package:dart_libp2p/core/crypto/ed25519.dart' as crypto_ed25519;
import 'package:dart_libp2p/core/host/host.dart';
import 'package:dart_libp2p/core/multiaddr.dart';
import 'package:dart_libp2p/core/network/context.dart';
import 'package:dart_libp2p/core/peer/addr_info.dart';
import 'package:dart_libp2p/p2p/transport/connection_manager.dart' as p2p_conn_manager;
import 'package:dart_libp2p/p2p/transport/udx_transport.dart';

Future<Host> _host(List<String> listen) async {
  final keyPair = await crypto_ed25519.generateEd25519KeyPair();
  final connManager = p2p_conn_manager.ConnectionManager();
  final host = await p2p_config.Libp2p.new_([
    p2p_config.Libp2p.identity(keyPair),
    p2p_config.Libp2p.connManager(connManager),
    p2p_config.Libp2p.transport(UDXTransport(connManager: connManager)),
    p2p_config.Libp2p.listenAddrs([for (final a in listen) MultiAddr(a)]),
  ]);
  await host.start();
  return host;
}

Future<void> main() async {
  const protocol = '/exit-probe/1.0.0';

  final b = await _host(['/ip4/127.0.0.1/udp/0/udx']);
  b.setStreamHandler(protocol, (stream, _) async {
    await stream.write(await stream.read());
    await stream.close();
  });
  final a = await _host([]);

  await a.connect(AddrInfo(b.id, b.network.listenAddresses));
  final s = await a.newStream(b.id, [protocol], Context());
  await s.write(Uint8List.fromList([1, 2, 3]));
  await s.read();
  await s.close();

  await a.close();
  await b.close();
  print('CLOSED');
}
