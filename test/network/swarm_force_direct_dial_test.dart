import 'package:dart_libp2p/config/config.dart';
import 'package:dart_libp2p/core/crypto/ed25519.dart';
import 'package:dart_libp2p/core/multiaddr.dart';
import 'package:dart_libp2p/core/network/context.dart';
import 'package:dart_libp2p/core/network/rcmgr.dart';
import 'package:dart_libp2p/core/peer/peer_id.dart';
import 'package:dart_libp2p/p2p/host/basic/basic_host.dart';
import 'package:dart_libp2p/p2p/host/peerstore/pstoremem/peerstore.dart';
import 'package:dart_libp2p/p2p/network/swarm/swarm.dart';
import 'package:dart_libp2p/core/network/conn.dart';
import 'package:dart_libp2p/p2p/transport/basic_upgrader.dart';
import 'package:dart_libp2p/p2p/transport/listener.dart';
import 'package:dart_libp2p/p2p/transport/transport.dart';
import 'package:dart_libp2p/p2p/transport/transport_config.dart';
import 'package:test/test.dart';

/// Records the simultaneousConnect flag of each dial and fails it.
class _RecordingTransport implements Transport {
  final List<bool> simultaneousConnects = [];

  @override
  TransportConfig get config => TransportConfig.defaultConfig;

  @override
  Future<Conn> dial(MultiAddr addr, {Duration? timeout, bool simultaneousConnect = false}) async {
    simultaneousConnects.add(simultaneousConnect);
    throw Exception('recording transport does not connect');
  }

  @override
  Future<Listener> listen(MultiAddr addr) => throw UnimplementedError();

  @override
  List<String> get protocols => ['/udx'];

  @override
  bool canDial(MultiAddr addr) => addr.hasProtocol('udx');

  @override
  bool canListen(MultiAddr addr) => false;

  @override
  Future<void> dispose() async {}
}

void main() {
  group('Swarm.dialPeer with forceDirectDial', () {
    late BasicHost host;
    late Swarm swarm;
    late MemoryPeerstore peerstore;
    late PeerId remote;
    late _RecordingTransport transport;

    setUp(() async {
      final keyPair = await generateEd25519KeyPair();
      final localPeerId = PeerId.fromPublicKey(keyPair.publicKey);
      final remoteKeyPair = await generateEd25519KeyPair();
      remote = PeerId.fromPublicKey(remoteKeyPair.publicKey);

      peerstore = MemoryPeerstore();
      transport = _RecordingTransport();
      final resourceManager = NullResourceManager();
      final config = Config();
      swarm = Swarm(
        host: null,
        localPeer: localPeerId,
        peerstore: peerstore,
        resourceManager: resourceManager,
        upgrader: BasicUpgrader(resourceManager: resourceManager),
        config: config,
        transports: [transport],
      );
      host = await BasicHost.create(network: swarm, config: config);
      swarm.setHost(host);
    });

    tearDown(() async {
      await host.close();
    });

    test('never dials a relay address', () async {
      // A DCUtR punch dial must not be satisfied by opening a new relayed
      // connection, so a peer known only by a circuit address has nothing
      // to dial.
      final relayId = PeerId.fromPublicKey((await generateEd25519KeyPair()).publicKey);
      await peerstore.addrBook.addAddrs(
        remote,
        [MultiAddr('/ip4/100.70.3.10/tcp/4001/p2p/${relayId.toBase58()}/p2p-circuit')],
        const Duration(minutes: 5),
      );

      await expectLater(
        swarm.dialPeer(Context().withForceDirectDial('hole-punching'), remote),
        throwsA(predicate((e) => e.toString().contains('No dialable addresses'))),
      );
    });

    test('marks only a simultaneous connect as one for the transport', () async {
      await peerstore.addrBook.addAddrs(
        remote,
        [MultiAddr('/ip4/100.70.1.20/udp/4001/udx')],
        const Duration(minutes: 5),
      );

      // DCUtR's uncoordinated direct dial before the punch: must not use
      // the punch socket.
      await expectLater(
        swarm.dialPeer(Context().withForceDirectDial('hole-punching'), remote),
        throwsA(anything),
      );
      // The punch itself.
      await expectLater(
        swarm.dialPeer(
          Context().withSimultaneousConnect(true, 'hole-punching').withForceDirectDial('hole-punching'),
          remote,
        ),
        throwsA(anything),
      );

      expect(transport.simultaneousConnects, [false, true]);
    });
  });
}
