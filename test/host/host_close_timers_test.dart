import 'dart:async';

import 'package:dart_libp2p/config/config.dart' as p2p_config;
import 'package:dart_libp2p/core/crypto/ed25519.dart' as crypto_ed25519;
import 'package:dart_libp2p/core/host/host.dart';
import 'package:dart_libp2p/core/multiaddr.dart';
import 'package:dart_libp2p/core/network/network.dart' show Reachability;
import 'package:dart_libp2p/core/network/rcmgr.dart' show NullResourceManager;
import 'package:dart_libp2p/core/peer/addr_info.dart';
import 'package:dart_libp2p/p2p/security/noise/noise_protocol.dart';
import 'package:dart_libp2p/p2p/transport/connection_manager.dart' as p2p_conn_manager;
import 'package:dart_libp2p/p2p/transport/tcp_transport.dart';
import 'package:dart_libp2p/p2p/transport/udx_transport.dart';
import 'package:test/test.dart';

/// A timer that remembers where it was created.
class _TrackedTimer implements Timer {
  _TrackedTimer(this._inner, this.createdAt);

  final Timer _inner;
  final StackTrace createdAt;

  @override
  void cancel() => _inner.cancel();

  @override
  bool get isActive => _inner.isActive;

  @override
  int get tick => _inner.tick;
}

/// Runs [body] and returns the timers it created that are still active
/// [settle] after it completes.
Future<List<_TrackedTimer>> _activeTimersAfter(Future<void> Function() body,
    {Duration settle = const Duration(milliseconds: 500)}) async {
  final timers = <_TrackedTimer>[];
  await runZoned(body,
      zoneSpecification: ZoneSpecification(
        createTimer: (self, parent, zone, duration, f) {
          final t = _TrackedTimer(parent.createTimer(zone, duration, f), StackTrace.current);
          timers.add(t);
          return t;
        },
        createPeriodicTimer: (self, parent, zone, period, f) {
          final t = _TrackedTimer(parent.createPeriodicTimer(zone, period, f), StackTrace.current);
          timers.add(t);
          return t;
        },
      ));
  await Future.delayed(settle);
  return timers.where((t) => t.isActive).toList();
}

Future<Host> _host({bool relay = false, List<String> relays = const []}) async {
  final keyPair = await crypto_ed25519.generateEd25519KeyPair();
  final connManager = p2p_conn_manager.ConnectionManager();
  final host = await p2p_config.Libp2p.new_([
    p2p_config.Libp2p.identity(keyPair),
    p2p_config.Libp2p.connManager(connManager),
    p2p_config.Libp2p.transport(UDXTransport(connManager: connManager)),
    p2p_config.Libp2p.transport(TCPTransport(connManager: connManager, resourceManager: NullResourceManager())),
    p2p_config.Libp2p.security(await NoiseSecurity.create(keyPair)),
    p2p_config.Libp2p.listenAddrs([
      MultiAddr('/ip4/127.0.0.1/udp/0/udx'),
      MultiAddr('/ip4/127.0.0.1/tcp/0'),
    ]),
    p2p_config.Libp2p.relay(relay),
    if (relay) p2p_config.Libp2p.forceReachability(Reachability.public),
    p2p_config.Libp2p.autoRelay(!relay),
    if (relays.isNotEmpty) p2p_config.Libp2p.relayServers(relays),
    p2p_config.Libp2p.holePunching(true),
  ]);
  await host.start();
  return host;
}

String _describe(List<_TrackedTimer> timers) => timers
    .map((t) => t.createdAt
        .toString()
        .split('\n')
        .where((l) => l.contains('package:dart_libp2p/'))
        .take(3)
        .join('\n  '))
    .join('\n---\n');

void main() {
  // A periodic timer, or a pending one, keeps the Dart process alive. If
  // close() leaves one behind, a program that closes its hosts never exits.
  test('a host that is created and closed leaves no active timer', () async {
    final active = await _activeTimersAfter(() async {
      final host = await _host();
      await host.close();
    });
    expect(active, isEmpty, reason: _describe(active));
  });

  test('hosts that connect through a relay leave no active timer after close', () async {
    final active = await _activeTimersAfter(() async {
      final relay = await _host(relay: true);
      final relayAddr = relay.network.listenAddresses.firstWhere((a) => a.hasProtocol('udx'));
      final relays = ['$relayAddr/p2p/${relay.id}'];
      final a = await _host(relays: relays);
      final b = await _host(relays: relays);

      await a.connect(AddrInfo(relay.id, relay.network.listenAddresses));
      await b.connect(AddrInfo(relay.id, relay.network.listenAddresses));
      await a.connect(AddrInfo(b.id, b.network.listenAddresses));

      await a.close();
      await b.close();
      await relay.close();
    });
    expect(active, isEmpty, reason: _describe(active));
  }, timeout: const Timeout(Duration(seconds: 60)));
}
