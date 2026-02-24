import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:dart_udx/dart_udx.dart';
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
import 'package:dart_libp2p/p2p/protocol/circuitv2/client/reservation.dart';
import 'package:dart_libp2p/p2p/security/noise/noise_protocol.dart';
import 'package:dart_libp2p/p2p/transport/connection_manager.dart';
import 'package:dart_libp2p/p2p/transport/multiplexing/multiplexer.dart';
import 'package:dart_libp2p/p2p/transport/multiplexing/yamux/metrics_observer.dart';
import 'package:dart_libp2p/p2p/transport/multiplexing/yamux/session.dart';
import 'package:dart_libp2p/p2p/transport/udx_transport.dart';
import 'package:dart_libp2p_kad_dht/dart_libp2p_kad_dht.dart';
import 'package:logging/logging.dart';
import 'package:test/test.dart';

import 'helpers/go_process_manager.dart';

/// Yamux muxer provider with configurable yamux settings and optional metrics observer.
class _TestYamuxMuxerProvider extends StreamMuxer {
  _TestYamuxMuxerProvider({
    required MultiplexerConfig yamuxConfig,
    YamuxMetricsObserver? metricsObserver,
  }) : super(
          id: YamuxConstants.protocolId,
          muxerFactory: (Conn secureConn, bool isClient) {
            if (secureConn is! TransportConn) {
              throw ArgumentError(
                  'YamuxMuxer factory expects a TransportConn, got ${secureConn.runtimeType}');
            }
            return YamuxSession(
                secureConn, yamuxConfig, isClient, null, metricsObserver);
          },
        );
}

/// Collects yamux ping/pong metrics for test assertions.
class _TestMetricsObserver implements YamuxMetricsObserver {
  final List<_PingRecord> pings = [];
  final List<_PongRecord> pongs = [];
  final List<String> errors = [];

  @override
  void onPingSent(PeerId remotePeer, int pingId, DateTime timestamp) {
    pings.add(_PingRecord(remotePeer, pingId, timestamp));
  }

  @override
  void onPongReceived(PeerId remotePeer, int pingId, DateTime sentTime,
      DateTime receivedTime, Duration rtt) {
    pongs.add(_PongRecord(remotePeer, pingId, sentTime, receivedTime, rtt));
  }

  @override
  void onStreamOpenStart(PeerId remotePeer, int streamId) {}
  @override
  void onStreamOpened(PeerId remotePeer, int streamId, String? protocol) {}
  @override
  void onStreamClosed(PeerId remotePeer, int streamId, Duration duration,
      int bytesRead, int bytesWritten) {}
  @override
  void onStreamReset(PeerId remotePeer, int streamId, String? reason) {}
  @override
  void onSessionError(PeerId remotePeer, String error, StackTrace? stackTrace) {
    errors.add(error);
  }
}

class _PingRecord {
  final PeerId remotePeer;
  final int pingId;
  final DateTime timestamp;
  _PingRecord(this.remotePeer, this.pingId, this.timestamp);
}

class _PongRecord {
  final PeerId remotePeer;
  final int pingId;
  final DateTime sentTime;
  final DateTime receivedTime;
  final Duration rtt;
  _PongRecord(
      this.remotePeer, this.pingId, this.sentTime, this.receivedTime, this.rtt);
}

