import 'dart:async';
import 'dart:typed_data';

import 'package:dart_libp2p/core/network/context.dart' as core_context;
import 'package:dart_libp2p/core/peer/peer_id.dart';
import 'package:dart_libp2p/p2p/transport/multiplexing/multiplexer.dart';
import 'package:dart_libp2p/p2p/transport/multiplexing/yamux/frame.dart';
import 'package:dart_libp2p/p2p/transport/multiplexing/yamux/session.dart';
import 'package:test/test.dart';

import '../../../mocks/yamux_mock_connection.dart';

/// A connection that died without a close: writes never complete and reads
/// return nothing, as a UDX connection whose path went dead does. Frames
/// given to [deliver] are read once, to play a remote that sends something
/// before it goes silent.
class _DeadConnection extends YamuxMockConnection {
  _DeadConnection()
      : super('dead', localPeer: _peer(1), remotePeer: _peer(2));

  final attemptedWrites = <YamuxFrame>[];
  final _never = Completer<void>();
  final _inbound = StreamController<Uint8List>();
  late final _inboundQueue = StreamIterator(_inbound.stream);

  void deliver(YamuxFrame frame) => _inbound.add(frame.toBytes());

  @override
  Future<void> write(Uint8List data) async {
    attemptedWrites.add(YamuxFrame.fromBytes(data));
    await _never.future;
  }

  @override
  Future<Uint8List> read([int? length]) async {
    if (await _inboundQueue.moveNext()) return _inboundQueue.current;
    return Uint8List(0);
  }

  @override
  Future<void> close() async {
    // Not awaited: with no read pending, the done event is never delivered.
    unawaited(_inbound.close());
    await super.close();
  }
}

PeerId _peer(int seed) => PeerId.fromBytes(Uint8List.fromList(
    List.generate(34, (i) => (i % 250) + seed)..[0] = 0x12..[1] = 0x20));

Future<void> _until(bool Function() condition, String what,
    {Duration within = const Duration(seconds: 5)}) async {
  final deadline = DateTime.now().add(within);
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) fail('timed out waiting for $what');
    await Future.delayed(const Duration(milliseconds: 10));
  }
}

void main() {
  group('Yamux on a connection that died silently', () {
    test('close() completes although the GO_AWAY cannot be sent', () async {
      final conn = _DeadConnection();
      final session = YamuxSession(
          conn,
          const MultiplexerConfig(
            keepAliveInterval: Duration.zero,
            goAwayTimeout: Duration(milliseconds: 200),
          ),
          true);

      final watch = Stopwatch()..start();
      await session.close().timeout(const Duration(seconds: 2));
      expect(watch.elapsed, lessThan(const Duration(seconds: 1)));
      expect(session.isClosed, isTrue);
      expect(conn.isClosed, isTrue);
    });

    test('a second close() waits for the first one and does not send again', () async {
      final conn = _DeadConnection();
      final session = YamuxSession(
          conn,
          const MultiplexerConfig(
            keepAliveInterval: Duration.zero,
            goAwayTimeout: Duration(milliseconds: 200),
          ),
          true);

      await Future.wait([session.close(), session.close()])
          .timeout(const Duration(seconds: 2));
      final goAways =
          conn.attemptedWrites.where((f) => f.type == YamuxFrameType.goAway);
      expect(goAways, hasLength(1));
    });

    test('openStream fails within streamOpenTimeout', () async {
      final conn = _DeadConnection();
      final session = YamuxSession(
          conn,
          const MultiplexerConfig(
            keepAliveInterval: Duration.zero,
            streamOpenTimeout: Duration(milliseconds: 200),
            goAwayTimeout: Duration(milliseconds: 100),
          ),
          true);
      addTearDown(session.close);

      final watch = Stopwatch()..start();
      await expectLater(
          session.openStream(core_context.Context()), throwsA(isA<TimeoutException>()));
      expect(watch.elapsed, lessThan(const Duration(seconds: 1)));
      expect(session.numStreams, 0);
    });

    test('keep-alive closes the session when a ping goes unanswered', () async {
      final conn = _DeadConnection();
      final session = YamuxSession(
          conn,
          const MultiplexerConfig(
            keepAliveInterval: Duration(milliseconds: 100),
            keepAliveTimeout: Duration(milliseconds: 300),
            goAwayTimeout: Duration(milliseconds: 100),
          ),
          true);
      addTearDown(session.close);

      // One ping interval, the ping time-out, and the GO_AWAY time-out.
      await _until(() => session.isClosed && conn.isClosed, 'the session to close',
          within: const Duration(seconds: 2));
      final pings =
          conn.attemptedWrites.where((f) => f.type == YamuxFrameType.ping);
      expect(pings, hasLength(1), reason: 'one ping at a time, as go-yamux');
    });

    test('a received GO_AWAY closes the session without a GO_AWAY in reply', () async {
      final conn = _DeadConnection();
      final session = YamuxSession(
          conn, const MultiplexerConfig(keepAliveInterval: Duration.zero), true);
      addTearDown(session.close);

      // go-libp2p's ConnGarbageCollected.
      conn.deliver(YamuxFrame.goAway(0x1005));

      await _until(() => session.isClosed && conn.isClosed, 'the session to close');
      expect(conn.attemptedWrites.where((f) => f.type == YamuxFrameType.goAway), isEmpty);
    });
  });

  group('Yamux keep-alive on a live connection', () {
    test('the session stays open while pings are answered', () async {
      final (clientConn, serverConn) = YamuxMockConnection.createPair();
      const config = MultiplexerConfig(
        keepAliveInterval: Duration(milliseconds: 50),
        keepAliveTimeout: Duration(milliseconds: 200),
      );
      final client = YamuxSession(clientConn, config, true);
      final server = YamuxSession(serverConn, config, false);
      addTearDown(() async {
        await client.close();
        await server.close();
      });

      await Future.delayed(const Duration(milliseconds: 800));
      expect(client.isClosed, isFalse);
      expect(server.isClosed, isFalse);
    });
  });

  test('goAwayCodeName names yamux and go-libp2p codes', () {
    expect(goAwayCodeName(0), 'normal');
    expect(goAwayCodeName(1), 'protocolError');
    expect(goAwayCodeName(0x1005), 'garbage collected');
    expect(goAwayCodeName(0x4242), 'unknown');
  });
}
