import 'package:dart_libp2p/core/peer/peer_id.dart';
import 'package:dart_libp2p/core/protocol/protocol.dart';
import 'package:dart_libp2p/p2p/host/resource_manager/limit.dart';
import 'package:dart_libp2p/p2p/host/resource_manager/limiter.dart';

const int _mib = 1024 * 1024;
const int _gib = 1024 * _mib;

/// The limits of [LimiterConfig.defaults] before scaling, and how much each
/// one grows per GiB of memory. They are the values of go-libp2p's
/// `rcmgr.DefaultLimits`.
class _ScalingLimit {
  final BaseLimit base;
  final BaseLimit increase; // conns, streams and memory per GiB.
  final double fdFraction; // Share of the FD budget; 0 keeps base.fd.

  const _ScalingLimit(this.base, this.increase, [this.fdFraction = 0]);

  /// go-libp2p's `scale()`: base + increase * (memory in GiB), FD from the
  /// FD budget. A memory budget of 128 MiB or less gives the base limits.
  BaseLimit scale(int memory, int fds) {
    final mib = memory > 128 * _mib ? memory ~/ _mib : 0;
    int grow(int base, int inc) => base + (inc * mib) ~/ 1024;
    var fd = base.fd;
    if (fdFraction > 0 && fds > 0) {
      fd = (fdFraction * fds).floor();
      if (fd < base.fd) fd = base.fd;
    }
    return BaseLimit(
      streams: grow(base.streams, increase.streams),
      streamsInbound: grow(base.streamsInbound, increase.streamsInbound),
      streamsOutbound: grow(base.streamsOutbound, increase.streamsOutbound),
      conns: grow(base.conns, increase.conns),
      connsInbound: grow(base.connsInbound, increase.connsInbound),
      connsOutbound: grow(base.connsOutbound, increase.connsOutbound),
      fd: fd,
      memory: grow(base.memory, increase.memory),
    );
  }
}

final _systemScaling = _ScalingLimit(
  BaseLimit(
      connsInbound: 64,
      connsOutbound: 128,
      conns: 128,
      streamsInbound: 64 * 16,
      streamsOutbound: 128 * 16,
      streams: 128 * 16,
      memory: 128 * _mib,
      fd: 256),
  BaseLimit(
      connsInbound: 64,
      connsOutbound: 128,
      conns: 128,
      streamsInbound: 64 * 16,
      streamsOutbound: 128 * 16,
      streams: 128 * 16,
      memory: _gib),
  1,
);

final _transientScaling = _ScalingLimit(
  BaseLimit(
      connsInbound: 32,
      connsOutbound: 64,
      conns: 64,
      streamsInbound: 128,
      streamsOutbound: 256,
      streams: 256,
      memory: 32 * _mib,
      fd: 64),
  BaseLimit(
      connsInbound: 16,
      connsOutbound: 32,
      conns: 32,
      streamsInbound: 128,
      streamsOutbound: 256,
      streams: 256,
      memory: 128 * _mib),
  0.25,
);

final _serviceScaling = _ScalingLimit(
  BaseLimit(
      streamsInbound: 1024,
      streamsOutbound: 4096,
      streams: 4096,
      memory: 64 * _mib),
  BaseLimit(
      streamsInbound: 512,
      streamsOutbound: 2048,
      streams: 2048,
      memory: 128 * _mib),
);

final _servicePeerScaling = _ScalingLimit(
  BaseLimit(
      streamsInbound: 128,
      streamsOutbound: 256,
      streams: 256,
      memory: 16 * _mib),
  BaseLimit(
      streamsInbound: 4, streamsOutbound: 8, streams: 8, memory: 4 * _mib),
);

final _protocolScaling = _ScalingLimit(
  BaseLimit(
      streamsInbound: 512,
      streamsOutbound: 2048,
      streams: 2048,
      memory: 64 * _mib),
  BaseLimit(
      streamsInbound: 256,
      streamsOutbound: 512,
      streams: 512,
      memory: 164 * _mib),
);

final _protocolPeerScaling = _ScalingLimit(
  BaseLimit(
      streamsInbound: 64,
      streamsOutbound: 128,
      streams: 256,
      memory: 16 * _mib),
  BaseLimit(
      streamsInbound: 4, streamsOutbound: 8, streams: 16, memory: 4 * _mib),
);

final _peerScaling = _ScalingLimit(
  BaseLimit(
      connsInbound: 8,
      connsOutbound: 8,
      conns: 8,
      streamsInbound: 256,
      streamsOutbound: 512,
      streams: 512,
      memory: 64 * _mib,
      fd: 4),
  BaseLimit(
      streamsInbound: 128,
      streamsOutbound: 256,
      streams: 256,
      memory: 128 * _mib),
  1 / 64,
);

final _connScaling = _ScalingLimit(
  BaseLimit(
      connsInbound: 1, connsOutbound: 1, conns: 1, fd: 1, memory: 32 * _mib),
  BaseLimit(),
);

final _streamScaling = _ScalingLimit(
  BaseLimit(
      streamsInbound: 1, streamsOutbound: 1, streams: 1, memory: 16 * _mib),
  BaseLimit(),
);

