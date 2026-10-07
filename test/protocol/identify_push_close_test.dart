import 'dart:async';

import 'package:dart_libp2p/config/config.dart' as p2p_config;
import 'package:dart_libp2p/core/crypto/ed25519.dart' as ed25519;
import 'package:dart_libp2p/core/host/host.dart';
import 'package:dart_libp2p/core/multiaddr.dart';
import 'package:dart_libp2p/core/network/rcmgr.dart';
import 'package:dart_libp2p/core/peer/addr_info.dart';
import 'package:dart_libp2p/core/event/protocol.dart';
import 'package:dart_libp2p/core/network/context.dart';
import 'package:dart_libp2p/p2p/protocol/identify/identify.dart' as identify;
import 'package:dart_libp2p/p2p/security/noise/noise_protocol.dart';
import 'package:dart_libp2p/p2p/transport/connection_manager.dart'
    as p2p_conn_manager;
import 'package:dart_libp2p/p2p/transport/tcp_transport.dart';
import 'package:dart_libp2p/p2p/host/eventbus/basic.dart' as p2p_event_bus;
import 'package:dart_udx/dart_udx.dart';
import 'package:logging/logging.dart';
import 'package:test/test.dart';

import '../real_net_stack.dart';

/// Removing a stream handler makes Identify push the new protocol list to
/// every connected peer. When the peers close at the same moment, the pushes
/// fail. These failures must be handled inside Identify: no error may reach
/// the zone as an unhandled async error.
void main() {
  group('Identify push to closing connections', () {
    // A peer that closes a push stream before it writes the message must not
    // clear the protocols that identify learned for it.
    test('a push stream that ends before its message changes nothing', () async {
      final a = await _tcpHost();
      final b = await _tcpHost();
      try {
        await b.connect(AddrInfo(a.id, a.network.listenAddresses));
        final deadline = DateTime.now().add(const Duration(seconds: 10));
        while ((await a.peerStore.protoBook.getProtocols(b.id)).isEmpty) {
          if (DateTime.now().isAfter(deadline)) fail('identify did not finish');
          await Future.delayed(const Duration(milliseconds: 50));
        }
        final before = await a.peerStore.protoBook.getProtocols(b.id);

        final updates = <EvtPeerProtocolsUpdated>[];
        final sub = await a.eventBus.subscribe(EvtPeerProtocolsUpdated);
        final listener = sub.stream.listen((e) {
          if (e is EvtPeerProtocolsUpdated) updates.add(e);
        });

        final s = await b.newStream(a.id, [identify.idPush], Context());
        await s.close();
        await Future.delayed(const Duration(milliseconds: 500));

        await listener.cancel();
        await sub.close();
        expect(await a.peerStore.protoBook.getProtocols(b.id),
            unorderedEquals(before));
        expect(updates, isEmpty);
      } finally {
        await b.close();
        await a.close();
      }
    }, timeout: const Timeout(Duration(seconds: 30)));

    for (final transport in ['tcp', 'udx']) {
      final make = transport == 'tcp' ? _tcpHost : _udxHost;

      test('$transport: a handler removed while the peers close raises no unhandled error',
          () async {
        await _expectNoUnhandledErrors(() async {
          for (var round = 0; round < 4; round++) {
            final local = await make();
            const proto = '/identify-push-close-test/1.0.0';
            local.setStreamHandler(proto, (stream, _) async {
              await stream.close();
            });
            final remotes = <Host>[];
            for (var i = 0; i < 5; i++) {
              final remote = await make();
              await remote.connect(
                  AddrInfo(local.id, local.network.listenAddresses));
              remotes.add(remote);
            }
            // Let the initial identify exchanges finish.
            await Future.delayed(const Duration(milliseconds: 500));

            // The remotes close while the local host pushes its new
            // protocol list. Vary the order between rounds.
            final closes = <Future<void>>[];
            if (round.isEven) {
              local.removeStreamHandler(proto);
              closes.addAll(remotes.map((r) => r.close()));
            } else {
              closes.addAll(remotes.map((r) => r.close()));
              await Future.delayed(Duration(milliseconds: round * 2));
              local.removeStreamHandler(proto);
            }
            await Future.wait(closes);
            // Give the pushes time to fail.
            await Future.delayed(const Duration(seconds: 1));
            await local.close();
          }
        });
      }, timeout: const Timeout(Duration(seconds: 120)));

      // The pattern of the dart_libp2p_kad_dht tests: every node removes its
      // handler (the DHT closes), then every host closes, one after another.
      test('$transport: all hosts remove a handler, then close', () async {
        await _expectNoUnhandledErrors(() async {
          const proto = '/identify-push-close-test/2.0.0';
          final hosts = <Host>[];
          for (var i = 0; i < 5; i++) {
            final h = await make();
            h.setStreamHandler(proto, (stream, _) async {
              await stream.close();
            });
            hosts.add(h);
          }
          for (var i = 1; i < hosts.length; i++) {
            for (var j = 0; j < i; j++) {
              await hosts[i].connect(
                  AddrInfo(hosts[j].id, hosts[j].network.listenAddresses));
            }
          }
          await Future.delayed(const Duration(milliseconds: 500));
          for (final h in hosts) {
            h.removeStreamHandler(proto);
          }
          for (final h in hosts) {
            await h.close();
          }
          await Future.delayed(const Duration(seconds: 1));
        });
      }, timeout: const Timeout(Duration(seconds: 120)));
    }
  });
}

