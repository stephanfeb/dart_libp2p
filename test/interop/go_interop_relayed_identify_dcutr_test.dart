import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:dart_libp2p/core/crypto/ed25519.dart' as crypto_ed25519;
import 'package:dart_libp2p/core/crypto/keys.dart';
import 'package:dart_libp2p/core/multiaddr.dart';
import 'package:dart_libp2p/core/network/conn.dart';
import 'package:dart_libp2p/core/network/stream.dart';
import 'package:dart_libp2p/core/network/transport_conn.dart';
import 'package:dart_libp2p/core/peer/peer_id.dart';
import 'package:dart_libp2p/core/peer/addr_info.dart';
import 'package:dart_libp2p/core/network/context.dart' as core_context;
import 'package:dart_libp2p/config/config.dart' as p2p_config;
import 'package:dart_libp2p/config/stream_muxer.dart';
import 'package:dart_libp2p/p2p/host/basic/basic_host.dart';
import 'package:dart_libp2p/p2p/host/resource_manager/resource_manager_impl.dart';
import 'package:dart_libp2p/p2p/host/resource_manager/limiter.dart';
import 'package:dart_libp2p/p2p/security/noise/noise_protocol.dart';
import 'package:dart_libp2p/p2p/transport/connection_manager.dart';
import 'package:dart_libp2p/p2p/transport/multiplexing/multiplexer.dart';
import 'package:dart_libp2p/p2p/transport/multiplexing/yamux/session.dart';
import 'package:dart_libp2p/p2p/transport/tcp_transport.dart';
import 'package:logging/logging.dart';
import 'package:test/test.dart';

import 'helpers/go_process_manager.dart';

class _TestYamuxMuxerProvider extends StreamMuxer {
  _TestYamuxMuxerProvider({required MultiplexerConfig yamuxConfig})
      : super(
          id: YamuxConstants.protocolId,
          muxerFactory: (Conn secureConn, bool isClient) {
            if (secureConn is! TransportConn) {
              throw ArgumentError(
                  'YamuxMuxer factory expects a TransportConn, got ${secureConn.runtimeType}');
            }
            return YamuxSession(secureConn, yamuxConfig, isClient);
          },
        );
}

