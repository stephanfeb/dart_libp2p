import 'dart:async';

import 'package:dart_libp2p/core/multiaddr.dart';
import 'package:dart_libp2p/p2p/transport/connection_manager.dart' as p2p_conn_manager;
import 'package:dart_libp2p/p2p/transport/listener.dart';
import 'package:dart_libp2p/p2p/transport/udx_stream_adapter.dart';
import 'package:dart_libp2p/p2p/transport/udx_transport.dart';
import 'package:test/test.dart';

/// A listen socket the OS takes away (Android cuts a screen-off app's
/// network; Dart closes a socket on any error) is bound again, and dials
/// leave from the new socket. Before, every dial reused the dead socket,
/// sent nothing and timed out, until the app restarted.
void main() {
  late UDXTransport phone, server;
  late UDXListener phoneListener;
  late Listener serverListener;

  setUp(() async {
    phone = UDXTransport(connManager: p2p_conn_manager.ConnectionManager());
    server = UDXTransport(connManager: p2p_conn_manager.ConnectionManager());
    phoneListener = await phone.listen(MultiAddr('/ip4/127.0.0.1/udp/0/udx')) as UDXListener;
    serverListener = await server.listen(MultiAddr('/ip4/127.0.0.1/udp/0/udx'));
  });

  tearDown(() async {
    await phone.dispose();
    await server.dispose();
  });

  /// Dials the server, and answers the port the server saw the dial from.
  Future<int> dialServer() async {
    final accepted = serverListener.accept();
    final conn = await phone.dial(serverListener.addr, timeout: const Duration(seconds: 5));
    final seen = (await accepted.timeout(const Duration(seconds: 5)))!;
    final port = int.parse(seen.remoteMultiaddr.valueForProtocol('udp')!);
    await conn.close();
    return port;
  }

  test('a lost listen socket is bound again, on its port, and dials work', () async {
    final port = phoneListener.multiplexer.socket.port;
    expect(await dialServer(), port, reason: 'dials leave from the listen socket');

    final lost = phoneListener.multiplexer;
    lost.socket.close(); // what the OS did
    await lost.done;

    // Bound again within a moment, on the same port.
    final deadline = DateTime.now().add(const Duration(seconds: 5));
    while (identical(phoneListener.multiplexer, lost) && DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    expect(phoneListener.multiplexer, isNot(same(lost)));
    expect(phoneListener.isClosed, isFalse);
    expect(phoneListener.multiplexer.socket.port, port);
    expect(phoneListener.addr.valueForProtocol('udp'), '$port');

    expect(await dialServer(), port, reason: 'and from the new socket');
  });

  test('a listener closed on purpose is not bound again', () async {
    final multiplexer = phoneListener.multiplexer;
    await phoneListener.close();
    await Future<void>.delayed(const Duration(milliseconds: 200));
    expect(phoneListener.isClosed, isTrue);
    expect(phoneListener.multiplexer, same(multiplexer));
  });
}
