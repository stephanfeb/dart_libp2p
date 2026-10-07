import 'dart:async';
import 'dart:io';

import 'package:dart_libp2p/config/config.dart' as p2p_config;
import 'package:dart_libp2p/core/crypto/ed25519.dart' as ed25519;
import 'package:dart_libp2p/core/host/host.dart';
import 'package:dart_libp2p/core/multiaddr.dart';
import 'package:dart_libp2p/core/network/rcmgr.dart';
import 'package:dart_libp2p/core/peer/addr_info.dart';
import 'package:dart_libp2p/core/peer/peer_id.dart';
import 'package:dart_libp2p/core/protocol/protocol.dart';
import 'package:dart_libp2p/p2p/host/resource_manager/limit.dart';
import 'package:dart_libp2p/p2p/host/resource_manager/limiter.dart';
import 'package:dart_libp2p/p2p/host/resource_manager/resource_manager_impl.dart';
import 'package:dart_libp2p/p2p/security/noise/noise_protocol.dart';
import 'package:dart_libp2p/p2p/transport/connection_manager.dart'
    as p2p_conn_manager;
import 'package:dart_libp2p/p2p/transport/tcp_transport.dart';
import 'package:test/test.dart';

/// A TCPTransport that shares the host's resource manager opens the
/// connection's scope when the socket opens. The swarm must use that scope
/// (one per connection), not open a second one.
void main() {
  group('TCPTransport with the host resource manager', () {
    final hosts = <Host>[];

    tearDown(() async {
      for (final h in hosts) {
        await h.close().catchError((_) {});
      }
      hosts.clear();
    });

    Future<Host> host({Limiter? limiter}) async {
      final h = await _host(limiter: limiter);
      hosts.add(h);
      return h;
    }

    test('a transport made without a resource manager gets the host\'s',
        () async {
      final transport = TCPTransport();
      expect(transport.hasResourceManager, isFalse);
      expect(transport.resourceManager, isA<NullResourceManager>());
      final h = await _host(transport: transport);
      hosts.add(h);
      expect(transport.resourceManager, same(h.network.resourceManager));

      // A resource manager given to the constructor is kept.
      final own = NullResourceManager();
      final kept = TCPTransport(resourceManager: own);
      final h2 = await _host(transport: kept);
      hosts.add(h2);
      expect(kept.resourceManager, same(own));
    });

    test('more than 96 connections, one after another, count once each',
        () async {
      final server = await host();
      final client = await host();

      for (var i = 0; i < 110; i++) {
        await client
            .connect(AddrInfo(server.id, server.network.listenAddresses));
        await _until(() async {
          final s = _system(server);
          return s.numConnsInbound == 1 &&
              s.numFD == 1 &&
              (await _transient(server)).numConnsInbound == 0;
        }, () async => 'round $i: server ${_fmt(_system(server))}, '
            'transient ${_fmt(await _transient(server))}');
        // The client counts its outbound connection once too.
        expect(_system(client).numConnsOutbound, 1, reason: 'round $i');
        expect(_system(client).numFD, 1, reason: 'round $i');
        expect((await _transient(client)).numConnsOutbound, 0,
            reason: 'round $i');

        await client.network.closePeer(server.id);
        await _until(
            () async =>
                _conns(_system(server)) == 0 && _conns(_system(client)) == 0,
            () async => 'round $i close: server ${_fmt(_system(server))}, '
                'client ${_fmt(_system(client))}');
      }
      await _expectZero(server);
      await _expectZero(client);
    }, timeout: const Timeout(Duration(seconds: 180)));

    test('many concurrent connections count once each and return to zero',
        () async {
      final server = await host();
      const clients = 24;
      final cs = <Host>[];
      for (var i = 0; i < clients; i++) {
        cs.add(await host());
      }
      // 5 rounds of 24 concurrent connections: 120 in all, more than the
      // transient scope's 96 if a scope stayed in it.
      for (var round = 0; round < 5; round++) {
        await Future.wait(cs.map((c) =>
            c.connect(AddrInfo(server.id, server.network.listenAddresses))));
        await _until(() async {
          final s = _system(server);
          return s.numConnsInbound == clients &&
              s.numFD == clients &&
              (await _transient(server)).numConnsInbound == 0;
        }, () async => 'round $round: server ${_fmt(_system(server))}, '
            'transient ${_fmt(await _transient(server))}');
        for (final c in cs) {
          expect(_system(c).numConnsOutbound, 1);
        }

        await Future.wait(cs.map((c) => c.network.closePeer(server.id)));
        await _until(() async => _conns(_system(server)) == 0,
            () async => 'round $round close: server ${_fmt(_system(server))}');
      }
      await _expectZero(server);
      for (final c in cs) {
        await _expectZero(c);
      }
    }, timeout: const Timeout(Duration(seconds: 180)));

    test('a connection that the peer scope refuses releases its scope',
        () async {
      final refused = await host();
      final server =
          await host(limiter: _RefusePeerLimiter({refused.id.toString()}));
      final accepted = await host();

      try {
        await refused
            .connect(AddrInfo(server.id, server.network.listenAddresses));
      } catch (_) {
        // The server closes the connection; the dial may or may not see it.
      }
      await _until(() async => _conns(_system(server)) == 0,
          () async => 'server ${_fmt(_system(server))}');
      await _until(() async => _conns(await _transient(server)) == 0,
          () async => 'transient ${_fmt(await _transient(server))}');
      expect(_system(server).numFD, 0);
      // The server closed the connection: the refused peer sees it close.
      await _expectZero(refused);

      // Other peers still connect.
      await accepted
          .connect(AddrInfo(server.id, server.network.listenAddresses));
      await _until(() async => _system(server).numConnsInbound == 1,
          () async => 'server ${_fmt(_system(server))}');
      await accepted.network.closePeer(server.id);
      await _until(() async => _conns(_system(server)) == 0,
          () async => 'server ${_fmt(_system(server))}');
      await _expectZero(server);
    }, timeout: const Timeout(Duration(seconds: 60)));

    test('a failed upgrade releases the transport\'s scope', () async {
      final server = await host();
      // A raw TCP client that sends garbage: the security negotiation fails.
      final addr = server.network.listenAddresses.first;
      for (var i = 0; i < 60; i++) {
        final socket = await _rawConnect(addr);
        socket.add([0xff, 0xff, 0xff, 0xff]);
        await socket.flush();
        await socket.close();
      }
      await _until(
          () async =>
              _conns(_system(server)) == 0 &&
              _conns(await _transient(server)) == 0,
          () async => 'server ${_fmt(_system(server))}, '
              'transient ${_fmt(await _transient(server))}');
      await _expectZero(server);
    }, timeout: const Timeout(Duration(seconds: 60)));
  });
}

