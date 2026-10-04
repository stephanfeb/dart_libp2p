import 'dart:typed_data';

import 'package:dart_libp2p/core/network/context.dart';
import 'package:dart_libp2p/core/network/rcmgr.dart';
import 'package:dart_libp2p/core/peer/addr_info.dart';
import 'package:dart_libp2p/p2p/host/eventbus/basic.dart' as p2p_event_bus;
import 'package:dart_libp2p/p2p/transport/connection_manager.dart' as p2p_conn_mgr;
import 'package:dart_udx/dart_udx.dart';
import 'package:test/test.dart';

import '../real_net_stack.dart';

void main() {
  group('BasicHost stream handlers', () {
    late Libp2pNode a;
    late Libp2pNode b;

    setUp(() async {
      final udx = UDX();
      Future<Libp2pNode> node() => createLibp2pNode(
            udxInstance: udx,
            resourceManager: NullResourceManager(),
            connManager: p2p_conn_mgr.ConnectionManager(),
            hostEventBus: p2p_event_bus.BasicBus(),
          );
      a = await node();
      b = await node();
      await a.host.connect(AddrInfo(b.peerId, b.listenAddrs));
    });

    tearDown(() async {
      await a.host.close();
      await b.host.close();
    });

    // The muxer does not await handlers, so a handler that threw after its
    // first await escaped as an unhandled async error. It must instead reset
    // only its own stream; the test zone fails on any unhandled error.
    test('a handler that throws resets its stream and leaves the host serving', () async {
      const failing = '/test/failing/1.0.0';
      const echo = '/test/echo/1.0.0';
      b.host.setStreamHandler(failing, (stream, _) async {
        await stream.read();
        throw StateError('handler failed');
      });
      b.host.setStreamHandler(echo, (stream, _) async {
        await stream.write(await stream.read());
        await stream.close();
      });

      final bad = await a.host.newStream(b.peerId, [failing], Context());
      await bad.write(Uint8List.fromList([1]));
      // A reset reaches the reader as an error or as end of stream.
      final Object result = await bad
          .read()
          .then<Object>((data) => data, onError: (Object e) => e)
          .timeout(const Duration(seconds: 10));
      expect(result, anyOf(isA<Exception>(), isA<Error>(), isEmpty),
          reason: 'the failed handler should reset its stream');
      print('reader saw: ${result is List ? 'end of stream' : result}');

      final good = await a.host.newStream(b.peerId, [echo], Context());
      await good.write(Uint8List.fromList([7, 8, 9]));
      expect(await good.read(), [7, 8, 9]);
    }, timeout: const Timeout(Duration(seconds: 30)));
  });
}