/// Runs [body] in a guarded zone and fails if an error reaches the zone.
Future<void> _expectNoUnhandledErrors(Future<void> Function() body) async {
  final unhandled = <Object>[];
  final identifyFailures = <String>[];
  final done = Completer<void>();
  final oldLevel = Logger.root.level;
  Logger.root.level = Level.WARNING;
  final logSub = Logger.root.onRecord.listen((r) {
    // A push that fails because the connection closes is expected. It must
    // not be reported as a failed stream handler or an identify error.
    final m = r.message;
    if (m.contains('/ipfs/id/') ||
        m.contains('IdentifyService') ||
        r.loggerName.startsWith('identify')) {
      identifyFailures.add('${r.level.name} ${r.loggerName}: ${m.split('\n').first}');
    }
  });
  runZonedGuarded(() async {
    try {
      await body();
      // Let late failures surface.
      await Future.delayed(const Duration(milliseconds: 500));
      done.complete();
    } catch (e, st) {
      if (!done.isCompleted) done.completeError(e, st);
    }
  }, (error, stack) {
    unhandled.add(error);
    // ignore: avoid_print
    print('Unhandled async error: $error\n$stack');
  });
  try {
    await done.future;
  } finally {
    await logSub.cancel();
    Logger.root.level = oldLevel;
  }
  expect(unhandled, isEmpty);
  expect(identifyFailures, isEmpty);
}

Future<Host> _udxHost() async {
  final node = await createLibp2pNode(
    udxInstance: UDX(),
    resourceManager: NullResourceManager(),
    connManager: p2p_conn_manager.ConnectionManager(),
    hostEventBus: p2p_event_bus.BasicBus(),
    listenAddrsOverride: [MultiAddr('/ip4/127.0.0.1/udp/0/udx')],
  );
  return node.host;
}

Future<Host> _tcpHost() async {
  final keyPair = await ed25519.generateEd25519KeyPair();
  final connManager = p2p_conn_manager.ConnectionManager();
  final host = await p2p_config.Libp2p.new_([
    p2p_config.Libp2p.identity(keyPair),
    p2p_config.Libp2p.connManager(connManager),
    p2p_config.Libp2p.transport(TCPTransport(
        connManager: connManager, resourceManager: NullResourceManager())),
    p2p_config.Libp2p.security(await NoiseSecurity.create(keyPair)),
    p2p_config.Libp2p.listenAddrs([MultiAddr('/ip4/127.0.0.1/tcp/0')]),
    p2p_config.Libp2p.autoNAT(false),
    p2p_config.Libp2p.holePunching(false),
  ]);
  await host.start();
  return host;
}