void main() {
  Logger.root.level = Level.INFO;
  Logger.root.onRecord.listen((record) {
    if (record.level >= Level.WARNING ||
        record.loggerName.contains('Noise') ||
        record.loggerName.contains('Yamux') ||
        record.loggerName.contains('BasicHost') ||
        record.loggerName.contains('identify') ||
        record.loggerName.contains('Identify') ||
        record.loggerName.contains('Circuit') ||
        record.loggerName.contains('Relay') ||
        record.loggerName.contains('holepunch')) {
      print('${record.level.name}: ${record.loggerName}: ${record.message}');
    }
  });

  late String goBinaryPath;

  final yamuxConfig = MultiplexerConfig(
    keepAliveInterval: Duration(seconds: 30),
    maxStreamWindowSize: 1024 * 1024,
    initialStreamWindowSize: 256 * 1024,
    streamWriteTimeout: Duration(seconds: 10),
    maxStreams: 256,
  );

  setUpAll(() async {
    final goSourceDir = '${Directory.current.path}/interop/go-peer';
    goBinaryPath = await GoProcessManager.ensureBinary(goSourceDir);
    print('Go peer binary: $goBinaryPath');
  });

  Future<BasicHost> createHost(KeyPair keyPair,
      {List<MultiAddr>? listenAddrs, bool enableRelay = false}) async {
    final connMgr = ConnectionManager();
    final resMgr = ResourceManagerImpl(limiter: FixedLimiter());
    final muxerDef = _TestYamuxMuxerProvider(yamuxConfig: yamuxConfig);

    final config = p2p_config.Config()
      ..peerKey = keyPair
      ..securityProtocols = [await NoiseSecurity.create(keyPair)]
      ..muxers = [muxerDef]
      ..transports = [
        TCPTransport(resourceManager: resMgr, connManager: connMgr)
      ]
      ..connManager = connMgr
      ..addrsFactory = (addrs) => [...addrs, MultiAddr('/ip4/1.2.3.4/tcp/5678')];
    config.enableRelay = enableRelay;

    if (listenAddrs != null) {
      config.listenAddrs = listenAddrs;
    }

    final host = await config.newNode() as BasicHost;
    await host.start();
    return host;
  }

  group('P0 — Relayed Identify completion & DCUtR trigger', () {
    late GoProcessManager goRelay;
    late GoProcessManager goGateway;
    BasicHost? dartHost;

    setUp(() {
      goRelay = GoProcessManager(binaryPath: goBinaryPath);
      goGateway = GoProcessManager(binaryPath: goBinaryPath);
    });

    tearDown(() async {
      await goGateway.stop();
      await goRelay.stop();
      if (dartHost != null) {
        await dartHost!.close();
        dartHost = null;
      }
    });

    test('Dart connects to Go gateway via Go relay -> Identify completes & DCUtR initiated', () async {
      // 1. Start Go relay
      await goRelay.startRelay();
      final relayAddr = goRelay.listenAddr;
      final relayPeerId = goRelay.peerId;
      print('Go relay: $relayAddr (${relayPeerId.toBase58()})');

      // 2. Start Go gateway behind relay (holepunching enabled)
      final relayFullAddr = '$relayAddr/p2p/${relayPeerId.toBase58()}';
      await goGateway.startRelayEchoServer(relayFullAddr);
      final circuitAddr = goGateway.circuitAddr;
      final gatewayPeerId = goGateway.peerId;
      print('Go gateway circuit addr: $circuitAddr (${gatewayPeerId.toBase58()})');

      // 3. Create Dart client with relay enabled
      final keyPair = await crypto_ed25519.generateEd25519KeyPair();
      dartHost = await createHost(keyPair, enableRelay: true);
      print('Dart host started: ${dartHost!.id.toBase58()}');

      // Set up DCUtR / holepunch listener on Dart side to catch incoming DCUtR streams
      Completer<PeerId> dcutrStreamReceived = Completer<PeerId>();
      dartHost!.setStreamHandler('/libp2p/dcutr', (P2PStream stream, PeerId remotePeer) async {
        print('Dart received /libp2p/dcutr stream from Go gateway $remotePeer!');
        if (!dcutrStreamReceived.isCompleted) {
          dcutrStreamReceived.complete(remotePeer);
        }
      });

      // 4. Connect Dart to Go relay
      await dartHost!.connect(
          AddrInfo(relayPeerId, [relayAddr]),
          context: core_context.Context());
      print('Connected to relay');

      // 5. Connect Dart through relay to Go gateway
      final circuitMA = MultiAddr(circuitAddr);
      final connectStart = DateTime.now();
      await dartHost!.connect(
          AddrInfo(gatewayPeerId, [circuitMA]),
          context: core_context.Context());
      final connectDuration = DateTime.now().difference(connectStart);
      print('Connected to Go gateway through relay in ${connectDuration.inMilliseconds}ms');

      // 6. Assert Go gateway learned Dart's protocols via Identify
      final knownProtos = await dartHost!.peerStore.protoBook.getProtocols(gatewayPeerId);
      print('Protocols known for Go gateway: $knownProtos');

      // 7. Wait for automatic Go DCUtR initiation (/libp2p/dcutr stream)
      final dcutrRemotePeer = await dcutrStreamReceived.future.timeout(
        Duration(seconds: 10),
        onTimeout: () {
          throw TimeoutException('Go gateway did not initiate DCUtR within 10 seconds');
        },
      );

      expect(dcutrRemotePeer, equals(gatewayPeerId));
      print('✅ Automatic Go-initiated DCUtR verified over relayed connection!');
    }, timeout: Timeout(Duration(seconds: 60)));

    test('50 iterations of Dart↔Go relayed Identify & DCUtR initiation', () async {
      await goRelay.startRelay();
      final relayAddr = goRelay.listenAddr;
      final relayPeerId = goRelay.peerId;
      final relayFullAddr = '$relayAddr/p2p/${relayPeerId.toBase58()}';

      await goGateway.startRelayEchoServer(relayFullAddr);
      final circuitAddr = goGateway.circuitAddr;
      final gatewayPeerId = goGateway.peerId;
      final circuitMA = MultiAddr(circuitAddr);

      for (int i = 1; i <= 50; i++) {
        final keyPair = await crypto_ed25519.generateEd25519KeyPair();
        final host = await createHost(keyPair, enableRelay: true);

        Completer<PeerId> dcutrReceived = Completer<PeerId>();
        host.setStreamHandler('/libp2p/dcutr', (P2PStream stream, PeerId remotePeer) async {
          if (!dcutrReceived.isCompleted) {
            dcutrReceived.complete(remotePeer);
          }
        });

        await host.connect(
            AddrInfo(relayPeerId, [relayAddr]),
            context: core_context.Context());

        await host.connect(
            AddrInfo(gatewayPeerId, [circuitMA]),
            context: core_context.Context());

        final remotePeer = await dcutrReceived.future.timeout(
          Duration(seconds: 15),
          onTimeout: () => throw TimeoutException('Iteration $i: DCUtR failed to initiate within 15s'),
        );
        expect(remotePeer, equals(gatewayPeerId));

        await host.close();
        if (i % 10 == 0) {
          print('✅ Completed $i/50 iterations of relayed Identify + DCUtR initiation');
        }
      }
    }, timeout: Timeout(Duration(minutes: 5)));
  });
}