/// Fills the zero fields of [limit] from [fallback]. A null [limit] gives
/// [fallback].
BaseLimit _fill(BaseLimit? limit, BaseLimit fallback) =>
    limit == null ? fallback : limit.apply(fallback);

Map<K, BaseLimit> _fillAll<K>(Map<K, BaseLimit> limits, BaseLimit fallback) =>
    Map.unmodifiable(limits.map((k, v) => MapEntry(k, v.apply(fallback))));

/// The limits of each resource scope, for a [ConfigurableLimiter].
///
/// A limit is a [BaseLimit]: counts of connections, streams and file
/// descriptors (each direction and in total) and bytes of memory.
///
/// Every argument is optional. A scope that is not given takes its limit
/// from [base] (by default [LimiterConfig.defaults]). In a given
/// [BaseLimit], a field that is 0 also takes the value from [base], so
/// `BaseLimit(conns: 4)` changes only the total connection count. To block
/// a resource, give a negative value. To remove a limit, use
/// [BaseLimit.unlimited].
///
/// The scopes:
/// - [system]: everything the node uses.
/// - [transient]: connections and streams that are not yet attached to a
///   peer or a protocol.
/// - [service] and [servicePeer]: each service (such as `libp2p.autonat`),
///   and each peer within a service.
/// - [protocol] and [protocolPeer]: each protocol, and each peer within a
///   protocol.
/// - [peer]: each remote peer.
/// - [conn] and [stream]: one connection, one stream.
///
/// The overrides set the limit of one service, protocol or peer. Their zero
/// fields take the value of the scope's limit ([service], [protocol],
/// [peer], ...).
class LimiterConfig {
  final BaseLimit system;
  final BaseLimit transient;
  final BaseLimit allowlistedSystem;
  final BaseLimit allowlistedTransient;
  final BaseLimit service;
  final BaseLimit servicePeer;
  final BaseLimit protocol;
  final BaseLimit protocolPeer;
  final BaseLimit peer;
  final BaseLimit conn;
  final BaseLimit stream;

  final Map<String, BaseLimit> serviceOverrides;
  final Map<String, BaseLimit> servicePeerOverrides;
  final Map<ProtocolID, BaseLimit> protocolOverrides;
  final Map<ProtocolID, BaseLimit> protocolPeerOverrides;
  final Map<PeerId, BaseLimit> peerOverrides;

  /// Makes a configuration from [base] (by default
  /// [LimiterConfig.defaults]) with the given limits in place of its own.
  factory LimiterConfig({
    BaseLimit? system,
    BaseLimit? transient,
    BaseLimit? allowlistedSystem,
    BaseLimit? allowlistedTransient,
    BaseLimit? service,
    BaseLimit? servicePeer,
    BaseLimit? protocol,
    BaseLimit? protocolPeer,
    BaseLimit? peer,
    BaseLimit? conn,
    BaseLimit? stream,
    Map<String, BaseLimit> serviceOverrides = const {},
    Map<String, BaseLimit> servicePeerOverrides = const {},
    Map<ProtocolID, BaseLimit> protocolOverrides = const {},
    Map<ProtocolID, BaseLimit> protocolPeerOverrides = const {},
    Map<PeerId, BaseLimit> peerOverrides = const {},
    LimiterConfig? base,
  }) {
    final b = base ?? LimiterConfig.defaults();
    final svc = _fill(service, b.service);
    final svcPeer = _fill(servicePeer, b.servicePeer);
    final proto = _fill(protocol, b.protocol);
    final protoPeer = _fill(protocolPeer, b.protocolPeer);
    final p = _fill(peer, b.peer);
    return LimiterConfig._(
      system: _fill(system, b.system),
      transient: _fill(transient, b.transient),
      allowlistedSystem: _fill(allowlistedSystem, b.allowlistedSystem),
      allowlistedTransient: _fill(allowlistedTransient, b.allowlistedTransient),
      service: svc,
      servicePeer: svcPeer,
      protocol: proto,
      protocolPeer: protoPeer,
      peer: p,
      conn: _fill(conn, b.conn),
      stream: _fill(stream, b.stream),
      serviceOverrides:
          _fillAll({...b.serviceOverrides, ...serviceOverrides}, svc),
      servicePeerOverrides: _fillAll(
          {...b.servicePeerOverrides, ...servicePeerOverrides}, svcPeer),
      protocolOverrides:
          _fillAll({...b.protocolOverrides, ...protocolOverrides}, proto),
      protocolPeerOverrides: _fillAll(
          {...b.protocolPeerOverrides, ...protocolPeerOverrides}, protoPeer),
      peerOverrides: _fillAll({...b.peerOverrides, ...peerOverrides}, p),
    );
  }

  LimiterConfig._({
    required this.system,
    required this.transient,
    required this.allowlistedSystem,
    required this.allowlistedTransient,
    required this.service,
    required this.servicePeer,
    required this.protocol,
    required this.protocolPeer,
    required this.peer,
    required this.conn,
    required this.stream,
    this.serviceOverrides = const {},
    this.servicePeerOverrides = const {},
    this.protocolOverrides = const {},
    this.protocolPeerOverrides = const {},
    this.peerOverrides = const {},
  });

