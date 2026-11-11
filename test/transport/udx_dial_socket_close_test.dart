import 'dart:async';
import 'dart:io';

import 'package:dart_libp2p/core/multiaddr.dart';
import 'package:dart_libp2p/p2p/transport/connection_manager.dart' as p2p_conn_manager;
import 'package:dart_libp2p/p2p/transport/listener.dart';
import 'package:dart_libp2p/p2p/transport/udx_transport.dart';
import 'package:test/test.dart';

UDXTransport _transport() => UDXTransport(connManager: p2p_conn_manager.ConnectionManager());

/// Completes when [conn]'s dial socket (its UDXMultiplexer and raw socket)
/// has closed, or times out.
Future<bool> _socketClosed(UDXSessionConn conn) => conn.udpSocket.multiplexer.done
    .then((_) => true)
    .timeout(const Duration(seconds: 5), onTimeout: () => false);

void main() {
  late UDXTransport server;
  late Listener serverListener;

  setUp(() async {
    server = _transport();
    serverListener = await server.listen(MultiAddr('/ip4/127.0.0.1/udp/0/udx'));
  });

  tearDown(() async {
    await server.dispose();
  });

  // A dial that cannot use a listener's socket binds its own. Nothing but
  // the connection holds that socket, so it must close with the connection;
  // left open, it stayed bound and kept the process from exiting.
  test('a dial without a listener closes its socket with the connection', () async {
    final client = _transport();
    addTearDown(client.dispose);

    final conn = await client.dial(serverListener.addr) as UDXSessionConn;
    await conn.close();

    expect(await _socketClosed(conn), isTrue);
  });

  test('an ephemeral dial closes its socket with the connection', () async {
    final client = _transport();
    addTearDown(client.dispose);
    await client.listen(MultiAddr('/ip4/0.0.0.0/udp/0/udx'));

    final conn = await client.dialFromEphemeralSocket(serverListener.addr) as UDXSessionConn;
    await conn.close();

    expect(await _socketClosed(conn), isTrue);
  });

  // A dial from a listener's socket shares it: closing the connection must
  // leave the listener's socket open.
  test('a dial from the listener socket leaves the listener open', () async {
    final client = _transport();
    addTearDown(client.dispose);
    final clientListener = await client.listen(MultiAddr('/ip4/0.0.0.0/udp/0/udx'));

    final conn = await client.dial(serverListener.addr) as UDXSessionConn;
    expect(conn.udpSocket.multiplexer.socket.port,
        int.parse(clientListener.addr.valueForProtocol('udp')!),
        reason: 'the dial uses the listener socket');
    await conn.close();

    expect(await _socketClosed(conn), isFalse);
  });

  // The check from the bug report: a program whose dialling host does not
  // listen ends on its own after both hosts close. The leaked dial socket
  // kept it alive.
  test('a program with a non-listening dialler exits after close', () async {
    final proc = await Process.start(
      Platform.resolvedExecutable,
      ['run', 'test/transport/fixtures/udx_exit_probe.dart'],
    );
    final out = StringBuffer();
    proc.stdout.transform(const SystemEncoding().decoder).listen(out.write);
    proc.stderr.transform(const SystemEncoding().decoder).listen(out.write);

    final code = await proc.exitCode.timeout(const Duration(seconds: 60), onTimeout: () {
      proc.kill(ProcessSignal.sigkill);
      return -1;
    });
    expect(code, 0, reason: 'the program did not exit on its own:\n$out');
    expect(out.toString(), contains('CLOSED'));
  }, timeout: const Timeout(Duration(seconds: 90)));
}
