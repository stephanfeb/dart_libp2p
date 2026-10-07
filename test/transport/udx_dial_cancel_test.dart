import 'dart:async';
import 'dart:io' show InternetAddress, RawDatagramSocket, RawSocketEvent;

import 'package:dart_libp2p/core/multiaddr.dart';
import 'package:dart_libp2p/p2p/transport/connection_manager.dart' as p2p_conn_manager;
import 'package:dart_libp2p/p2p/transport/udx_transport.dart';
import 'package:test/test.dart';

/// A UDP socket that never answers and records when packets arrive.
class _SilentPeer {
  final RawDatagramSocket socket;
  final arrivals = <DateTime>[];

  _SilentPeer(this.socket) {
    socket.listen((event) {
      if (event == RawSocketEvent.read && socket.receive() != null) arrivals.add(DateTime.now());
    });
  }

  static Future<_SilentPeer> bind() async =>
      _SilentPeer(await RawDatagramSocket.bind(InternetAddress.loopbackIPv4, 0));

  MultiAddr get addr => MultiAddr('/ip4/127.0.0.1/udp/${socket.port}/udx');

  int packetsAfter(DateTime t) => arrivals.where((a) => a.isAfter(t)).length;
}

void main() {
  late UDXTransport transport;
  late _SilentPeer silent;

  setUp(() async {
    transport = UDXTransport(connManager: p2p_conn_manager.ConnectionManager());
    // A listener, as on a real host: dials then use its socket, and the
    // socket stays open after a dial fails.
    await transport.listen(MultiAddr('/ip4/127.0.0.1/udp/0/udx'));
    silent = await _SilentPeer.bind();
  });

  tearDown(() async {
    silent.socket.close();
    await transport.dispose();
  });

  // A dial that failed kept its socket, which went on sending the
  // handshake until the socket's 30-s idle close.
  test('a failed dial stops sending', () async {
    await expectLater(
      transport.dial(silent.addr, timeout: const Duration(seconds: 1)),
      throwsA(anything),
    );
    final failedAt = DateTime.now().add(const Duration(milliseconds: 300));
    await Future.delayed(const Duration(seconds: 3));

    expect(silent.arrivals, isNotEmpty, reason: 'the dial sent a handshake');
    expect(silent.packetsAfter(failedAt), 0);
  });

  // Happy Eyeballs cancels the dials that lost the race. Before, a losing
  // UDX dial went on until its own timeout.
  test('a cancelled dial fails at once and stops sending', () async {
    final cancel = Completer<void>();
    final watch = Stopwatch()..start();
    final dial = transport.dial(silent.addr, timeout: const Duration(seconds: 10), cancel: cancel.future);
    Future.delayed(const Duration(milliseconds: 300), cancel.complete);

    await expectLater(dial, throwsA(isA<UDXDialCancelledException>()));
    expect(watch.elapsed, lessThan(const Duration(seconds: 2)));
    final cancelledAt = DateTime.now().add(const Duration(milliseconds: 300));
    await Future.delayed(const Duration(seconds: 3));

    expect(silent.packetsAfter(cancelledAt), 0);
  });
}
