import 'dart:async';
import 'dart:typed_data';

import 'package:dart_libp2p/config/config.dart' as p2p_config;
import 'package:dart_libp2p/core/crypto/ed25519.dart' as ed25519;
import 'package:dart_libp2p/core/host/host.dart';
import 'package:dart_libp2p/core/multiaddr.dart';
import 'package:dart_libp2p/core/network/common.dart';
import 'package:dart_libp2p/core/network/context.dart';
import 'package:dart_libp2p/core/network/errors.dart' as network_errors;
import 'package:dart_libp2p/core/network/rcmgr.dart';
import 'package:dart_libp2p/core/peer/addr_info.dart';
import 'package:dart_libp2p/core/peer/peer_id.dart';
import 'package:dart_libp2p/p2p/host/resource_manager/limit.dart';
import 'package:dart_libp2p/p2p/host/resource_manager/limiter.dart';
import 'package:dart_libp2p/p2p/host/resource_manager/resource_manager_impl.dart';
import 'package:dart_libp2p/p2p/security/noise/noise_protocol.dart';
import 'package:dart_libp2p/p2p/transport/connection_manager.dart'
    as p2p_conn_manager;
import 'package:dart_libp2p/p2p/transport/tcp_transport.dart';
import 'package:test/test.dart';

const _mib = 1024 * 1024;
const _gib = 1024 * _mib;

Future<PeerId> _peer() async =>
    PeerId.fromPublicKey((await ed25519.generateEd25519KeyPair()).publicKey);

final _addr = MultiAddr('/ip4/127.0.0.1/tcp/4001');

int _streams(ScopeStat s) => s.numStreamsInbound + s.numStreamsOutbound;
int _conns(ScopeStat s) => s.numConnsInbound + s.numConnsOutbound;