  /// The memory budget of [LimiterConfig.defaults]: 1 GiB.
  static const int defaultMemory = _gib;

  /// The file descriptor budget of [LimiterConfig.defaults]: 512.
  static const int defaultFDs = 512;

  /// The default limits: [LimiterConfig.scaled] with a budget of
  /// [defaultMemory] (1 GiB) and [defaultFDs] (512 file descriptors).
  ///
  /// Dart cannot read the machine's memory or the process's file descriptor
  /// limit portably, so the budget is fixed. With it, the main limits are:
  /// - system: 256 connections (128 inbound), 4096 streams (2048 inbound),
  ///   1152 MiB, 512 FDs;
  /// - transient: 96 connections (48 inbound), 512 streams (256 inbound);
  /// - each peer: 8 connections, 768 streams (384 inbound), 8 FDs;
  /// - each protocol: 2560 streams (768 inbound); each peer in a protocol:
  ///   272 streams (68 inbound);
  /// - each service: 6144 streams (1536 inbound); each peer in a service:
  ///   264 streams (132 inbound).
  factory LimiterConfig.defaults() =>
      LimiterConfig.scaled(memory: defaultMemory, fds: defaultFDs);

  /// The go-libp2p default limits (`rcmgr.DefaultLimits`), scaled to a
  /// budget of [memory] bytes and [fds] file descriptors, as go-libp2p's
  /// `ScalingLimitConfig.Scale` does.
  ///
  /// Each limit is a base value plus an increase for each GiB of [memory]
  /// (a budget of 128 MiB or less gives the base values). The system scope
  /// gets all of [fds], the transient scope a quarter and each peer 1/64.
  /// go-libp2p's `AutoScale` uses 1/8 of the machine's memory and half of
  /// the process's file descriptor limit; to do the same, read these
  /// numbers from the platform and pass them here.
  factory LimiterConfig.scaled({required int memory, required int fds}) {
    if (memory < 0)
      throw ArgumentError.value(memory, 'memory', 'must not be negative');
    if (fds < 0) throw ArgumentError.value(fds, 'fds', 'must not be negative');
    final system = _systemScaling.scale(memory, fds);
    return LimiterConfig._(
      system: system,
      transient: _transientScaling.scale(memory, fds),
      // Not used yet (no allowlist); as go-libp2p, the same as the scopes
      // they stand in for.
      allowlistedSystem: system,
      allowlistedTransient: _transientScaling.scale(memory, fds),
      service: _serviceScaling.scale(memory, fds),
      servicePeer: _servicePeerScaling.scale(memory, fds),
      protocol: _protocolScaling.scale(memory, fds),
      protocolPeer: _protocolPeerScaling.scale(memory, fds),
      peer: _peerScaling.scale(memory, fds),
      conn: _connScaling.scale(memory, fds),
      stream: _streamScaling.scale(memory, fds),
    );
  }

  /// No limits in any scope, as [FixedLimiter] gives for the shared scopes.
  factory LimiterConfig.unlimited() {
    BaseLimit u() => BaseLimit.unlimited();
    return LimiterConfig._(
      system: u(),
      transient: u(),
      allowlistedSystem: u(),
      allowlistedTransient: u(),
      service: u(),
      servicePeer: u(),
      protocol: u(),
      protocolPeer: u(),
      peer: u(),
      conn: u(),
      stream: u(),
    );
  }
}

/// A [Limiter] that gives the limits of a [LimiterConfig].
///
/// `ConfigurableLimiter()` gives [LimiterConfig.defaults], the limits that
/// a host made with `Libp2p.new_` uses unless the `Libp2p.resourceLimiter`
/// or `Libp2p.resourceManager` option says otherwise.
class ConfigurableLimiter implements Limiter {
  /// The limits this limiter gives.
  final LimiterConfig config;

  ConfigurableLimiter([LimiterConfig? config])
      : config = config ?? LimiterConfig.defaults();

  @override
  Limit getSystemLimits() => config.system;

  @override
  Limit getTransientLimits() => config.transient;

  @override
  Limit getAllowlistedSystemLimits() => config.allowlistedSystem;

  @override
  Limit getAllowlistedTransientLimits() => config.allowlistedTransient;

  @override
  Limit getServiceLimits(String service) =>
      config.serviceOverrides[service] ?? config.service;

  @override
  Limit getServicePeerLimits(String service, PeerId peer) =>
      config.servicePeerOverrides[service] ?? config.servicePeer;

  @override
  Limit getProtocolLimits(ProtocolID protocol) =>
      config.protocolOverrides[protocol] ?? config.protocol;

  @override
  Limit getProtocolPeerLimits(ProtocolID protocol, PeerId peer) =>
      config.protocolPeerOverrides[protocol] ?? config.protocolPeer;

  @override
  Limit getPeerLimits(PeerId peer) => config.peerOverrides[peer] ?? config.peer;

  @override
  Limit getStreamLimits(PeerId peer) => config.stream;

  @override
  Limit getConnLimits() => config.conn;
}