int _conns(ScopeStat s) => s.numConnsInbound + s.numConnsOutbound;

String _fmt(ScopeStat s) =>
    'conns in/out ${s.numConnsInbound}/${s.numConnsOutbound}, fd ${s.numFD}';

ScopeStat _system(Host h) =>
    (h.network.resourceManager as ResourceManagerImpl).systemScope.stat;

Future<ScopeStat> _transient(Host h) =>
    h.network.resourceManager.viewTransient((s) async => s.stat);

Future<void> _expectZero(Host h) async {
  await _until(() async {
    final s = _system(h);
    final t = await _transient(h);
    return _conns(s) == 0 && s.numFD == 0 && _conns(t) == 0 && t.numFD == 0;
  }, () async => 'system ${_fmt(_system(h))}, transient ${_fmt(await _transient(h))}');
}

Future<void> _until(
    Future<bool> Function() ok, Future<String> Function() what) async {
  final deadline = DateTime.now().add(const Duration(seconds: 10));
  while (!await ok()) {
    if (DateTime.now().isAfter(deadline)) {
      fail('timed out: ${await what()}');
    }
    await Future.delayed(const Duration(milliseconds: 20));
  }
}

Future<Socket> _rawConnect(MultiAddr addr) {
  final ip = addr.valueForProtocol('ip4')!;
  final port = int.parse(addr.valueForProtocol('tcp')!);
  return Socket.connect(ip, port);
}

Future<Host> _host({TCPTransport? transport, Limiter? limiter}) async {
  final keyPair = await ed25519.generateEd25519KeyPair();
  final connManager = p2p_conn_manager.ConnectionManager();
  final host = await p2p_config.Libp2p.new_([
    p2p_config.Libp2p.identity(keyPair),
    p2p_config.Libp2p.connManager(connManager),
    // No resource manager: the transport uses the host's.
    p2p_config.Libp2p.transport(
        transport ?? TCPTransport(connManager: connManager)),
    p2p_config.Libp2p.security(await NoiseSecurity.create(keyPair)),
    p2p_config.Libp2p.listenAddrs([MultiAddr('/ip4/127.0.0.1/tcp/0')]),
    p2p_config.Libp2p.autoNAT(false),
    p2p_config.Libp2p.holePunching(false),
    if (limiter != null) p2p_config.Libp2p.resourceLimiter(limiter),
  ]);
  await host.start();
  return host;
}

/// The default limits, but no connection at all for the given peers.
class _RefusePeerLimiter implements Limiter {
  final Set<String> refused;
  final ConfigurableLimiter _base = ConfigurableLimiter(LimiterConfig.defaults());

  _RefusePeerLimiter(this.refused);

  @override
  Limit getPeerLimits(PeerId peer) => refused.contains(peer.toString())
      ? BaseLimit(memory: 1 << 30, streams: 100, streamsInbound: 100, streamsOutbound: 100)
      : _base.getPeerLimits(peer);

  @override
  Limit getSystemLimits() => _base.getSystemLimits();
  @override
  Limit getTransientLimits() => _base.getTransientLimits();
  @override
  Limit getAllowlistedSystemLimits() => _base.getAllowlistedSystemLimits();
  @override
  Limit getAllowlistedTransientLimits() =>
      _base.getAllowlistedTransientLimits();
  @override
  Limit getServiceLimits(String service) => _base.getServiceLimits(service);
  @override
  Limit getServicePeerLimits(String service, PeerId peer) =>
      _base.getServicePeerLimits(service, peer);
  @override
  Limit getProtocolLimits(ProtocolID protocol) =>
      _base.getProtocolLimits(protocol);
  @override
  Limit getProtocolPeerLimits(ProtocolID protocol, PeerId peer) =>
      _base.getProtocolPeerLimits(protocol, peer);
  @override
  Limit getStreamLimits(PeerId peer) => _base.getStreamLimits(peer);
  @override
  Limit getConnLimits() => _base.getConnLimits();
}
