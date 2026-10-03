import 'package:dart_libp2p/config/config.dart' as p2p_config;
import 'package:dart_libp2p/config/stream_muxer.dart';
import 'package:dart_libp2p/core/crypto/ed25519.dart' as crypto_ed25519;
import 'package:dart_libp2p/core/multiaddr.dart';
import 'package:dart_libp2p/core/network/conn.dart';
import 'package:dart_libp2p/core/network/network.dart' show Reachability;
import 'package:dart_libp2p/core/network/rcmgr.dart';
import 'package:dart_libp2p/core/network/transport_conn.dart';
import 'package:dart_libp2p/core/peer/addr_info.dart';
import 'package:dart_libp2p/core/protocol/autonatv2/autonatv2.dart';
import 'package:dart_libp2p/p2p/host/basic/basic_host.dart';
import 'package:dart_libp2p/p2p/protocol/autonatv2/autonatv2.dart';
import 'package:dart_libp2p/p2p/protocol/autonatv2/options.dart';
import 'package:dart_libp2p/p2p/security/noise/noise_protocol.dart';
import 'package:dart_libp2p/p2p/transport/connection_manager.dart';
import 'package:dart_libp2p/p2p/transport/multiplexing/multiplexer.dart';
import 'package:dart_libp2p/p2p/transport/multiplexing/yamux/session.dart';
import 'package:dart_libp2p/p2p/transport/tcp_transport.dart';
import 'package:test/test.dart';

class _YamuxProvider extends StreamMuxer {
  _YamuxProvider()
      : super(
          id: YamuxConstants.protocolId,
          muxerFactory: (Conn secureConn, bool isClient) =>
              YamuxSession(secureConn as TransportConn, MultiplexerConfig(), isClient),
        );
}

Future<BasicHost> _newHost({required bool autoNATServer}) async {
  final keyPair = await crypto_ed25519.generateEd25519KeyPair();
  final connManager = ConnectionManager();
  final config = p2p_config.Config()
    ..peerKey = keyPair
    ..listenAddrs = [MultiAddr('/ip4/127.0.0.1/tcp/0')]
    ..securityProtocols = [await NoiseSecurity.create(keyPair)]
    ..muxers = [_YamuxProvider()]
    ..transports = [TCPTransport(resourceManager: NullResourceManager(), connManager: connManager)]
    ..connManager = connManager
    ..enableHolePunching = false
    ..enableAutoNAT = autoNATServer
    ..autoNATv2Options = [allowPrivateAddrs()]
    // Skips the ambient prober; the AutoNAT v2 server still runs.
    ..forceReachability = autoNATServer ? Reachability.public : null;
  final host = await config.newNode() as BasicHost;
  await host.start();
  return host;
}

void main() {
  group('AutoNAT v2 dial-back', () {
    late BasicHost server;
    late BasicHost client;
    late AutoNATv2Impl clientAutoNAT;

    setUp(() async {
      server = await _newHost(autoNATServer: true);
      client = await _newHost(autoNATServer: false);
      clientAutoNAT = AutoNATv2Impl(client, client, options: [allowPrivateAddrs()]);
      await clientAutoNAT.start();
    });

    tearDown(() async {
      await clientAutoNAT.close();
      await client.close();
      await server.close();
    });

    test('leaves the server\'s own connection and addresses for the peer alone', () async {
      await client.connect(AddrInfo(server.id, server.network.listenAddresses));
      final clientAddr = client.network.listenAddresses.first;
      await server.peerStore.addrBook.addAddrs(client.id, [clientAddr], const Duration(hours: 1));
      // Let identify record the server's protocols on the client.
      await Future.delayed(const Duration(milliseconds: 500));

      final result = await clientAutoNAT.getReachability([Request(addr: clientAddr)]);

      expect(result.reachability, Reachability.public);
      // The dial-back must come from a separate dialer host. On the server
      // host itself its cleanup closed every connection to the client and
      // cleared the client's addresses.
      expect(server.network.connsToPeer(client.id), isNotEmpty);
      expect(await server.peerStore.addrBook.addrs(client.id), contains(clientAddr));
    });
  });
}
