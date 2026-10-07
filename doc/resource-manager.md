# Resource Manager

A public-facing libp2p node can be exposed to resource exhaustion attacks, where malicious peers open many connections or streams to consume all available memory or file descriptors. The **Resource Manager** is the component responsible for protecting a node against such attacks by tracking and limiting the resources consumed by other peers.

## Key Concepts

The Resource Manager works with a system of hierarchical **scopes**. A scope represents a component (like a peer, a connection, or a service) that consumes resources. Resources are tracked and limited at each level of the hierarchy.

The main scopes are:
-   **System**: A global scope for the entire libp2p node.
-   **Transient**: Connections and streams that are not yet attached to a peer or a protocol.
-   **Service**: A scope for a specific service (e.g., `libp2p.autonat`), and within it, one scope per peer.
-   **Protocol**: A scope for a specific protocol (e.g., `/ipfs/ping/1.0.0`), and within it, one scope per peer.
-   **Peer**: A scope for a specific remote peer.
-   **Connection**: A scope for a single network connection.
-   **Stream**: A scope for a single stream within a connection.

A connection starts in the transient scope and moves to its peer scope when the remote peer is known (see [Transports](#transports)). A stream starts in its peer scope and the transient scope, and moves out of the transient scope into the protocol scope when its protocol is negotiated. A resource is counted once in every scope above it.

### Resource Limits

Each scope has a limit, a `BaseLimit` (`lib/p2p/host/resource_manager/limit.dart`) with these fields:
-   `conns`, `connsInbound`, `connsOutbound`: connections, in total and per direction.
-   `streams`, `streamsInbound`, `streamsOutbound`: streams, in total and per direction.
-   `fd`: file descriptors (each TCP or UDX connection counts as one).
-   `memory`: bytes of memory that the scope can reserve.

When a component attempts to reserve a resource (e.g., open a new stream), the Resource Manager checks if the reservation would exceed the limits at every level of the scope hierarchy (from the stream's scope up to the system scope). If any limit is exceeded, the operation fails with `ResourceLimitExceededException`, and the connection or stream is closed.

Scopes are released when their connection or stream closes or is reset (by either side), and when the connection under a stream closes. Peer scopes that nothing uses are dropped every minute.

## The `ResourceManager` Interface

The `ResourceManager` (`lib/core/network/rcmgr.dart`) is the main entry point for interacting with this system. Implementations of this interface are responsible for tracking resource usage and enforcing limits.

-   `ResourceManagerImpl` is the implementation in this library. It takes its limits from a `Limiter`.
-   `NullResourceManager` tracks nothing and limits nothing.

### Key Methods

-   **`Future<ConnManagementScope> openConnection(...)`**: Creates a new connection scope. This is called by the `Swarm` when a new connection is established.
-   **`Future<StreamManagementScope> openStream(...)`**: Creates a new stream scope. This is called by the `Swarm` when a stream is opened or accepted.
-   **`viewSystem`, `viewTransient`, `viewService`, `viewProtocol`, `viewPeer`**: Give a scope, for example to read its usage with `scope.stat`.
-   **`Future<void> close()`**: Closes the resource manager and releases its resources.

## Limiters

A `Limiter` (`lib/p2p/host/resource_manager/limiter.dart`) gives the limit of each scope.

-   **`ConfigurableLimiter`** gives the limits of a `LimiterConfig`. This is the default of a host made with `Libp2p.new_`.
-   **`FixedLimiter`** sets no limit on the system, transient, service, protocol and peer scopes. It was the default before the `ConfigurableLimiter`, and it is still the default of `ResourceManagerImpl()` when you make one without a limiter.

### Default limits

`LimiterConfig.defaults()` gives the default limits of go-libp2p (`rcmgr.DefaultLimits`), scaled as go-libp2p's `ScalingLimitConfig.Scale` does: each limit is a base value plus an increase for each GiB of the memory budget. go-libp2p's `AutoScale` uses 1/8 of the machine's memory and half of the process's file descriptor limit. Dart cannot read these numbers portably, so the defaults use a fixed budget of 1 GiB of memory and 512 file descriptors. With this budget:

| Scope | Connections (in / out / total) | Streams (in / out / total) | Memory | FD |
|---|---|---|---|---|
| System | 128 / 256 / 256 | 2048 / 4096 / 4096 | 1152 MiB | 512 |
| Transient | 48 / 96 / 96 | 256 / 512 / 512 | 160 MiB | 128 |
| Each service | - | 1536 / 6144 / 6144 | 192 MiB | - |
| Each peer in a service | - | 132 / 264 / 264 | 20 MiB | - |
| Each protocol | - | 768 / 2560 / 2560 | 228 MiB | - |
| Each peer in a protocol | - | 68 / 136 / 272 | 20 MiB | - |
| Each peer | 8 / 8 / 8 | 384 / 768 / 768 | 192 MiB | 8 |
| One connection | 1 / 1 / 1 | - | 32 MiB | 1 |
| One stream | - | 1 / 1 / 1 | 16 MiB | - |

If you know the memory and file descriptors that the node can use, scale the limits to them:

```dart
// For example, 1/8 of 16 GiB of memory, and half of a ulimit of 8192.
final config = LimiterConfig.scaled(memory: 2 * 1024 * 1024 * 1024, fds: 4096);
```

A budget of 128 MiB or less gives the base values (for example, 128 system connections and 4 FDs per peer).

### Custom limits

`LimiterConfig(...)` starts from the defaults (or from `base:`) and replaces the limits you give. In a given `BaseLimit`, a field that is 0 keeps the base value, so `BaseLimit(conns: 4)` changes only the total number of connections. A negative value blocks the resource. `BaseLimit.unlimited()` removes the limit.

```dart
import 'package:dart_libp2p/p2p/host/resource_manager/limit.dart';
import 'package:dart_libp2p/p2p/host/resource_manager/limiter.dart';

final limiterConfig = LimiterConfig(
  system: BaseLimit(
    conns: 200,
    streams: 1000,
    memory: 2 * 1024 * 1024 * 1024, // 2 GiB
  ),
  transient: BaseLimit(
    conns: 50,
    streams: 200,
    memory: 256 * 1024 * 1024, // 256 MiB
  ),
  peer: BaseLimit(
    conns: 4,
    streams: 32,
    memory: 64 * 1024 * 1024, // 64 MiB
  ),
  // The limit of one protocol, service or peer.
  protocolOverrides: {'/ipfs/kad/1.0.0': BaseLimit(streamsInbound: 1024)},
  peerOverrides: {trustedPeer: BaseLimit.unlimited()},
);

final limiter = ConfigurableLimiter(limiterConfig);
```

The other arguments are `allowlistedSystem`, `allowlistedTransient` (not used yet), `service`, `servicePeer`, `protocol`, `protocolPeer`, `conn`, `stream`, `serviceOverrides`, `servicePeerOverrides` and `protocolPeerOverrides`. `LimiterConfig.unlimited()` sets no limit anywhere.

## Usage

Give the limiter to the host with the `Libp2p.resourceLimiter` option:

```dart
final host = await Libp2p.new_([
  Libp2p.identity(keyPair),
  // ...
  Libp2p.resourceLimiter(ConfigurableLimiter(limiterConfig)),
]);
```

Or give a whole `ResourceManager` with the `Libp2p.resourceManager` option. The host closes it when the host closes. You cannot give both options.

```dart
// No limits, as before the ConfigurableLimiter was the default:
Libp2p.resourceLimiter(FixedLimiter())
// No tracking and no limits:
Libp2p.resourceManager(NullResourceManager())
```

To read the usage, for example in a health check:

```dart
await host.network.resourceManager.viewSystem((scope) async {
  final s = scope.stat;
  print('conns: ${s.numConnsInbound + s.numConnsOutbound}, '
      'streams: ${s.numStreamsInbound + s.numStreamsOutbound}');
});
```

### Transports

Each connection has one connection scope, whatever its transport.

`TCPTransport` opens the connection scope when the socket opens, as go-libp2p's transports do with `OpenConnection`. The scope is in the transient scope while the connection is upgraded (security and multiplexer negotiation), so the transient limits also cover handshakes in progress. The upgrader carries the scope to the swarm. The swarm uses it for the connection and, when the security handshake has given the remote peer, moves it to the peer scope (`setPeer`). The connection is counted once.

Make the `TCPTransport` without a `resourceManager` to share the host's resource manager. A host made with `Libp2p.new_` (or `Config.newNode`) gives its resource manager to such a transport:

```dart
Libp2p.transport(TCPTransport(connManager: connManager)),
```

A `TCPTransport` that you give a different resource manager (for example `NullResourceManager()`, as older examples do) counts its sockets in that manager only; the host then opens its own scope for each connection after the upgrade. You can also give it the host's manager explicitly.

UDX connections and relayed (circuit v2) connections do not open a scope themselves: the swarm opens one for each connection after the upgrade and attaches it to the peer at once. Their handshakes are therefore not counted in the transient scope.

A connection scope is released once, when the connection closes or when the connection fails: a failed upgrade (security or multiplexer negotiation), a refused `setPeer` (a peer limit), or a refused `openConnection` (a transient or system limit) closes the connection and releases its scope.

By properly configuring the Resource Manager, you can build more resilient and secure peer-to-peer applications.
