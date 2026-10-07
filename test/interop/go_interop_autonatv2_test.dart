// Each test starts a go-libp2p process; under a busy full-suite run the
// default 30 s was not always enough.
@Timeout(Duration(seconds: 90))
library;

import 'dart:io';

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
import 'package:dart_libp2p/p2p/transport/udx_transport.dart';
import 'package:test/test.dart';

import 'helpers/go_process_manager.dart';

class _YamuxProvider extends StreamMuxer {
  _YamuxProvider()
      : super(
          id: YamuxConstants.protocolId,
          muxerFactory: (Conn secureConn, bool isClient) =>
              YamuxSession(secureConn as TransportConn, MultiplexerConfig(), isClient),
        );
}

/// A Dart host. As a server it answers AutoNAT v2 checks; [serverOptions]
/// go to its AutoNAT v2 service.
Future<BasicHost> _newHost({
  required String transport,
  required bool autoNATServer,
  String listenIp = '127.0.0.1',
  List<AutoNATv2Option> serverOptions = const [],
}) async {
  final keyPair = await crypto_ed25519.generateEd25519KeyPair();
  final connManager = ConnectionManager();
  final udx = transport == 'udx';
  final config = p2p_config.Config()
    ..peerKey = keyPair
    ..listenAddrs = [MultiAddr(udx ? '/ip4/$listenIp/udp/0/udx' : '/ip4/$listenIp/tcp/0')]
    ..securityProtocols = [await NoiseSecurity.create(keyPair)]
    ..muxers = [_YamuxProvider()]
    ..transports = [
      udx
          ? UDXTransport(connManager: connManager)
          : TCPTransport(resourceManager: NullResourceManager(), connManager: connManager)
    ]
    ..connManager = connManager
    ..enableHolePunching = false
    ..enableAutoNAT = autoNATServer
    ..autoNATv2Options = [allowPrivateAddrs(), ...serverOptions]
    // Skips the ambient prober; the AutoNAT v2 server still runs.
    ..forceReachability = autoNATServer ? Reachability.public : null;
  final host = await config.newNode() as BasicHost;
  await host.start();
  return host;
}

/// A non-loopback IPv4 address of this machine, or null.
Future<String?> _lanIp() async {
  for (final iface in await NetworkInterface.list(type: InternetAddressType.IPv4)) {
    for (final a in iface.addresses) {
      if (!a.isLoopback && !a.isLinkLocal) return a.address;
    }
  }
  return null;
}

/// Asks the Go AutoNAT v2 server at [go] to check [addr] for [client].
Future<Result> _checkWithGo(GoProcessManager go, BasicHost client, MultiAddr addr) async {
  final autoNAT = AutoNATv2Impl(client, client, options: [allowPrivateAddrs()]);
  await autoNAT.start();
  addTearDown(autoNAT.close);
  await client.connect(AddrInfo(go.peerId, [go.listenAddr]));
  // Let identify record the Go peer's protocols.
  await Future.delayed(const Duration(milliseconds: 500));
  return autoNAT.getReachability([Request(addr: addr, sendDialData: true)]);
}

void main() {
  late String goBinaryPath;

  setUpAll(() async {
    goBinaryPath = await GoProcessManager.ensureBinary(
        '${Directory.current.path}/interop/go-peer');
  });

  for (final transport in ['tcp', 'udx']) {
    group('AutoNAT v2 interop over $transport', () {
      test('a Go server checks a Dart address', () async {
        final go = GoProcessManager(binaryPath: goBinaryPath);
        await go.startAutoNATServer(transport: transport);
        addTearDown(go.stop);
        final client = await _newHost(transport: transport, autoNATServer: false);
        addTearDown(client.close);

        final result = await _checkWithGo(go, client, client.network.listenAddresses.first);

        expect(result.reachability, Reachability.public);
      });

      // The Go server asks for dial data when the IP of the address is not
      // the IP of the connection. The Dart client sends it (dart-libp2p-ta4).
      test('a Go server that asks for dial data gets it from Dart', () async {
        final lanIp = await _lanIp();
        if (lanIp == null) {
          markTestSkipped('No non-loopback IPv4 address');
          return;
        }
        final go = GoProcessManager(binaryPath: goBinaryPath);
        await go.startAutoNATServer(transport: transport);
        addTearDown(go.stop);
        // Listens on all interfaces, connects over loopback, asks about the
        // LAN address.
        final client = await _newHost(transport: transport, autoNATServer: false, listenIp: '0.0.0.0');
        addTearDown(client.close);
        final port = client.network.listenAddresses.first.valueForProtocol(transport == 'udx' ? 'udp' : 'tcp');
        final lanAddr = MultiAddr(transport == 'udx' ? '/ip4/$lanIp/udp/$port/udx' : '/ip4/$lanIp/tcp/$port');

        final result = await _checkWithGo(go, client, lanAddr);

        expect(result.reachability, Reachability.public);
        expect(go.output.join('\n'), isNot(contains('panic')));
      });

      test('a Dart server checks a Go address and gets dial data', () async {
        var dialDataAsked = false;
        final server = await _newHost(
          transport: transport,
          autoNATServer: true,
          serverOptions: [
            withDataRequestPolicy((_, __) {
              dialDataAsked = true;
              return true;
            })
          ],
        );
        addTearDown(server.close);
        final go = GoProcessManager(binaryPath: goBinaryPath);
        final target = '${server.network.listenAddresses.first}/p2p/${server.id.toBase58()}';

        final result = await go.runAutoNATClient(target, transport: transport);

        expect(result.exitCode, 0, reason: '${result.stdout}\n${result.stderr}');
        expect(result.stdout as String, contains('AutoNATResult: Public'));
        expect(dialDataAsked, isTrue);
      });
    });
  }
}
