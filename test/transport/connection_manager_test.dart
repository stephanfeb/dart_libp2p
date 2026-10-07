import 'package:dart_libp2p/core/crypto/ed25519.dart';
import 'package:dart_libp2p/core/multiaddr.dart';
import 'package:dart_libp2p/core/peer/peer_id.dart';
import 'package:dart_libp2p/p2p/transport/connection_manager.dart';
import 'package:test/test.dart';

import '../mocks/streamlined_mock_transport_conn.dart';

Future<StreamlinedMockTransportConn> _newConn(String id) async {
  final local = PeerId.fromPublicKey((await generateEd25519KeyPair()).publicKey);
  final remote = PeerId.fromPublicKey((await generateEd25519KeyPair()).publicKey);
  return StreamlinedMockTransportConn(
    id: id,
    localAddr: MultiAddr('/ip4/127.0.0.1/udp/4001/udx'),
    remoteAddr: MultiAddr('/ip4/127.0.0.1/udp/4002/udx'),
    localPeer: local,
    remotePeer: remote,
  );
}

void main() {
  group('ConnectionManager', () {
    test('recordActivity ignores a connection it does not know', () async {
      final manager = ConnectionManager();
      final conn = await _newConn('unknown');

      expect(() => manager.recordActivity(conn), returnsNormally);
      expect(manager.getState(conn), isNull);
      await manager.dispose();
    });

    test('recordActivity ignores a connection removed by dispose', () async {
      final manager = ConnectionManager();
      final conn = await _newConn('removed');
      manager.registerConnection(conn);

      await manager.dispose();

      expect(() => manager.recordActivity(conn), returnsNormally);
    });

    test('a connection registered during dispose is closed, not dropped', () async {
      final manager = ConnectionManager();
      final existing = await _newConn('existing');
      final late = await _newConn('late');
      manager.registerConnection(existing);

      // A listener accepts a session while closeAll is still running.
      final disposing = manager.dispose();
      manager.registerConnection(late);
      await disposing;
      await Future<void>.delayed(Duration.zero);

      expect(existing.isClosed, isTrue);
      expect(late.isClosed, isTrue);
      expect(manager.getState(late), isNull);
      expect(() => manager.recordActivity(late), returnsNormally);
    });
  });
}
