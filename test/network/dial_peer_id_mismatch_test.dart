import 'package:dart_libp2p/config/config.dart';
import 'package:dart_libp2p/core/crypto/ed25519.dart';
import 'package:dart_libp2p/core/host/host.dart';
import 'package:dart_libp2p/core/multiaddr.dart';
import 'package:dart_libp2p/core/network/network.dart';
import 'package:dart_libp2p/core/peer/addr_info.dart';
import 'package:dart_libp2p/core/peer/peer_id.dart';
import 'package:dart_libp2p/p2p/security/noise/noise_protocol.dart';
import 'package:dart_libp2p/p2p/transport/tcp_transport.dart';
import 'package:test/test.dart';

Future<Host> _host() async {
  final keyPair = await generateEd25519KeyPair();
  final host = await Libp2p.new_([
    Libp2p.identity(keyPair),
    Libp2p.transport(TCPTransport()),
    Libp2p.security(await NoiseSecurity.create(keyPair)),
    Libp2p.listenAddrs([MultiAddr('/ip4/127.0.0.1/tcp/0')]),
    Libp2p.autoNAT(false),
    Libp2p.relay(false),
    Libp2p.autoRelay(false),
    Libp2p.holePunching(false),
  ]);
  await host.start();
  return host;
}

void main() {
  group('Dialing a peer ID', () {
    late Host dialer;
    late Host answerer;

    setUp(() async {
      dialer = await _host();
      answerer = await _host();
    });

    tearDown(() async {
      await dialer.close();
      await answerer.close();
    });

    test('fails when a different peer answers at the address', () async {
      // Another device copies X's identity (e.g. in a BLE advertisement), but
      // the Noise handshake proves it is the answerer.
      final x = PeerId.fromPublicKey((await generateEd25519KeyPair()).publicKey);

      await expectLater(
        dialer.connect(AddrInfo(x, answerer.network.listenAddresses)),
        throwsA(predicate((e) => '$e'.contains('PeerIdMismatchException'))),
      );
      expect(dialer.network.connectedness(x), equals(Connectedness.notConnected));
      // The connection to the peer that did answer is closed, not kept.
      expect(dialer.network.connectedness(answerer.id), equals(Connectedness.notConnected));
      expect(dialer.network.conns, isEmpty);
    });

    test('succeeds when the dialed peer answers', () async {
      await dialer.connect(AddrInfo(answerer.id, answerer.network.listenAddresses));
      expect(dialer.network.connectedness(answerer.id), equals(Connectedness.connected));
    });
  });
}
