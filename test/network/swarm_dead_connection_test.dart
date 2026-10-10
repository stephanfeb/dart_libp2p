import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:dart_libp2p/core/multiaddr.dart';
import 'package:dart_libp2p/core/network/context.dart';
import 'package:dart_libp2p/core/network/rcmgr.dart';
import 'package:dart_libp2p/core/peer/addr_info.dart';
import 'package:dart_libp2p/core/peerstore.dart';
import 'package:dart_libp2p/p2p/host/eventbus/basic.dart' as p2p_event_bus;
import 'package:dart_libp2p/p2p/transport/connection_manager.dart' as p2p_conn_mgr;
import 'package:dart_libp2p/p2p/transport/multiplexing/multiplexer.dart';
import 'package:dart_udx/dart_udx.dart';
import 'package:test/test.dart';

import '../real_net_stack.dart';

/// A UDP relay between one client and one target that can drop every
/// datagram, so a connection through it dies without a close, as a phone's
/// path does.
class _UdpProxy {
  _UdpProxy._(this._socket, this._target, this._targetPort) {
    _socket.listen((event) {
      if (event != RawSocketEvent.read) return;
      final d = _socket.receive();
      if (d == null || dropping) return;
      final fromTarget = d.address == _target && d.port == _targetPort;
      if (fromTarget) {
        final client = _client;
        if (client != null) _socket.send(d.data, client.$1, client.$2);
      } else {
        _client = (d.address, d.port);
        _socket.send(d.data, _target, _targetPort);
      }
    });
  }

  static Future<_UdpProxy> start(InternetAddress target, int targetPort) async {
    final socket = await RawDatagramSocket.bind(InternetAddress.loopbackIPv4, 0);
    return _UdpProxy._(socket, target, targetPort);
  }

  final RawDatagramSocket _socket;
  final InternetAddress _target;
  final int _targetPort;
  (InternetAddress, int)? _client;
  bool dropping = false;

  MultiAddr get addr => MultiAddr('/ip4/127.0.0.1/udp/${_socket.port}/udx');

  void close() => _socket.close();
}

const _echo = '/test/echo/1.0.0';
const _sink = '/test/sink/1.0.0';

void main() {
  group('Swarm with a connection that dies silently (dart-libp2p-m06)', () {
    late Libp2pNode a;
    late Libp2pNode b;
    late _UdpProxy proxy;

    setUp(() async {
      final udx = UDX();
      final resourceManager = NullResourceManager();
      final connManager = p2p_conn_mgr.ConnectionManager();
      const yamux = MultiplexerConfig(
        keepAliveInterval: Duration(seconds: 1),
        keepAliveTimeout: Duration(seconds: 3),
        streamOpenTimeout: Duration(seconds: 3),
      );
      a = await createLibp2pNode(
        udxInstance: udx,
        resourceManager: resourceManager,
        connManager: connManager,
        hostEventBus: p2p_event_bus.BasicBus(),
        yamuxConfig: yamux,
        negotiationTimeout: const Duration(seconds: 3),
      );
      b = await createLibp2pNode(
        udxInstance: udx,
        resourceManager: resourceManager,
        connManager: connManager,
        hostEventBus: p2p_event_bus.BasicBus(),
        yamuxConfig: yamux,
        negotiationTimeout: const Duration(seconds: 3),
      );
      b.host.setStreamHandler(_echo, (stream, _) async {
        final data = await stream.read();
        await stream.write(data);
        await stream.close();
      });

      b.host.setStreamHandler(_sink, (stream, _) async {
        while ((await stream.read()).isNotEmpty) {}
      });

      final bPort = int.parse(b.listenAddrs.first.valueForProtocol('udp')!);
      proxy = await _UdpProxy.start(InternetAddress.loopbackIPv4, bPort);
      await a.host.connect(AddrInfo(b.peerId, [proxy.addr]));
      // Only the proxy leads to B, so every dial goes through it.
      await a.host.peerStore.addrBook.clearAddrs(b.peerId);
      await a.host.peerStore.addrBook
          .addAddrs(b.peerId, [proxy.addr], AddressTTL.permanentAddrTTL);
    });

    tearDown(() async {
      proxy.close();
      await a.host.close();
      await b.host.close();
    });

    Future<String> echo(String text) async {
      final stream = await a.host.newStream(b.peerId, [_echo], Context());
      await stream.write(Uint8List.fromList(text.codeUnits));
      final reply = await stream.read().timeout(const Duration(seconds: 5));
      await stream.close();
      return String.fromCharCodes(reply);
    }

    test('a new stream fails within a bound, the connection is dropped, '
        'and the next stream dials again', () async {
      expect(await echo('before'), 'before');
      final firstConn = a.host.network.connsToPeer(b.peerId).single;

      final sink = await a.host.newStream(b.peerId, [_sink], Context());

      proxy.dropping = true;

      // Fill the send window, so later frames on the connection wait
      // behind data that is never acknowledged: the stalled writes of the
      // field report, not only lost pongs.
      unawaited(sink.write(Uint8List(512 * 1024)).catchError((Object _) {}));

      // The connection does not answer: the request fails, it does not hang.
      final watch = Stopwatch()..start();
      await expectLater(echo('during'), throwsA(anything));
      expect(watch.elapsed, lessThan(const Duration(seconds: 15)));

      // Keep-alive finds the connection dead and the swarm drops it.
      final deadline = DateTime.now().add(const Duration(seconds: 15));
      while (a.host.network.connsToPeer(b.peerId).any((c) => c.id == firstConn.id)) {
        if (DateTime.now().isAfter(deadline)) {
          fail('the dead connection was not dropped');
        }
        await Future.delayed(const Duration(milliseconds: 100));
      }

      proxy.dropping = false;

      // The next request dials a new connection.
      expect(await echo('after').timeout(const Duration(seconds: 20)), 'after');
      expect(a.host.network.connsToPeer(b.peerId).map((c) => c.id),
          isNot(contains(firstConn.id)));
    }, timeout: const Timeout(Duration(seconds: 90)));
  });
}