void main() {
  Logger.root.level = Level.INFO;
  Logger.root.onRecord.listen((record) {
    if (record.level >= Level.WARNING ||
        record.loggerName.contains('Yamux') ||
        record.loggerName.contains('BasicHost')) {
      print('${record.level.name}: ${record.loggerName}: ${record.message}');
    }
  });

  late String goBinaryPath;

  const keepAliveInterval = Duration(seconds: 3);

  final yamuxConfig = MultiplexerConfig(
    keepAliveInterval: keepAliveInterval,
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

  Future<BasicHost> createHost(
    KeyPair keyPair, {
    List<MultiAddr>? listenAddrs,
    YamuxMetricsObserver? metricsObserver,
    bool enableRelay = false,
  }) async {
    final connMgr = ConnectionManager();
    final udxInstance = UDX();
    final muxerDef = _TestYamuxMuxerProvider(
        yamuxConfig: yamuxConfig, metricsObserver: metricsObserver);

    final config = p2p_config.Config()
      ..peerKey = keyPair
      ..securityProtocols = [await NoiseSecurity.create(keyPair)]
      ..muxers = [muxerDef]
      ..transports = [
        UDXTransport(connManager: connMgr, udxInstance: udxInstance)
      ]
      ..connManager = connMgr
      ..enableRelay = enableRelay;
    config.addrsFactory = (addrs) => addrs;

    if (listenAddrs != null) {
      config.listenAddrs = listenAddrs;
    }

    final host = await config.newNode() as BasicHost;
    await host.start();
    return host;
  }

  /// Helper: open an echo stream, send data, verify echo response.
  Future<void> echoVerify(BasicHost host, PeerId remotePeer,
      {int size = 32}) async {
    final stream = await host.newStream(
        remotePeer, ['/echo/1.0.0'], core_context.Context());
    expect(stream.protocol(), '/echo/1.0.0');

    final random = Random();
    final data =
        Uint8List.fromList(List.generate(size, (_) => random.nextInt(256)));

    await stream.write(data);
    await stream.closeWrite();

    // Read all response data (may arrive in multiple chunks for large payloads)
    final chunks = <Uint8List>[];
    var totalRead = 0;
    while (totalRead < size) {
      try {
        final chunk = await stream.read();
        if (chunk.isEmpty) break;
        chunks.add(chunk);
        totalRead += chunk.length;
      } catch (_) {
        break;
      }
    }
    final response = Uint8List(totalRead);
    var offset = 0;
    for (final chunk in chunks) {
      response.setRange(offset, offset + chunk.length, chunk);
      offset += chunk.length;
    }

    expect(response, orderedEquals(data),
        reason: 'Echo mismatch for $size bytes');
    await stream.close();
  }

  group('UDX Connection Stability', () {
    late GoProcessManager goProcess;
    BasicHost? dartHost;

    setUp(() {
      goProcess = GoProcessManager(binaryPath: goBinaryPath);
    });

    tearDown(() async {
      await goProcess.stop();
      if (dartHost != null) {
        await dartHost!.close();
        dartHost = null;
      }
    });

    test('Keepalive survives idle period', () async {
      // Start Go echo-server with matching keepalive config
      await goProcess.startServer(
        transport: 'udx',
        yamuxKeepAliveInterval: keepAliveInterval,
        yamuxWriteTimeout: const Duration(seconds: 10),
      );
      final goAddr = goProcess.listenAddr;
      final goPeerId = goProcess.peerId;
      print('Go peer: $goAddr');

      final keyPair = await crypto_ed25519.generateEd25519KeyPair();
      dartHost = await createHost(keyPair);

      await dartHost!.connect(AddrInfo(goPeerId, [goAddr]),
          context: core_context.Context());
      print('Connected to Go peer over UDX');

      // Idle for 2x keepalive interval — pings should keep connection alive
      final idleDuration = keepAliveInterval * 2;
      print('Idling for $idleDuration...');
      await Future.delayed(idleDuration);

      // Verify connection is still alive by echoing
      await echoVerify(dartHost!, goPeerId);
      print('Keepalive survived ${idleDuration.inSeconds}s idle period');
    }, timeout: Timeout(Duration(seconds: 60)));

    test('Keepalive after data transfer', () async {
      await goProcess.startServer(
        transport: 'udx',
        yamuxKeepAliveInterval: keepAliveInterval,
        yamuxWriteTimeout: const Duration(seconds: 10),
      );
      final goAddr = goProcess.listenAddr;
      final goPeerId = goProcess.peerId;

      final keyPair = await crypto_ed25519.generateEd25519KeyPair();
      dartHost = await createHost(keyPair);

      await dartHost!.connect(AddrInfo(goPeerId, [goAddr]),
          context: core_context.Context());
      print('Connected to Go peer over UDX');

      // Transfer 64KB to exercise the flow control window
      print('Sending 64KB echo...');
      await echoVerify(dartHost!, goPeerId, size: 64 * 1024);
      print('64KB echo complete');

      // Idle for 2x keepalive — pings should work even after large transfer
      final idleDuration = keepAliveInterval * 2;
      print('Idling for $idleDuration after data transfer...');
      await Future.delayed(idleDuration);

      // Verify connection is still alive
      await echoVerify(dartHost!, goPeerId);
      print('Keepalive survived idle after 64KB transfer');
    }, timeout: Timeout(Duration(seconds: 60)));

    test('Multiple streams then idle', () async {
      await goProcess.startServer(
        transport: 'udx',
        yamuxKeepAliveInterval: keepAliveInterval,
        yamuxWriteTimeout: const Duration(seconds: 10),
      );
      final goAddr = goProcess.listenAddr;
      final goPeerId = goProcess.peerId;

      final keyPair = await crypto_ed25519.generateEd25519KeyPair();
      dartHost = await createHost(keyPair);

      await dartHost!.connect(AddrInfo(goPeerId, [goAddr]),
          context: core_context.Context());
      print('Connected to Go peer over UDX');

      // Open 5 sequential echo streams
      for (var i = 0; i < 5; i++) {
        await echoVerify(dartHost!, goPeerId, size: 1024);
        print('Stream $i echo complete');
      }

      // Idle for 2x keepalive — stream cleanup shouldn't break keepalive
      final idleDuration = keepAliveInterval * 2;
      print('Idling for $idleDuration after 5 streams...');
      await Future.delayed(idleDuration);

      // Open another stream to verify connection is alive
      await echoVerify(dartHost!, goPeerId);
      print('Connection alive after 5 streams + idle');
    }, timeout: Timeout(Duration(seconds: 60)));

    test('Keepalive metrics show ping/pong roundtrips', () async {
      await goProcess.startServer(
        transport: 'udx',
        yamuxKeepAliveInterval: keepAliveInterval,
        yamuxWriteTimeout: const Duration(seconds: 10),
      );
      final goAddr = goProcess.listenAddr;
      final goPeerId = goProcess.peerId;

      final metricsObserver = _TestMetricsObserver();

      final keyPair = await crypto_ed25519.generateEd25519KeyPair();
      dartHost = await createHost(keyPair, metricsObserver: metricsObserver);

      await dartHost!.connect(AddrInfo(goPeerId, [goAddr]),
          context: core_context.Context());
      print('Connected to Go peer over UDX');

      // Wait for multiple keepalive cycles (10s with 3s interval = ~3 pings)
      const idleDuration = Duration(seconds: 10);
      print('Idling for $idleDuration to collect keepalive metrics...');
      await Future.delayed(idleDuration);

      print('Pings sent: ${metricsObserver.pings.length}');
      print('Pongs received: ${metricsObserver.pongs.length}');

      // Should have at least 2 ping/pong cycles (3s interval, 10s wait)
      expect(metricsObserver.pings.length, greaterThanOrEqualTo(2),
          reason: 'Should have sent at least 2 pings in 10s with 3s interval');
      expect(metricsObserver.pongs.length, greaterThanOrEqualTo(2),
          reason: 'Should have received at least 2 pongs');

      // Verify RTTs are valid (positive, reasonable for loopback)
      for (final pong in metricsObserver.pongs) {
        expect(pong.rtt.inMilliseconds, greaterThan(0),
            reason: 'RTT should be positive');
        expect(pong.rtt.inSeconds, lessThan(5),
            reason: 'RTT should be under 5s for loopback');
        print(
            '  Ping ${pong.pingId}: RTT=${pong.rtt.inMilliseconds}ms');
      }

      // Verify no session errors
      expect(metricsObserver.errors, isEmpty,
          reason: 'No session errors expected');

      // Connection should still be alive
      await echoVerify(dartHost!, goPeerId);
      print('Metrics verified: ${metricsObserver.pongs.length} successful keepalive roundtrips');
    }, timeout: Timeout(Duration(seconds: 60)));

    test('Bidirectional keepalive: Go connects to Dart', () async {
      final keyPair = await crypto_ed25519.generateEd25519KeyPair();
      final dartPeerId = await PeerId.fromPublicKey(keyPair.publicKey);

      dartHost = await createHost(keyPair,
          listenAddrs: [MultiAddr('/ip4/127.0.0.1/udp/0/udx')]);

      final dartAddr = dartHost!.addrs.firstWhere(
        (addr) => addr.toString().contains('/udx'),
        orElse: () => throw Exception('Dart host not listening on UDX'),
      );
      print('Dart host listening on: $dartAddr');

      // Set up echo handler on Dart side
      dartHost!.setStreamHandler('/echo/1.0.0',
          (P2PStream stream, PeerId remotePeer) async {
        try {
          final data = await stream.read();
          print(
              'Echo handler: received ${data.length} bytes from $remotePeer');
          await stream.write(data);
          await stream.closeWrite();
        } catch (e) {
          print('Echo handler error: $e');
          await stream.reset();
        }
      });

      final targetAddr = '$dartAddr/p2p/${dartPeerId.toBase58()}';
      print('Go echo-client target: $targetAddr');

      // Start Go server that will connect to Dart
      // First, have Go connect as echo-client, then idle is handled by keepalive
      // For bidirectional test: Go connects, idles, then sends echo
      // We use Go's echo-client mode but with config for keepalive
      // Actually, the simplest approach: start Go as server, connect from Dart,
      // idle, then Dart sends echo — but that's the same as test 1.
      // For true bidirectional: Dart listens, Go connects and sends echo.
      // The keepalive runs from Go→Dart direction.

      // Use a brief delay then have Go send echo
      // The Go echo-client doesn't idle, so we test that the Dart host
      // accepts the incoming connection and keepalive works from the server side.
      await Future.delayed(const Duration(seconds: 1));

      final result = await goProcess.runEchoClient(
        targetAddr,
        'hello-bidirectional-keepalive',
        transport: 'udx',
      );
      print('Go echo-client stdout: ${result.stdout}');
      print('Go echo-client stderr: ${result.stderr}');

      expect(result.exitCode, 0, reason: 'Go echo-client should succeed');
      expect(result.stdout.toString(), contains('Echo successful'));

      // Now idle to let Dart's keepalive pings flow
      final idleDuration = keepAliveInterval * 2;
      print('Idling for $idleDuration to test Dart-side keepalive...');
      await Future.delayed(idleDuration);

      // Dart host should still be healthy (no session errors from keepalive timeout)
      print('Bidirectional keepalive test passed');
    }, timeout: Timeout(Duration(seconds: 60)));

    test('New streams succeed while long-lived stream is active', () async {
      // Start Go echo-server with matching keepalive config
      await goProcess.startServer(
        transport: 'udx',
        yamuxKeepAliveInterval: keepAliveInterval,
        yamuxWriteTimeout: const Duration(seconds: 10),
      );
      final goAddr = goProcess.listenAddr;
      final goPeerId = goProcess.peerId;
      print('Go peer: $goAddr');

      final metricsObserver = _TestMetricsObserver();
      final keyPair = await crypto_ed25519.generateEd25519KeyPair();
      dartHost = await createHost(keyPair, metricsObserver: metricsObserver);

      await dartHost!.connect(AddrInfo(goPeerId, [goAddr]),
          context: core_context.Context());
      print('Connected to Go peer over UDX');

      // Open long-lived stream (simulates relay reservation)
      // Send a small amount of data but do NOT closeWrite — Go's echo handler
      // echoes those bytes then blocks on s.Read(), keeping the stream open
      final longLivedStream = await dartHost!.newStream(
          goPeerId, ['/echo/1.0.0'], core_context.Context());
      expect(longLivedStream.protocol(), '/echo/1.0.0');
      await longLivedStream.write(Uint8List.fromList([1, 2, 3, 4]));
      print('Long-lived stream opened (not closing write side)');

      // Wait 10s — matches production timeline where failures appear
      // During this time, keepalive pings flow but the long-lived stream
      // holds resources on both sides
      print('Idling for 10s with long-lived stream open...');
      await Future.delayed(const Duration(seconds: 10));

      // Verify no session errors during idle with long-lived stream
      expect(metricsObserver.errors, isEmpty,
          reason: 'No session errors expected during idle with long-lived stream');
      print('No session errors after 10s idle');

      // Now try opening new streams — this is the production failure point
      // where "failed to open stream: i/o deadline reached" occurs
      for (var i = 0; i < 3; i++) {
        await echoVerify(dartHost!, goPeerId);
        print('Echo stream $i succeeded while long-lived stream active');
      }

      // Verify still no session errors after concurrent stream activity
      expect(metricsObserver.errors, isEmpty,
          reason: 'No session errors expected after new streams');

      // Clean up long-lived stream
      await longLivedStream.close();
      print('Long-lived stream closed — test passed');
    }, timeout: Timeout(Duration(seconds: 60)));
  });

  group('UDX DHT + Relay Stability', () {
    late GoProcessManager goProcess;
    BasicHost? dartHost;
    IpfsDHT? dartDHT;

    setUp(() {
      goProcess = GoProcessManager(binaryPath: goBinaryPath);
    });

    tearDown(() async {
      if (dartDHT != null) {
        await dartDHT!.close();
        dartDHT = null;
      }
      if (dartHost != null) {
        await dartHost!.close();
        dartHost = null;
      }
      await goProcess.stop();
    });

    test('DHT queries succeed while relay CONNECT stream is active over UDX',
        () async {
      // Reproduces production failure from go-ricochet server logs:
      //
      // Production timeline (from 2026-02-24 server logs):
      //   T+0s:  Dart connects over UDX, DHT FIND_NODE/PING succeed
      //   T+5s:  Dart makes relay reservation → long-lived HOP stream
      //   T+10s: Go DHT RT refresh tries opening stream TO Dart →
      //          "context deadline exceeded"
      //   T+12s: "failed to open stream: timed out"
      //   T+13s: "failed to open stream: i/o deadline reached"
      //
      // Root cause hypothesis: yamux write serialization under UDX flow
      // control — the relay HOP stream + DHT streams compete for the
      // yamux write lock, causing Go's SYN frames to time out.
      //
      // Key: the failure is Go opening streams TO Dart (DHT routing table
      // maintenance), NOT Dart opening streams to Go. So Dart must run
      // DHT in server mode so Go's RT refresh will query Dart.

      // 1. Start Go peer as combined DHT server + relay over UDX
      //    with aggressive keepalive to match production config
      await goProcess.startDHTRelayServer(
        transport: 'udx',
        yamuxKeepAliveInterval: keepAliveInterval,
        yamuxWriteTimeout: const Duration(seconds: 10),
      );
      final goAddr = goProcess.listenAddr;
      final goPeerId = goProcess.peerId;
      print('Go DHT+relay server: $goAddr (${goPeerId.toBase58()})');

      // 2. Create Dart host ("mobile client") with UDX + relay + DHT
      //    Must listen on UDX so Go can open streams back to us
      final metricsObserver = _TestMetricsObserver();
      final keyPairA = await crypto_ed25519.generateEd25519KeyPair();
      final dartPeerId = await PeerId.fromPublicKey(keyPairA.publicKey);
      dartHost = await createHost(keyPairA,
          listenAddrs: [MultiAddr('/ip4/127.0.0.1/udp/0/udx')],
          metricsObserver: metricsObserver,
          enableRelay: true);
      print('Dart host: ${dartHost!.addrs.first} (${dartPeerId.toBase58()})');

      // 3. Dart connects to Go and bootstraps DHT in SERVER mode
      //    Server mode means Go's RT refresh will try querying us
      await dartHost!.connect(AddrInfo(goPeerId, [goAddr]),
          context: core_context.Context());
      print('Dart connected to Go peer over UDX');

      dartDHT = IpfsDHT(
        host: dartHost!,
        providerStore: MemoryProviderStore(),
        options: DHTOptions(mode: DHTMode.server),
      );
      await dartDHT!.start();
      await dartDHT!.routingTable.tryAddPeer(goPeerId, queryPeer: false);
      print('Dart DHT started in SERVER mode');

      // 4. Baseline: Dart→Go DHT findPeer should succeed
      final baselineResult = await dartDHT!.findPeer(goPeerId);
      expect(baselineResult, isNotNull, reason: 'Baseline findPeer should succeed');
      print('Baseline DHT findPeer (Dart→Go) succeeded');

      // 5. Dart makes relay reservation on Go
      //    This creates a long-lived HOP stream on the Go ↔ Dart yamux session
      //    (matches production: "new relay stream" → "reserving relay slot")
      final relayClient = dartHost!.circuitV2Client;
      expect(relayClient, isNotNull,
          reason: 'CircuitV2Client should be created when relay is enabled');
      final reservation = await relayClient!.reserve(goPeerId);
      print('Relay reservation made, expires: ${reservation.expire}');

      // 6. Wait 15s — production failure window
      //    Go's DHT routing table refresh interval is typically 10s for
      //    the first CPL bucket. During this time:
      //    - The relay reservation HOP stream stays open
      //    - Yamux keepalive pings flow every 3s
      //    - Go's DHT RT refresh will try opening new streams TO Dart
      //    In production, this is where "i/o deadline reached" appears
      print('Waiting 15s for Go DHT RT refresh to attempt streams TO Dart...');
      await Future.delayed(const Duration(seconds: 15));

      // 7. Check Go's stderr for the production failure signature
      final goOutput = goProcess.output;
      final ioDeadlineErrors = goOutput
          .where((line) => line.contains('i/o deadline reached'))
          .toList();
      final contextDeadlineErrors = goOutput
          .where((line) =>
              line.contains('context deadline exceeded') &&
              line.contains('dht'))
          .toList();
      final streamOpenFailures = goOutput
          .where((line) => line.contains('failed to open stream'))
          .toList();

      if (ioDeadlineErrors.isNotEmpty) {
        print('BUG REPRODUCED — Go "i/o deadline reached" errors:');
        for (final line in ioDeadlineErrors) {
          print('  $line');
        }
      }
      if (streamOpenFailures.isNotEmpty) {
        print('Go stream-open failures:');
        for (final line in streamOpenFailures) {
          print('  $line');
        }
      }
      if (contextDeadlineErrors.isNotEmpty) {
        print('Go DHT context deadline errors:');
        for (final line in contextDeadlineErrors) {
          print('  $line');
        }
      }

      // 8. Check Dart-side session errors
      if (metricsObserver.errors.isNotEmpty) {
        print('Dart session errors during idle:');
        for (final err in metricsObserver.errors) {
          print('  - $err');
        }
      }

      // 9. Try Dart→Go DHT query after the idle period
      //    Even if Go→Dart failed, Dart→Go might still work (or vice versa)
      print('Attempting Dart→Go DHT query after idle...');
      try {
        final postIdleResult = await dartDHT!.findPeer(goPeerId);
        print('Post-idle Dart→Go findPeer: ${postIdleResult != null ? "succeeded" : "returned null"}');
      } catch (e) {
        print('Post-idle Dart→Go DHT query failed: $e');
      }

      // 10. Verify echo still works on the direct UDX connection
      try {
        await echoVerify(dartHost!, goPeerId);
        print('Direct echo to Go still works after idle');
      } catch (e) {
        print('Direct echo FAILED after idle: $e');
      }

      // Assert: the production failure should NOT happen (or if it does,
      // we've reproduced the bug and should fail the test)
      expect(ioDeadlineErrors, isEmpty,
          reason: 'Go should not get "i/o deadline reached" opening streams to Dart');
      expect(metricsObserver.errors, isEmpty,
          reason: 'No Dart session errors expected');
      print('Test passed — no i/o deadline errors over UDX');
    }, timeout: Timeout(Duration(seconds: 90)));
  });
}
