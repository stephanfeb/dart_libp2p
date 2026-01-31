import 'dart:io';
import 'dart:typed_data';

import 'package:dart_libp2p/core/crypto/ed25519.dart' as crypto_ed25519;
import 'package:dart_libp2p/core/crypto/keys.dart';
import 'package:dart_libp2p/core/multiaddr.dart';
import 'package:dart_libp2p/core/peer/peer_id.dart';
import 'package:dart_libp2p/core/peer/addr_info.dart';
import 'package:dart_libp2p/core/network/conn.dart';
import 'package:dart_libp2p/core/network/transport_conn.dart';
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
import 'package:dart_libp2p_kad_dht/dart_libp2p_kad_dht.dart';
import 'package:dcid/dcid.dart';
import 'package:logging/logging.dart';
import 'package:test/test.dart';

import 'helpers/go_process_manager.dart';

/// Yamux muxer provider for Config.
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
        record.loggerName.contains('DHT') ||
        record.loggerName.contains('IpfsDHT') ||
        record.loggerName.contains('Noise') ||
        record.loggerName.contains('Yamux') ||
        record.loggerName.contains('BasicHost') ||
        record.loggerName.contains('identify') ||
        record.loggerName.contains('Identify')) {
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
      {List<MultiAddr>? listenAddrs}) async {
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
      ..addrsFactory = (addrs) => addrs;

    if (listenAddrs != null) {
      config.listenAddrs = listenAddrs;
    }

    final host = await config.newNode() as BasicHost;
    await host.start();
    return host;
  }

  // NOTE: These tests require dart-libp2p-kad-dht to use protobuf wire format
  // instead of JSON encoding. The Go DHT uses protobuf per the spec.
  // See: https://github.com/libp2p/specs/blob/master/kad-dht/README.md
  // Until the encoding is fixed, these tests will fail with JSON decode errors.
  group('Kademlia DHT Go-libp2p Interop', () {
    late GoProcessManager goDHTServer;
    BasicHost? dartHost;
    IpfsDHT? dartDHT;

    setUp(() {
      goDHTServer = GoProcessManager(binaryPath: goBinaryPath);
    });

    tearDown(() async {
      await goDHTServer.stop();
      if (dartDHT != null) {
        await dartDHT!.close();
        dartDHT = null;
      }
      if (dartHost != null) {
        await dartHost!.close();
        dartHost = null;
      }
    });

    test('Dart FIND_NODE via Go DHT bootstrap', skip: 'Requires protobuf wire format in dart-libp2p-kad-dht (currently uses JSON)', () async {
      // 1. Start Go DHT server
      await goDHTServer.startDHTServer();
      final goAddr = goDHTServer.listenAddr;
      final goPeerId = goDHTServer.peerId;
      print('Go DHT server: $goAddr (${goPeerId.toBase58()})');

      // 2. Create Dart host + DHT
      final keyPair = await crypto_ed25519.generateEd25519KeyPair();
      dartHost = await createHost(keyPair,
          listenAddrs: [MultiAddr('/ip4/127.0.0.1/tcp/0')]);

      dartDHT = IpfsDHT(
        host: dartHost!,
        providerStore: MemoryProviderStore(),
        options: DHTOptions(mode: DHTMode.server),
      );
      await dartDHT!.start();
      print('Dart DHT started');

      // 3. Connect to Go DHT server and add to routing table
      await dartHost!.connect(
          AddrInfo(goPeerId, [goAddr]),
          context: core_context.Context());
      await dartDHT!.routingTable.tryAddPeer(goPeerId, queryPeer: false);
      print('Connected to Go DHT server and added to routing table');

      // 4. Try to find the Go peer via DHT lookup
      final result = await dartDHT!.findPeer(goPeerId);
      print('findPeer result: $result');
      expect(result, isNotNull, reason: 'Should find the Go DHT peer');
      expect(result!.id, equals(goPeerId));
      print('FIND_NODE interop verified');
    }, timeout: Timeout(Duration(seconds: 60)));

    test('Go stores value, Dart retrieves via DHT', skip: 'Requires protobuf wire format in dart-libp2p-kad-dht (currently uses JSON)', () async {
      // 1. Start Go DHT server
      await goDHTServer.startDHTServer();
      final goAddr = goDHTServer.listenAddr;
      final goPeerId = goDHTServer.peerId;
      final goFullAddr = '$goAddr';
      print('Go DHT server: $goFullAddr');

      // 2. Go puts a value
      final goClient = GoProcessManager(binaryPath: goBinaryPath);
      final putResult = await goClient.runDHTPutValue(
          goFullAddr.toString(), '/test/key1', 'hello-from-go');
      print('Go put stdout: ${putResult.stdout}');
      print('Go put stderr: ${putResult.stderr}');
      expect(putResult.exitCode, 0, reason: 'Go PutValue should succeed');

      // 3. Create Dart host + DHT and connect
      final keyPair = await crypto_ed25519.generateEd25519KeyPair();
      dartHost = await createHost(keyPair,
          listenAddrs: [MultiAddr('/ip4/127.0.0.1/tcp/0')]);

      dartDHT = IpfsDHT(
        host: dartHost!,
        providerStore: MemoryProviderStore(),
        options: DHTOptions(mode: DHTMode.server),
      );
      await dartDHT!.start();

      await dartHost!.connect(
          AddrInfo(goPeerId, [goAddr]),
          context: core_context.Context());
      await dartDHT!.routingTable.tryAddPeer(goPeerId, queryPeer: false);
      print('Dart connected to Go DHT server');

      // 4. Dart gets the value
      final value = await dartDHT!.getValue('/test/key1', null);
      print('getValue result: ${value != null ? String.fromCharCodes(value) : null}');
      expect(value, isNotNull, reason: 'Should retrieve the stored value');
      expect(String.fromCharCodes(value!), equals('hello-from-go'));
      print('GET_VALUE interop verified');
    }, timeout: Timeout(Duration(seconds: 60)));

    test('Dart provides, Go finds providers via DHT', skip: 'Requires protobuf wire format in dart-libp2p-kad-dht (currently uses JSON)', () async {
      // 1. Start Go DHT server
      await goDHTServer.startDHTServer();
      final goAddr = goDHTServer.listenAddr;
      final goPeerId = goDHTServer.peerId;
      print('Go DHT server: $goAddr');

      // 2. Create Dart host + DHT
      final keyPair = await crypto_ed25519.generateEd25519KeyPair();
      final dartPeerId = await PeerId.fromPublicKey(keyPair.publicKey);
      dartHost = await createHost(keyPair,
          listenAddrs: [MultiAddr('/ip4/127.0.0.1/tcp/0')]);

      dartDHT = IpfsDHT(
        host: dartHost!,
        providerStore: MemoryProviderStore(),
        options: DHTOptions(mode: DHTMode.server),
      );
      await dartDHT!.start();

      await dartHost!.connect(
          AddrInfo(goPeerId, [goAddr]),
          context: core_context.Context());
      await dartDHT!.routingTable.tryAddPeer(goPeerId, queryPeer: false);
      print('Dart connected to Go DHT server');

      // 3. Dart provides a CID
      // Create a test CID from some data
      final testData = Uint8List.fromList('test-provide-data'.codeUnits);
      final testCid = CID.fromData(1, 'raw', testData);
      print('Dart providing CID: $testCid');
      await dartDHT!.provide(testCid, true);
      print('Dart provide complete');

      // 4. Go finds providers
      final goClient = GoProcessManager(binaryPath: goBinaryPath);
      final findResult = await goClient.runDHTFindProviders(
          goAddr.toString(), testCid.toString());
      print('Go find-providers stdout: ${findResult.stdout}');
      print('Go find-providers stderr: ${findResult.stderr}');

      expect(findResult.exitCode, 0,
          reason: 'Go FindProviders should succeed');
      expect(findResult.stdout.toString(),
          contains(dartPeerId.toBase58()),
          reason: 'Go should find Dart as a provider');
      print('PROVIDE/FIND_PROVIDERS interop verified');
    }, timeout: Timeout(Duration(seconds: 60)));

    test('Dart stores value, Go retrieves via DHT', skip: 'Requires protobuf wire format in dart-libp2p-kad-dht (currently uses JSON)', () async {
      // 1. Start Go DHT server
      await goDHTServer.startDHTServer();
      final goAddr = goDHTServer.listenAddr;
      final goPeerId = goDHTServer.peerId;
      print('Go DHT server: $goAddr');

      // 2. Create Dart host + DHT
      final keyPair = await crypto_ed25519.generateEd25519KeyPair();
      dartHost = await createHost(keyPair,
          listenAddrs: [MultiAddr('/ip4/127.0.0.1/tcp/0')]);

      dartDHT = IpfsDHT(
        host: dartHost!,
        providerStore: MemoryProviderStore(),
        options: DHTOptions(mode: DHTMode.server),
      );
      await dartDHT!.start();

      await dartHost!.connect(
          AddrInfo(goPeerId, [goAddr]),
          context: core_context.Context());
      await dartDHT!.routingTable.tryAddPeer(goPeerId, queryPeer: false);
      print('Dart connected to Go DHT server');

      // 3. Dart puts a value
      await dartDHT!.putValue(
          '/test/key2', Uint8List.fromList('hello-from-dart'.codeUnits));
      print('Dart putValue complete');

      // 4. Go gets the value
      final goClient = GoProcessManager(binaryPath: goBinaryPath);
      final getResult = await goClient.runDHTGetValue(
          goAddr.toString(), '/test/key2');
      print('Go get-value stdout: ${getResult.stdout}');
      print('Go get-value stderr: ${getResult.stderr}');

      expect(getResult.exitCode, 0,
          reason: 'Go GetValue should succeed');
      expect(getResult.stdout.toString(), contains('Value: hello-from-dart'));
      print('PUT_VALUE/GET_VALUE (Dart→Go) interop verified');
    }, timeout: Timeout(Duration(seconds: 60)));
  });
}