void main() {
  group('LimiterConfig', () {
    test('defaults are go-libp2p DefaultLimits scaled to 1 GiB and 512 FDs',
        () {
      final c = LimiterConfig.defaults();

      expect(c.system.conns, 256);
      expect(c.system.connsInbound, 128);
      expect(c.system.connsOutbound, 256);
      expect(c.system.streams, 4096);
      expect(c.system.streamsInbound, 2048);
      expect(c.system.memory, 128 * _mib + _gib);
      expect(c.system.fd, 512);

      expect(c.transient.conns, 96);
      expect(c.transient.streams, 512);
      expect(c.transient.fd, 128);

      expect(c.peer.conns, 8);
      expect(c.peer.streams, 768);
      expect(c.peer.streamsInbound, 384);
      expect(c.peer.fd, 8);

      expect(c.protocol.streams, 2560);
      expect(c.protocolPeer.streams, 272);
      expect(c.protocolPeer.streamsInbound, 68);
      expect(c.service.streams, 6144);
      expect(c.servicePeer.streams, 264);

      expect(c.conn.conns, 1);
      expect(c.conn.fd, 1);
      expect(c.stream.streams, 1);
      expect(c.stream.memory, 16 * _mib);
    });

    test('scaled() gives the base limits at 128 MiB and grows per GiB', () {
      final small = LimiterConfig.scaled(memory: 128 * _mib, fds: 0);
      expect(small.system.conns, 128);
      expect(small.system.streams, 2048);
      expect(small.system.fd, 256);
      expect(small.peer.fd, 4);

      final big = LimiterConfig.scaled(memory: 4 * _gib, fds: 4096);
      expect(big.system.conns, 128 + 4 * 128);
      expect(big.system.fd, 4096);
      expect(big.transient.fd, 1024);
      expect(big.peer.fd, 64);
      expect(big.peer.conns, 8); // No increase per GiB.
      expect(
          () => LimiterConfig.scaled(memory: -1, fds: 1), throwsArgumentError);
    });

    test('unset scopes and zero fields take the base values', () async {
      final p = await _peer();
      final c = LimiterConfig(
        peer: BaseLimit(conns: 2),
        peerOverrides: {p: BaseLimit(streams: 3)},
        protocolOverrides: {'/x/1.0.0': BaseLimit(streamsInbound: 5)},
      );
      final d = LimiterConfig.defaults();

      expect(c.system.conns, d.system.conns);
      expect(c.peer.conns, 2);
      expect(c.peer.connsInbound, d.peer.connsInbound);
      expect(c.peer.streams, d.peer.streams);

      final limiter = ConfigurableLimiter(c);
      expect(limiter.getPeerLimits(p).streamTotalLimit, 3);
      expect(limiter.getPeerLimits(p).connTotalLimit, 2); // From `peer`.
      expect(limiter.getPeerLimits(await _peer()).streamTotalLimit,
          d.peer.streams);
      expect(
          limiter
              .getProtocolLimits('/x/1.0.0')
              .getStreamLimit(Direction.inbound),
          5);
      expect(limiter.getProtocolLimits('/x/1.0.0').streamTotalLimit,
          d.protocol.streams);
      expect(
          limiter
              .getProtocolLimits('/y/1.0.0')
              .getStreamLimit(Direction.inbound),
          d.protocol.streamsInbound);
    });

    test('ConfigurableLimiter() uses the defaults', () {
      final l = ConfigurableLimiter();
      expect(l.getSystemLimits().connTotalLimit, 256);
      expect(l.getConnLimits().fdLimit, 1);
    });
  });

  group('ResourceManagerImpl with a ConfigurableLimiter', () {
    late ResourceManagerImpl rm;
    tearDown(() async => rm.close());

    test('enforces the system connection limit and frees it on done()',
        () async {
      rm = ResourceManagerImpl(
          limiter:
              ConfigurableLimiter(LimiterConfig(system: BaseLimit(conns: 3))));
      final scopes = [
        for (var i = 0; i < 3; i++)
          await rm.openConnection(Direction.inbound, true, _addr)
      ];
      await expectLater(rm.openConnection(Direction.inbound, true, _addr),
          throwsA(isA<network_errors.ResourceLimitExceededException>()));

      scopes.first.done();
      final again = await rm.openConnection(Direction.outbound, true, _addr);
      again.done();
      for (final s in scopes.skip(1)) {
        s.done();
      }
      expect(_conns(rm.systemScope.stat), 0);
      expect(rm.systemScope.stat.numFD, 0);
    });

    test('enforces the per-peer connection limit on setPeer()', () async {
      rm = ResourceManagerImpl(
          limiter:
              ConfigurableLimiter(LimiterConfig(peer: BaseLimit(conns: 2))));
      final p = await _peer();
      final open = <ConnManagementScope>[];
      for (var i = 0; i < 2; i++) {
        final s = await rm.openConnection(Direction.inbound, true, _addr);
        await s.setPeer(p);
        open.add(s);
      }
      final third = await rm.openConnection(Direction.inbound, true, _addr);
      await expectLater(third.setPeer(p),
          throwsA(isA<network_errors.ResourceLimitExceededException>()));
      third.done();

      // Another peer is not affected.
      final other = await rm.openConnection(Direction.inbound, true, _addr);
      await other.setPeer(await _peer());
      other.done();

      for (final s in open) {
        s.done();
      }
      expect(_conns(rm.systemScope.stat), 0);
      await rm.viewPeer(p, (scope) async => expect(_conns(scope.stat), 0));
    });

    test('enforces the per-peer stream limit', () async {
      rm = ResourceManagerImpl(
          limiter: ConfigurableLimiter(
              LimiterConfig(peer: BaseLimit(streamsInbound: 4))));
      final p = await _peer();
      final open = [
        for (var i = 0; i < 4; i++) await rm.openStream(p, Direction.inbound)
      ];
      await expectLater(rm.openStream(p, Direction.inbound),
          throwsA(isA<network_errors.ResourceLimitExceededException>()));
      // Outbound streams have their own limit.
      (await rm.openStream(p, Direction.outbound)).done();
      for (final s in open) {
        s.done();
      }
      expect(_streams(rm.systemScope.stat), 0);
    });

    test('enforces the protocol limits on setProtocol()', () async {
      rm = ResourceManagerImpl(
          limiter: ConfigurableLimiter(LimiterConfig(
        protocolOverrides: {'/limited/1.0.0': BaseLimit(streams: 2)},
      )));
      final a = await _peer();
      final b = await _peer();
      final open = <StreamManagementScope>[];
      for (final p in [a, b]) {
        final s = await rm.openStream(p, Direction.inbound);
        await s.setProtocol('/limited/1.0.0');
        open.add(s);
      }
      final third = await rm.openStream(a, Direction.inbound);
      await expectLater(third.setProtocol('/limited/1.0.0'),
          throwsA(isA<network_errors.ResourceLimitExceededException>()));
      // Another protocol has the default limits.
      await third.setProtocol('/other/1.0.0');
      third.done();

      for (final s in open) {
        s.done();
      }
      await rm.viewProtocol(
          '/limited/1.0.0', (scope) async => expect(_streams(scope.stat), 0));
      expect(_streams(rm.systemScope.stat), 0);
    });

    test('enforces the system stream limit across peers', () async {
      rm = ResourceManagerImpl(
          limiter: ConfigurableLimiter(
              LimiterConfig(system: BaseLimit(streams: 3))));
      final open = [
        for (var i = 0; i < 3; i++)
          await rm.openStream(await _peer(), Direction.outbound)
      ];
      await expectLater(rm.openStream(await _peer(), Direction.outbound),
          throwsA(isA<network_errors.ResourceLimitExceededException>()));
      for (final s in open) {
        s.done();
      }
      expect(_streams(rm.systemScope.stat), 0);
    });

    test('a negative value blocks the resource', () async {
      rm = ResourceManagerImpl(
          limiter: ConfigurableLimiter(
              LimiterConfig(transient: BaseLimit(connsInbound: -1))));
      await expectLater(rm.openConnection(Direction.inbound, true, _addr),
          throwsA(isA<network_errors.ResourceLimitExceededException>()));
      (await rm.openConnection(Direction.outbound, true, _addr)).done();
    });

    test(
        'many streams and connections opened and closed leave every counter at zero',
        () async {
      rm = ResourceManagerImpl(limiter: ConfigurableLimiter());
      final peers = [for (var i = 0; i < 5; i++) await _peer()];
      // More than any default limit, so a leak of one per open would fail.
      for (var i = 0; i < 5000; i++) {
        final p = peers[i % peers.length];
        final conn = await rm.openConnection(
            i.isEven ? Direction.inbound : Direction.outbound, true, _addr);
        await conn.setPeer(p);
        final s = await rm.openStream(
            p, i.isEven ? Direction.outbound : Direction.inbound);
        await s.setProtocol('/p/${i % 3}');
        await s.setService('svc');
        await s.reserveMemory(1024, ReservationPriority.always);
        s.done();
        conn.done();
      }
      final st = rm.systemScope.stat;
      expect(_streams(st), 0);
      expect(_conns(st), 0);
      expect(st.numFD, 0);
      expect(st.memory, 0);
      for (final p in peers) {
        await rm.viewPeer(p, (scope) async {
          expect(_streams(scope.stat), 0);
          expect(_conns(scope.stat), 0);
        });
      }
    });

    test('gc() drops peer scopes that nothing uses', () async {
      rm = ResourceManagerImpl(limiter: ConfigurableLimiter());
      final p = await _peer();
      final s = await rm.openStream(p, Direction.inbound);
      await s.setProtocol('/p/1.0.0');
      rm.gc();
      expect(rm.peerScopeCount, 1,
          reason: 'the stream still uses the peer scope');
      s.done();
      rm.gc();
      expect(rm.peerScopeCount, 0);
      // A new stream to the same peer gets a new scope.
      (await rm.openStream(p, Direction.inbound)).done();
      expect(_streams(rm.systemScope.stat), 0);
    });
  });

  group('Config', () {
    test('resourceLimiter and resourceManager options set the config',
        () async {
      final config = p2p_config.Config();
      final limiter = ConfigurableLimiter();
      await config.apply([p2p_config.Libp2p.resourceLimiter(limiter)]);
      expect(config.resourceLimiter, same(limiter));

      final rm = NullResourceManager();
      await config.apply([p2p_config.Libp2p.resourceManager(rm)]);
      expect(config.resourceManager, same(rm));
    });

    test(
        'a host uses the default ConfigurableLimiter, or the given limiter or manager',
        () async {
      final byDefault = await _host();
      final rm = byDefault.network.resourceManager;
      expect(rm, isA<ResourceManagerImpl>());
      expect((rm as ResourceManagerImpl).limiter, isA<ConfigurableLimiter>());
      await byDefault.close();

      final fixed = FixedLimiter();
      final withLimiter =
          await _host([p2p_config.Libp2p.resourceLimiter(fixed)]);
      expect(
          (withLimiter.network.resourceManager as ResourceManagerImpl).limiter,
          same(fixed));
      await withLimiter.close();

      final nullRm = NullResourceManager();
      final withRm = await _host([p2p_config.Libp2p.resourceManager(nullRm)]);
      expect(withRm.network.resourceManager, same(nullRm));
      await withRm.close();
    });

    test('a host refuses both a limiter and a resource manager', () async {
      await expectLater(
          _host([
            p2p_config.Libp2p.resourceLimiter(FixedLimiter()),
            p2p_config.Libp2p.resourceManager(NullResourceManager()),
          ]),
          throwsA(anything));
    });
  });

  group('Host streams and connections release their scopes', () {
    late Host server;
    late Host client;
    const echo = '/rcmgr-test/echo/1.0.0';
    const hold = '/rcmgr-test/hold/1.0.0';

    setUp(() async {
      server = await _host();
      client = await _host();
      server.setStreamHandler(echo, (stream, _) async {
        final data = await stream.read();
        await stream.write(data);
        await stream.close();
      });
      // Keeps the stream open until the remote resets it.
      server.setStreamHandler(hold, (stream, _) async {
        try {
          while (true) {
            final data = await stream.read();
            if (data.isEmpty) break;
          }
        } catch (_) {}
      });
    });

    tearDown(() async {
      await client.close();
      await server.close();
    });

    ScopeStat serverStat() =>
        (server.network.resourceManager as ResourceManagerImpl)
            .systemScope
            .stat;
    ScopeStat clientStat() =>
        (client.network.resourceManager as ResourceManagerImpl)
            .systemScope
            .stat;

    Future<void> until(bool Function() ok, String what) async {
      final deadline = DateTime.now().add(const Duration(seconds: 10));
      while (!ok()) {
        if (DateTime.now().isAfter(deadline)) {
          String fmt(ScopeStat x) =>
              'streams in/out ${x.numStreamsInbound}/${x.numStreamsOutbound}, '
              'conns in/out ${x.numConnsInbound}/${x.numConnsOutbound}, fd ${x.numFD}, memory ${x.memory}';
          fail(
              'timed out waiting for $what; server: ${fmt(serverStat())}; client: ${fmt(clientStat())}');
        }
        await Future.delayed(const Duration(milliseconds: 50));
      }
    }

    Future<void> connect() =>
        client.connect(AddrInfo(server.id, server.network.listenAddresses));

    test('after many streams, resets and reconnects', () async {
      await connect();
      // Let identify and the other start-up streams finish.
      await Future.delayed(const Duration(seconds: 1));
      // Long-lived streams of the host's own services (one each way).
      final serverBase = _streams(serverStat());
      final clientBase = _streams(clientStat());

      // More streams than the per-peer-protocol inbound limit (68), so a
      // leak would make the last ones fail.
      for (var i = 0; i < 150; i++) {
        final s = await client.newStream(server.id, [echo], Context());
        await s.write(Uint8List.fromList([i % 256]));
        expect(await s.read(), [i % 256]);
        await s.close();
      }
      // Streams that the client resets while the server handler holds them.
      for (var i = 0; i < 80; i++) {
        final s = await client.newStream(server.id, [hold], Context());
        await s.write(Uint8List.fromList([1]));
        await s.reset();
      }

      await until(() => _streams(serverStat()) <= serverBase,
          'server streams to return to $serverBase');
      await until(() => _streams(clientStat()) <= clientBase,
          'client streams to return to $clientBase');

      // More reconnects than the per-peer connection limit (8).
      for (var i = 0; i < 12; i++) {
        await client.network.closePeer(server.id);
        await until(() => _conns(serverStat()) == 0, 'server conns to reach 0');
        await connect();
        final s = await client.newStream(server.id, [echo], Context());
        await s.write(Uint8List.fromList([7]));
        expect(await s.read(), [7]);
        await s.close();
      }

      await client.network.closePeer(server.id);
      await until(() => _conns(serverStat()) == 0 && _conns(clientStat()) == 0,
          'conns to reach 0');
      await until(
          () => _streams(serverStat()) == 0 && _streams(clientStat()) == 0,
          'streams to reach 0');
      expect(serverStat().numFD, 0);
      expect(clientStat().numFD, 0);
    }, timeout: const Timeout(Duration(seconds: 120)));
  });
}

Future<Host> _host([List<p2p_config.Option> extra = const []]) async {
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
    ...extra,
  ]);
  await host.start();
  return host;
}
