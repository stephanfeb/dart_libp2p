import 'dart:async';
import 'dart:typed_data';

import 'package:dart_libp2p/core/network/context.dart' as core_context;
import 'package:dart_libp2p/core/network/stream.dart';
import 'package:dart_libp2p/core/peer/peer_id.dart';
import 'package:dart_libp2p/p2p/transport/multiplexing/multiplexer.dart';
import 'package:dart_libp2p/p2p/transport/multiplexing/yamux/session.dart';
import 'package:test/test.dart';

import '../../../mocks/yamux_mock_connection.dart';

/// A mock connection whose writes can be held and whose reads end on
/// demand, so a test can make the session see the remote go away while a
/// SYN is still being written, as a stalled UDX write does in practice.
class _StallingConnection extends YamuxMockConnection {
  _StallingConnection(super.id,
      {required super.localPeer, required super.remotePeer});

  final hold = Completer<void>();
  final eof = Completer<void>();

  @override
  Future<void> write(Uint8List data) async {
    await hold.future;
    return super.write(data);
  }

  @override
  Future<Uint8List> read([int? length]) async {
    await eof.future;
    return Uint8List(0);
  }
}

const _config = MultiplexerConfig(
  keepAliveInterval: Duration.zero,
  streamReadTimeout: Duration(seconds: 5),
  streamWriteTimeout: Duration(seconds: 5),
  maxStreams: 8,
);

PeerId _peer(int seed) => PeerId.fromBytes(Uint8List.fromList(
    List.generate(34, (i) => (i % 250) + seed)..[0] = 0x12..[1] = 0x20));

Future<void> _until(bool Function() condition, String what) async {
  final deadline = DateTime.now().add(const Duration(seconds: 5));
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) fail('timed out waiting for $what');
    await Future.delayed(const Duration(milliseconds: 10));
  }
}

void main() {
  group('Yamux stream release', () {
    late YamuxMockConnection clientConn;
    late YamuxMockConnection serverConn;
    late YamuxSession client;
    late YamuxSession server;

    setUp(() {
      (clientConn, serverConn) = YamuxMockConnection.createPair(
        autoRespondToSyn: false,
        autoRespondToPing: false,
      );
      client = YamuxSession(clientConn, _config, true);
      server = YamuxSession(serverConn, _config, false);
    });

    tearDown(() async {
      await client.close();
      await server.close();
      await clientConn.close();
      await serverConn.close();
    });

    // Closed streams used to stay in the session's table until the session
    // closed, so every connection refused its maxStreams'th stream.
    test('closed streams free their slot, so a session outlives maxStreams',
        () async {
      server.setStreamHandler((P2PStream stream) async {
        final request = await stream.read();
        await stream.write(request);
        await stream.close();
      });

      final rounds = _config.maxStreams * 4;
      for (var i = 0; i < rounds; i++) {
        final stream = await client.openStream(core_context.Context())
            as P2PStream<Uint8List>;
        await stream.write(Uint8List.fromList([i % 256]));
        expect(await stream.read(), [i % 256]);
        await stream.close();
      }

      await _until(() => client.numStreams == 0 && server.numStreams == 0,
          'both tables to empty');
      expect(client.canCreateStream, isTrue);
    });

    test('a stream reset by the remote frees its slot', () async {
      server.setStreamHandler((P2PStream stream) async {
        await stream.reset();
      });

      final stream = await client.openStream(core_context.Context())
          as P2PStream<Uint8List>;
      expect(client.numStreams, 1);
      await _until(() => client.numStreams == 0, 'the reset to arrive');
      expect(stream.isClosed, isTrue);
    });

    test('a stream half-closed by the remote frees its slot once read to EOF',
        () async {
      server.setStreamHandler((P2PStream stream) async {
        await stream.write(Uint8List.fromList([7]));
        await stream.closeWrite();
      });

      final stream = await client.openStream(core_context.Context())
          as P2PStream<Uint8List>;
      expect(await stream.read(), [7]);
      expect(await stream.read(), isEmpty);
      await stream.close();
      expect(client.numStreams, 0);
    });
  });

  group('Yamux session closing during openStream', () {
    // The ACK completer used to fail with no listener while the SYN write
    // was still pending, which surfaced as an uncaught "Session closed while
    // opening stream" error in the caller's zone. The test package fails a
    // test on any uncaught error, so passing means none escaped.
    test('fails the openStream call and leaks no uncaught error', () async {
      final clientConn = _StallingConnection('client',
          localPeer: _peer(1), remotePeer: _peer(2));
      final session = YamuxSession(clientConn, _config, true);
      final opening = session.openStream(core_context.Context());

      // The remote goes away under the pending SYN write: the read loop sees
      // EOF and tears the session down without waiting for the write.
      await Future.delayed(const Duration(milliseconds: 20));
      clientConn.eof.complete();
      await _until(() => session.isClosed, 'the session to close');
      await Future.delayed(const Duration(milliseconds: 20));

      await clientConn.close();
      clientConn.hold.complete();
      await expectLater(opening, throwsA(anything));
      expect(session.numStreams, 0);
    });
  });
}
